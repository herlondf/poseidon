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
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections;

type
  TElasticWorkItem = reference to procedure;

  TElasticWorkerPool = class
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
    FShutdown:      Boolean;
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
    procedure Shutdown(ATimeoutMs: Integer = 30000);

    property ActiveWorkers: Integer read FActiveWorkers;
    property IdleWorkers: Integer read FIdleWorkers;
  end;

implementation

{ TElasticWorkerPool }

constructor TElasticWorkerPool.Create(AMin, AMax, AIdleTimeoutMs: Integer);
var
  I: Integer;
begin
  inherited Create;
  FMinWorkers := AMin;
  FMaxWorkers := AMax;
  FIdleTimeoutMs := AIdleTimeoutMs;
  FShutdown := False;
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

procedure TElasticWorkerPool._SpawnWorker(ADequeIdx: Integer);
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
begin
  TInterlocked.Increment(FActiveWorkers);
  LAlreadyDropped := False;
  LDeque := @FDeques[ADequeIdx];
  try
    while True do
    begin
      TInterlocked.Increment(FIdleWorkers);
      LResult := FSemaphore.WaitFor(LongWord(FIdleTimeoutMs));
      TInterlocked.Decrement(FIdleWorkers);

      if FShutdown then Break;

      if LResult = wrTimeout then
      begin
        // Attempt to self-terminate while staying above the minimum.
        repeat
          LCurActive := TInterlocked.Add(FActiveWorkers, 0);
          if LCurActive <= FMinWorkers then Break;
        until TInterlocked.CompareExchange(
                FActiveWorkers, LCurActive - 1, LCurActive) = LCurActive;

        if LCurActive > FMinWorkers then
        begin
          LAlreadyDropped := True;
          Exit;
        end;
        Continue;
      end;

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
      end;
    end;
  finally
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
  if FShutdown then Exit;

  LWrapper := TWorkWrapper.Create;
  LWrapper.Work := AWork;

  LDequeIdx := TInterlocked.Increment(FNextDeque) mod FDequeCount;
  FDeques[LDequeIdx].Lock.Enter;
  try
    FDeques[LDequeIdx].Queue.Enqueue(LWrapper);
  finally
    FDeques[LDequeIdx].Lock.Leave;
  end;

  FSemaphore.Release(1);

  // Spawn a new worker when all existing workers are busy and below max.
  LIdle := TInterlocked.Add(FIdleWorkers, 0);
  LActive := TInterlocked.Add(FActiveWorkers, 0);
  if (LIdle = 0) and (LActive < FMaxWorkers) then
    _SpawnWorker(LDequeIdx);
end;

procedure TElasticWorkerPool.Shutdown(ATimeoutMs: Integer);
var
  LActive: Integer;
  LStart: Int64;
  LWrapper: TWorkWrapper;
  I: Integer;
begin
  if FShutdown then Exit;
  FShutdown := True;

  // Wake all blocked workers so they check FShutdown and exit cleanly.
  LActive := TInterlocked.Add(FActiveWorkers, 0);
  if LActive > 0 then
    FSemaphore.Release(LActive);

  LStart := Int64(TThread.GetTickCount64);
  while TInterlocked.Add(FActiveWorkers, 0) > 0 do
  begin
    if Int64(TThread.GetTickCount64) - LStart >= ATimeoutMs then Break;
    Sleep(10);
  end;

  // Drain un-executed work from all deques
  for I := 0 to FDequeCount - 1 do
  begin
    FDeques[I].Lock.Enter;
    try
      while FDeques[I].Queue.Count > 0 do
      begin
        LWrapper := FDeques[I].Queue.Dequeue;
        LWrapper.Work := nil;
        LWrapper.Free;
      end;
    finally
      FDeques[I].Lock.Leave;
    end;
  end;
end;

end.
