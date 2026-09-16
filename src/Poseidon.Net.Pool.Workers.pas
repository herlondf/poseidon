unit Poseidon.Net.Pool.Workers;

// TElasticWorkerPool runs blocking request handlers, kept separate from the IO
// workers on purpose. When IO workers doubled as handlers, a DB-bound workload
// blocked all of them and throughput capped at the IO worker count: 300
// concurrent users, 16 requests actually moving. So the IO tier stays small and
// fixed while this one starts at MinWorkers, grows to MaxWorkers under load, and
// lets anything above MinWorkers self-terminate after IdleTimeoutMs.
//
// Thread safety: FQueue under FQueueCS; FActiveWorkers/FIdleWorkers atomic;
// FShutdown written once by Shutdown and only read by workers.
//
// Two compiler workarounds live here. dcc32 resolves TQueue<reference to
// procedure> as 'procedure of object' and breaks Enqueue/Dequeue, so TWorkWrapper
// carries the closure. And TInterlocked.Read is Int64-only on dcc32, so Integer
// fields use TInterlocked.Add(X, 0) as the portable atomic read.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  syncobjs,
  Generics.Collections,
  Poseidon.Compat;
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;
  {$ENDIF}

type
  {$IFDEF FPC}
  // FPC: a plain method pointer (procedure of object), NOT a function reference.
  // Callers post `SomeObject.Method`, which binds the object BY VALUE - no
  // capture frame. FPC 3.3.1's function-reference adaptation of a method AVs
  // when built on an IOCP worker thread and, worse, captures the caller's local
  // variable by reference (garbage after it returns). A method pointer sidesteps
  // both. Delphi keeps `reference to procedure` (it posts anonymous methods).
  TElasticWorkItem = procedure of object;
  {$ELSE}
  TElasticWorkItem = reference to procedure;
  {$ENDIF}

  TElasticWorkerPool = class
  private const
    // #224: cap on how long a worker ever blocks in one semaphore wait, so
    // every deque gets its own-check-and-steal sweep this often regardless
    // of whether the global semaphore ever signals THIS specific worker.
    // Bounds worst-case recovery latency for a stranded item independently
    // of FIdleTimeoutMs (which still governs elastic scale-down timing).
    CSweepIntervalMs = 200;
  private type
    // Wrapper avoids the dcc32 generic+closure type resolution bug.
    TWorkWrapper = class
    public
      Work: TElasticWorkItem;
    end;
    PWorkerDeque = ^TWorkerDeque;
    TWorkerDeque = record
      Queue: TQueue<TWorkWrapper>;
      Lock: TCriticalSection;
    end;
  private
    FMinWorkers: Integer;
    FMaxWorkers: Integer;
    FIdleTimeoutMs: Integer;
    FDeques: array of TWorkerDeque;
    FDequeCount: Integer;
    FNextDeque: Integer;  // atomic round-robin counter for Post()
    FPadNextDeque: array[0..14] of Integer;
    FActiveWorkers: Integer;  // atomic - total alive threads (including idle)
    FPadActive: array[0..14] of Integer;
    FIdleWorkers: Integer;  // atomic - threads blocked on semaphore
    FPadIdle: array[0..14] of Integer;
    FPendingItems: Integer;  // atomic - itens enfileirados ainda nao retirados
    FPadPending: array[0..14] of Integer;
    FSemaphore:     TSemaphore;
    FShutdown:      Integer;  // 0=running, 1=shutdown; atomic via TInterlocked
    procedure _WarmUpThreadLocaleCache;
    procedure _WorkerLoop(ADequeIdx: Integer);
    procedure _SpawnWorker(ADequeIdx: Integer);
    function  _TrySteal(AMyIdx: Integer; out AWrapper: TWorkWrapper): Boolean;
  public
    constructor Create(AMin, AMax, AIdleTimeoutMs: Integer);
    destructor Destroy; override;

    // Enqueue a work item. Spawns a new worker if no idle workers and below max.
    procedure Post(AWork: TElasticWorkItem);

    // Signal shutdown, drain in-flight work, wait up to ATimeoutMs.
    // Safe to call multiple times. Subsequent calls are no-ops.
    // Returns True if all workers actually drained within the timeout; False
    // if it broke on timeout with stragglers still running (caller must NOT
    // free state those stragglers may still touch - e.g. SSL handles). #177
    function Shutdown(ATimeoutMs: Integer = 30000): Boolean;

    property ActiveWorkers: Integer read FActiveWorkers;
    property IdleWorkers: Integer read FIdleWorkers;
  end;

implementation

uses
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.HttpServer,
  Poseidon.Net.ResponseBuilder;

var
  // #234: on POSIX, case-insensitive compare goes through ICU. Its collator
  // cache is a threadvar, so each new worker starts empty and its first compare
  // falls into ICU's own cold-start path, which touches process-shared state
  // (icu_XX::UnifiedCache). Helgrind confirmed workers spawned in a burst racing
  // there. Serializing only that first call per thread removes the race without
  // trusting ICU's internal locking.
  GThreadLocaleWarmUpLock: TCriticalSection;

{ TElasticWorkerPool }

// #234: populates this thread's ICU collator cache now, under the lock, instead
// of lazily and concurrently with sibling workers.
procedure TElasticWorkerPool._WarmUpThreadLocaleCache;
begin
  GThreadLocaleWarmUpLock.Enter;
  try
    AnsiCompareText('Poseidon', 'poseidon');
  finally
    GThreadLocaleWarmUpLock.Leave;
  end;
end;

constructor TElasticWorkerPool.Create(AMin, AMax, AIdleTimeoutMs: Integer);
var
  I: Integer;
begin
  inherited Create;
  FMinWorkers := AMin;
  FMaxWorkers := AMax;
  FIdleTimeoutMs := AIdleTimeoutMs;
  FShutdown := 0;
  FActiveWorkers := 0;
  FIdleWorkers := 0;
  FPendingItems := 0;
  FNextDeque := 0;

  FDequeCount := AMin;
  if FDequeCount < 1 then FDequeCount := 1;
  SetLength(FDeques, FDequeCount);
  for I := 0 to FDequeCount - 1 do
  begin
    FDeques[I].Queue := TQueue<TWorkWrapper>.Create;
    FDeques[I].Lock := TCriticalSection.Create;
  end;

  FSemaphore := TSemaphore.Create(nil, 0, MaxInt, '');
  for I := 0 to FMinWorkers - 1 do
    _SpawnWorker(I mod FDequeCount);
end;

destructor TElasticWorkerPool.Destroy;
var
  I: Integer;
begin
  Shutdown;
  for I := 0 to FDequeCount - 1 do
  begin
    FreeAndNil(FDeques[I].Queue);
    FreeAndNil(FDeques[I].Lock);
  end;
  FreeAndNil(FSemaphore);
  inherited Destroy;
end;

{$IFDEF FPC}
// FPC 3.3.1 AVs constructing a capturing closure from Post on an IOCP worker
// thread, so this is a TThread subclass carrying the deque index in a field.
type
  TFPCPoolWorker = class(TThread)
  public
    Pool: TElasticWorkerPool;
    DequeIdx: Integer;
    procedure Execute; override;
  end;

procedure TFPCPoolWorker.Execute;
begin
  Pool._WorkerLoop(DequeIdx);
end;
{$ENDIF}

procedure TElasticWorkerPool._SpawnWorker(ADequeIdx: Integer);
{$IFDEF FPC}
var
  LWorker: TFPCPoolWorker;
begin
  LWorker := TFPCPoolWorker.Create(True);  // suspended: set fields before running
  LWorker.Pool := Self;
  LWorker.DequeIdx := ADequeIdx;
  LWorker.FreeOnTerminate := True;
  LWorker.Start;
end;
{$ELSE}
var
  LIdx: Integer;
  LThread: TThread;
begin
  LIdx := ADequeIdx;
  LThread := TThread.CreateAnonymousThread(
    procedure begin _WorkerLoop(LIdx); end);
  LThread.FreeOnTerminate := True;
  LThread.Start;
end;
{$ENDIF}

function TElasticWorkerPool._TrySteal(AMyIdx: Integer; out AWrapper: TWorkWrapper): Boolean;
var
  I, LTarget: Integer;
begin
  Result := False;
  AWrapper := nil;
  for I := 1 to FDequeCount - 1 do
  begin
    LTarget := (AMyIdx + I) mod FDequeCount;
    FDeques[LTarget].Lock.Enter;
    try
      if FDeques[LTarget].Queue.Count > 0 then
      begin
        AWrapper := FDeques[LTarget].Queue.Dequeue;
        TInterlocked.Decrement(FPendingItems);
        Result := True;
        Exit;
      end;
    finally
      FDeques[LTarget].Lock.Leave;
    end;
  end;
end;

procedure TElasticWorkerPool._WorkerLoop(ADequeIdx: Integer);
var
  LWrapper: TWorkWrapper;
  LWork: TElasticWorkItem;
  LResult: TWaitResult;
  LCurActive: Integer;
  LAlreadyDropped: Boolean;
  LDeque: PWorkerDeque;
  LIdleAccumMs: Integer;
  LWaitMs: Integer;
begin
  TInterlocked.Increment(FActiveWorkers);
  LAlreadyDropped := False;
  LDeque := @FDeques[ADequeIdx];
  LIdleAccumMs := 0;
  try
    if TInterlocked.Add(FShutdown, 0) <> 0 then Exit;
    _WarmUpThreadLocaleCache;
    while True do
    begin
      // #224: the semaphore is one global counter, not per-deque, so a Release
      // for an item enqueued into OUR deque can be consumed by another worker
      // that finds work elsewhere and never looks here. Under sustained load a
      // later Post eventually wakes someone who steals it, but once traffic
      // stops every wake is a bare timeout, and a bare timeout used to check
      // nothing - an item stranded exactly when traffic stopped was lost for
      // good. A tagged repro showed the item entering deque N and never being
      // hit or stolen again after 40s; sustained load leaked ~7 in 92000.
      //
      // So the wait runs in CSweepIntervalMs slices, checking our own deque and
      // stealing after every slice, signaled or not. Recovery is now one sweep
      // interval instead of a full FIdleTimeoutMs (30s). Scale-down still needs
      // accumulated idle to reach FIdleTimeoutMs, so shrink timing is unchanged.
      TInterlocked.Increment(FIdleWorkers);
      LWaitMs := CSweepIntervalMs;
      if LWaitMs > FIdleTimeoutMs then LWaitMs := FIdleTimeoutMs;
      LResult := FSemaphore.WaitFor(LongWord(LWaitMs));
      TInterlocked.Decrement(FIdleWorkers);

      if TInterlocked.Add(FShutdown, 0) <> 0 then Break;

      LWrapper := nil;
      LDeque^.Lock.Enter;
      try
        if LDeque^.Queue.Count > 0 then
        begin
          LWrapper := LDeque^.Queue.Dequeue;
          TInterlocked.Decrement(FPendingItems);
        end;
      finally
        LDeque^.Lock.Leave;
      end;

      if not Assigned(LWrapper) then
        _TrySteal(ADequeIdx, LWrapper);

      if Assigned(LWrapper) then
      begin
        LIdleAccumMs := 0;
        LWork := LWrapper.Work;
        LWrapper.Work := nil;
        LWrapper.Free;
        try
          LWork();
        except
          on E: Exception do
            Writeln(ErrOutput, '[pool.workers] WORKER_EX [',
              E.ClassName, ']: ', E.Message);
        end;
        LWork := nil;
        Continue;  // found and ran work -- skip the idle/scale-down check below
      end;

      if LResult = wrSignaled then
      begin
        // Woken by someone else's Release but every deque was already claimed:
        // that is activity, not idle time. Don't count this slice.
        LIdleAccumMs := 0;
        Continue;
      end;

      // Nothing found anywhere: one more idle slice.
      Inc(LIdleAccumMs, LWaitMs);
      if LIdleAccumMs < FIdleTimeoutMs then Continue;

      // A full idle timeout with no work: try to self-terminate, staying above
      // the minimum.
      repeat
        LCurActive := TInterlocked.Add(FActiveWorkers, 0);
        if LCurActive <= FMinWorkers then Break;
      until TInterlocked.CompareExchange(
              FActiveWorkers, LCurActive - 1, LCurActive) = LCurActive;

      if LCurActive > FMinWorkers then
      begin
        // Final guard against a Post() landing in OUR deque in the narrow
        // window between the check above and the CAS decrement.
        LDeque^.Lock.Enter;
        try
          if LDeque^.Queue.Count > 0 then
          begin
            TInterlocked.Increment(FActiveWorkers);  // undo -- stay alive
            LIdleAccumMs := 0;
            Continue;
          end;
        finally
          LDeque^.Lock.Leave;
        end;
        LAlreadyDropped := True;
        Exit;
      end;
      LIdleAccumMs := 0;  // min-worker: stay alive, reset the accumulator
    end;
  finally
    TBufferPool.FlushThreadCache;
    ResetThreadDateCache;
    ResetThreadDeferVars;
    if not LAlreadyDropped then
      TInterlocked.Decrement(FActiveWorkers);
  end;
end;

procedure TElasticWorkerPool.Post(AWork: TElasticWorkItem);
var
  LWrapper: TWorkWrapper;
  LIdle: Integer;
  LActive: Integer;
  LPending: Integer;
  LDequeIdx: Integer;
begin
  // Aligned Integer reads are atomic on x64, and these three are only hints
  // here (shutdown flag, spawn heuristic). A locked read would just dirty the
  // cache line and ping-pong it across IO threads on every Post.
  if FShutdown <> 0 then
  begin
    // Callers AddRef before Post and the closure's own try/finally does the
    // paired Release. Dropping AWork silently here would leak that ref whenever
    // a caller loses the race against Shutdown flipping FShutdown: no crash,
    // just a connection that never reaches refcount 0.
    try
      AWork();
    except
      on E: Exception do
        Writeln(ErrOutput, '[pool.workers] WORKER_EX [', E.ClassName, ']: ',
          E.Message);
    end;
    Exit;
  end;

  LWrapper := TWorkWrapper.Create;
  LWrapper.Work := AWork;

  LDequeIdx := (TInterlocked.Increment(FNextDeque) and $7FFFFFFF) mod FDequeCount;
  FDeques[LDequeIdx].Lock.Enter;
  try
    FDeques[LDequeIdx].Queue.Enqueue(LWrapper);
    TInterlocked.Increment(FPendingItems);
  finally
    FDeques[LDequeIdx].Lock.Leave;
  end;

  FSemaphore.Release(1);

  // FIdleWorkers so cai quando o worker acorda do semaforo, o que leva muito
  // mais tempo que uma rajada de Post. Decidir por ele fazia o pool ler os 2
  // workers ainda como ociosos nos 6 Posts seguidos e nunca crescer: a fila
  // acumulava e o spawn nunca era avaliado de novo, porque so Post avalia.
  // Comparar com o backlog real de itens nao retirados enxerga a rajada.
  LIdle := FIdleWorkers;
  LActive := FActiveWorkers;
  LPending := TInterlocked.Add(FPendingItems, 0);
  if (LPending > LIdle) and (LActive < FMaxWorkers) then
    _SpawnWorker(LDequeIdx);
end;

function TElasticWorkerPool.Shutdown(ATimeoutMs: Integer): Boolean;
const
  // Defensive cap on #258's drain-until-empty loop below - not expected to
  // ever bind (see the comment at the loop itself).
  CMaxDrainPasses = 1000;
var
  LActive: Integer;
  LStart: Int64;
  LWrapper: TWorkWrapper;
  LWork: TElasticWorkItem;
  I: Integer;
  LDrainedAny: Boolean;
  LPassNum: Integer;
begin
  if TInterlocked.Add(FShutdown, 0) <> 0 then
    Exit(TInterlocked.Add(FActiveWorkers, 0) = 0);
  TInterlocked.Exchange(FShutdown, 1);

  LActive := TInterlocked.Add(FActiveWorkers, 0);
  if LActive > 0 then
    FSemaphore.Release(LActive);

  LStart := Int64(TThread.GetTickCount64);
  while TInterlocked.Add(FActiveWorkers, 0) > 0 do
  begin
    if Int64(TThread.GetTickCount64) - LStart >= ATimeoutMs then Break;
    // Extra signals for workers spawned after the Release(LActive) above.
    FSemaphore.Release(1);
    Sleep(10);
  end;

  // Dropping a queued wrapper without running it leaks the AddRef the caller
  // paired with Post, so the closures run synchronously here on the shutdown
  // thread. Their bodies are short: dispatch already refuses new work once
  // FShutdown is set, and exceptions are swallowed as in the worker loop.
  //
  // #258: Post() reads FShutdown as an unlocked hint (see its own comment
  // above) to avoid dirtying the cache line on every call. A caller that
  // reads FShutdown=0 a moment before the Exchange below flips it still
  // enqueues normally afterward - if that Enqueue lands on a deque index
  // AFTER this drain has already finished with it, the single sequential
  // pass below (I := 0 to FDequeCount-1, each visited exactly once) would
  // never come back to collect it: the item, and the caller's paired
  // AddRef/InFlightPool/FInFlightCount increment, would leak forever, since
  // no worker exists anymore to dequeue it. LDrainedAny makes this drain
  // itself the "N consecutive empty passes" loop: keep sweeping every deque
  // until one full pass finds nothing left anywhere, which is guaranteed to
  // happen quickly (the race window is one in-flight Enqueue per straggling
  // caller at the instant of the flip, not a sustained producer - normal
  // callers see FShutdown<>0 and never enqueue at all). CMaxDrainPasses is a
  // defensive cap only, not expected to ever bind.
  LPassNum := 0;
  repeat
    Inc(LPassNum);
    LDrainedAny := False;
    for I := 0 to FDequeCount - 1 do
    begin
      repeat
        LWrapper := nil;
        FDeques[I].Lock.Enter;
        try
          if FDeques[I].Queue.Count > 0 then
          begin
            LWrapper := FDeques[I].Queue.Dequeue;
            TInterlocked.Decrement(FPendingItems);
          end;
        finally
          FDeques[I].Lock.Leave;
        end;
        if not Assigned(LWrapper) then Break;
        LDrainedAny := True;

        LWork := LWrapper.Work;
        LWrapper.Work := nil;
        LWrapper.Free;
        if Assigned(LWork) then
        begin
          try
            LWork();
          except
            on E: Exception do
              Writeln(ErrOutput, '[pool.workers] SHUTDOWN_DRAIN_EX [',
                E.ClassName, ']: ', E.Message);
          end;
          LWork := nil;
        end;
      until False;
    end;
  until (not LDrainedAny) or (LPassNum >= CMaxDrainPasses);

  // True only if no worker is still executing a (possibly stuck) handler.
  Result := TInterlocked.Add(FActiveWorkers, 0) = 0;
end;

initialization
  GThreadLocaleWarmUpLock := TCriticalSection.Create;

finalization
  GThreadLocaleWarmUpLock.Free;

end.
