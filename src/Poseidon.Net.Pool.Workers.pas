unit Poseidon.Net.Pool.Workers;

// TElasticWorkerPool — elastic thread pool for blocking request handlers.
//
// Problem solved:
//   IOCP/epoll IO workers previously doubled as request handlers. With DB-bound
//   workloads (ACBr, ORM queries), all workers block on DB calls and new
//   connections pile up until the worker count (WORKER_COUNT_MAX = 16) is
//   saturated. Under 300 concurrent users, only 16 requests proceed at once.
//
// Solution:
//   Decouple IO workers (small, fixed, auto-computed) from request workers
//   (elastic: start small, grow under load, shrink back when idle).
//
//     MinWorkers:    threads kept alive at all times (default = auto, matches IO workers).
//     MaxWorkers:    peak threads spawned under load (default 200).
//     IdleTimeoutMs: workers above MinWorkers self-terminate after this many ms idle.
//
//   At startup, MinWorkers threads are created — same count as before the fix,
//   so the Delphi debugger sees the same low thread count and starts fast.
//   Under load, new workers are spawned on demand up to MaxWorkers.
//   When load drops, workers above MinWorkers exit after IdleTimeoutMs.
//
// Thread lifecycle:
//   Spawn: called by Post() when IdleWorkers=0 and ActiveWorkers < MaxWorkers.
//          Also called MinWorkers times in Create() to seed the pool.
//   Idle-exit: worker with wrTimeout from semaphore attempts a CAS on
//              FActiveWorkers to claim an exit slot (only when > MinWorkers).
//   Shutdown: FShutdown flag + semaphore Release(N) wakes all workers; they
//             check the flag and break from their loop.
//
// Thread safety:
//   FQueue   — protected by FQueueCS (TCriticalSection).
//   FActiveWorkers / FIdleWorkers — atomic via TInterlocked.
//   FShutdown — written once (Shutdown); workers only read it.
//
// Compiler note:
//   dcc32 has a known bug: TQueue<T> where T is 'reference to procedure' resolves
//   the element type as 'procedure of object', breaking Enqueue/Dequeue.
//   Workaround: TWorkWrapper class holds the closure; TQueue<TWorkWrapper> compiles
//   cleanly on both Win32 and Win64.
//   TInterlocked.Read has only the Int64 overload on dcc32; TInterlocked.Add(X, 0)
//   is the portable atomic-read idiom for Integer fields.

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
  // Callers post `SomeObject.Method`, which binds the object BY VALUE — no
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
    FActiveWorkers: Integer;  // atomic — total alive threads (including idle)
    FPadActive: array[0..14] of Integer;
    FIdleWorkers: Integer;  // atomic — threads blocked on semaphore
    FPadIdle: array[0..14] of Integer;
    FSemaphore:     TSemaphore;
    FShutdown:      Integer;  // 0=running, 1=shutdown; atomic via TInterlocked
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
    // free state those stragglers may still touch — e.g. SSL handles). #177
    function Shutdown(ATimeoutMs: Integer = 30000): Boolean;

    property ActiveWorkers: Integer read FActiveWorkers;
    property IdleWorkers: Integer read FIdleWorkers;
  end;

implementation

uses
  Poseidon.Net.Pool.Buffer;

{ TElasticWorkerPool }

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
  // Seed minimum workers — each assigned to its own deque
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
// FPC: a TThread subclass instead of CreateAnonymousThread(closure). _SpawnWorker
// runs from Post on an IOCP worker thread; FPC 3.3.1 AVs constructing a capturing
// closure there. A subclass carries the deque index in a field — no closure.
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
    // If shutdown happened between _SpawnWorker and here, exit immediately.
    if TInterlocked.Add(FShutdown, 0) <> 0 then Exit;
    while True do
    begin
      // #224 root cause: the semaphore is a single global counter, not
      // per-deque — a Release() for an item just enqueued into OUR deque can
      // be consumed by ANY OTHER waiting worker, whose own check succeeds on
      // a DIFFERENT deque first and who therefore never looks at ours. That
      // was harmless under sustained load (a later Post() eventually wakes
      // someone who steals it) but once traffic stops, every subsequent
      // wake-up for every worker is a bare wrTimeout with no signal at all,
      // and a bare timeout never checked this deque or attempted a steal —
      // so a work item stranded at the exact moment traffic stopped was lost
      // forever. Confirmed via a tagged live repro (Post() logged the item
      // going into deque N; no own-deque hit or steal for that tag was ever
      // logged again, even after 40+ seconds) and a measured ~7-in-92000
      // in-flight leak rate during sustained load itself.
      //
      // Fix: wait in short CSweepIntervalMs slices instead of one long
      // FIdleTimeoutMs block, checking our own deque (and stealing if empty)
      // after EVERY slice, signaled or timed out. A stranded item is now
      // found within one sweep interval instead of only when this specific
      // worker's full idle timeout happens to elapse — the first fix (commit
      // before this one) already guaranteed eventual recovery, but only
      // within FIdleTimeoutMs (30s default), which is a real fix but a poor
      // user-visible latency for what's supposed to be a fast path. Scale-down
      // eligibility still only kicks in once accumulated idle time (across
      // consecutive empty slices) reaches FIdleTimeoutMs, so shrink timing
      // for the elastic pool is unchanged.
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
          LWrapper := LDeque^.Queue.Dequeue;
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
        // Someone else's Release() woke us but both our own deque and every
        // other deque came up empty (already claimed by a faster worker) --
        // genuine activity, not idle time; don't count this slice.
        LIdleAccumMs := 0;
        Continue;
      end;

      // wrTimeout with nothing found anywhere -- one more idle slice.
      Inc(LIdleAccumMs, LWaitMs);
      if LIdleAccumMs < FIdleTimeoutMs then Continue;

      // Accumulated a full idle timeout with no work ever found -- attempt to
      // self-terminate while staying above the minimum.
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
    if not LAlreadyDropped then
      TInterlocked.Decrement(FActiveWorkers);
  end;
end;

procedure TElasticWorkerPool.Post(AWork: TElasticWorkItem);
var
  LWrapper: TWorkWrapper;
  LIdle: Integer;
  LActive: Integer;
  LDequeIdx: Integer;
begin
  // Plain aligned Integer reads are atomic on x64. FShutdown/FIdleWorkers/
  // FActiveWorkers are only read here as a hint (shutdown flag + spawn
  // heuristic), so a locked read (LOCK XADD) is unnecessary — it just dirties
  // the cache line and ping-pongs it across IO threads on every Post.
  if FShutdown <> 0 then Exit;

  LWrapper := TWorkWrapper.Create;
  LWrapper.Work := AWork;

  LDequeIdx := (TInterlocked.Increment(FNextDeque) and $7FFFFFFF) mod FDequeCount;
  FDeques[LDequeIdx].Lock.Enter;
  try
    FDeques[LDequeIdx].Queue.Enqueue(LWrapper);
  finally
    FDeques[LDequeIdx].Lock.Leave;
  end;

  FSemaphore.Release(1);

  // Spawn a new worker when all existing workers are busy and below max.
  LIdle := FIdleWorkers;
  LActive := FActiveWorkers;
  if (LIdle = 0) and (LActive < FMaxWorkers) then
    _SpawnWorker(LDequeIdx);
end;

function TElasticWorkerPool.Shutdown(ATimeoutMs: Integer): Boolean;
var
  LActive: Integer;
  LStart: Int64;
  LWrapper: TWorkWrapper;
  LWork: TElasticWorkItem;
  I: Integer;
begin
  if TInterlocked.Add(FShutdown, 0) <> 0 then
    Exit(TInterlocked.Add(FActiveWorkers, 0) = 0);
  TInterlocked.Exchange(FShutdown, 1);

  // Wake all blocked workers so they check FShutdown and exit cleanly.
  LActive := TInterlocked.Add(FActiveWorkers, 0);
  if LActive > 0 then
    FSemaphore.Release(LActive);

  LStart := Int64(TThread.GetTickCount64);
  while TInterlocked.Add(FActiveWorkers, 0) > 0 do
  begin
    if Int64(TThread.GetTickCount64) - LStart >= ATimeoutMs then Break;
    // Release extra signals in case new workers were spawned after the
    // initial Release(LActive) above — they need a signal to wake up
    // and see FShutdown=1.
    FSemaphore.Release(1);
    Sleep(10);
  end;

  // Drain un-executed work from all deques.
  //
  // Callers pair an AddRef (or equivalent counter Increment) with the closure
  // BEFORE Post — the closure's own try/finally is what does the paired Release.
  // Dropping the wrapper without running the closure leaks the refcount and
  // leaves in-flight counters permanently non-zero. So we execute the closure
  // synchronously here on the shutdown thread; the closure body is short
  // (dispatch already refuses new work when FShutdown=1 higher up the stack,
  // and any exception is swallowed like in the normal worker loop).
  for I := 0 to FDequeCount - 1 do
  begin
    repeat
      LWrapper := nil;
      FDeques[I].Lock.Enter;
      try
        if FDeques[I].Queue.Count > 0 then
          LWrapper := FDeques[I].Queue.Dequeue;
      finally
        FDeques[I].Lock.Leave;
      end;
      if not Assigned(LWrapper) then Break;

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

  // True only if no worker is still executing a (possibly stuck) handler.
  Result := TInterlocked.Add(FActiveWorkers, 0) = 0;
end;

end.
