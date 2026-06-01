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
  private
    FMinWorkers:    Integer;
    FMaxWorkers:    Integer;
    FIdleTimeoutMs: Integer;
    FQueue:         TQueue<TWorkWrapper>;
    FQueueCS:       TCriticalSection;
    FSemaphore:     TSemaphore;
    FActiveWorkers: Integer;  // atomic — total alive threads (including idle)
    FIdleWorkers:   Integer;  // atomic — threads blocked on semaphore
    FShutdown:      Boolean;
    procedure _WorkerLoop;
    procedure _SpawnWorker;
  public
    constructor Create(AMin, AMax, AIdleTimeoutMs: Integer);
    destructor Destroy; override;

    // Enqueue a work item. Spawns a new worker if no idle workers and below max.
    procedure Post(AWork: TElasticWorkItem);

    // Signal shutdown, drain in-flight work, wait up to ATimeoutMs.
    // Safe to call multiple times. Subsequent calls are no-ops.
    procedure Shutdown(ATimeoutMs: Integer = 30000);

    property ActiveWorkers: Integer read FActiveWorkers;
    property IdleWorkers:   Integer read FIdleWorkers;
  end;

implementation

{ TElasticWorkerPool }

constructor TElasticWorkerPool.Create(AMin, AMax, AIdleTimeoutMs: Integer);
var
  I: Integer;
begin
  inherited Create;
  FMinWorkers    := AMin;
  FMaxWorkers    := AMax;
  FIdleTimeoutMs := AIdleTimeoutMs;
  FShutdown      := False;
  FActiveWorkers := 0;
  FIdleWorkers   := 0;
  FQueue         := TQueue<TWorkWrapper>.Create;
  FQueueCS       := TCriticalSection.Create;
  // Initial count 0; Release increments, WaitFor decrements.
  FSemaphore     := TSemaphore.Create(nil, 0, MaxInt, '');
  // Seed minimum workers so they are available before the first request arrives.
  for I := 1 to FMinWorkers do
    _SpawnWorker;
end;

destructor TElasticWorkerPool.Destroy;
begin
  Shutdown;
  FreeAndNil(FQueue);
  FreeAndNil(FQueueCS);
  FreeAndNil(FSemaphore);
  inherited Destroy;
end;

procedure TElasticWorkerPool._SpawnWorker;
var
  LThread: TThread;
begin
  LThread := TThread.CreateAnonymousThread(procedure begin _WorkerLoop; end);
  LThread.FreeOnTerminate := True;
  LThread.Start;
end;

procedure TElasticWorkerPool._WorkerLoop;
var
  LWrapper:        TWorkWrapper;
  LWork:           TElasticWorkItem;
  LResult:         TWaitResult;
  LCurActive:      Integer;
  LAlreadyDropped: Boolean;
begin
  TInterlocked.Increment(FActiveWorkers);
  LAlreadyDropped := False;
  try
    while True do
    begin
      TInterlocked.Increment(FIdleWorkers);
      // LongWord cast: WaitFor(Timeout: LongWord) — FIdleTimeoutMs is always >= 0
      LResult := FSemaphore.WaitFor(LongWord(FIdleTimeoutMs));
      TInterlocked.Decrement(FIdleWorkers);

      if FShutdown then Break;

      if LResult = wrTimeout then
      begin
        // Attempt to self-terminate while staying above the minimum.
        // CAS loop: speculatively decrement FActiveWorkers only when > FMinWorkers.
        // If two workers race here, the CAS ensures only one successfully exits
        // per iteration — the other retries the check.
        // TInterlocked.Add(X, 0) is the portable atomic-read idiom for Integer;
        // TInterlocked.Read only has the Int64 overload on dcc32.
        repeat
          LCurActive := TInterlocked.Add(FActiveWorkers, 0);
          if LCurActive <= FMinWorkers then Break;  // At/below minimum — stay alive
        until TInterlocked.CompareExchange(
                FActiveWorkers, LCurActive - 1, LCurActive) = LCurActive;

        if LCurActive > FMinWorkers then
        begin
          // CAS succeeded: we claimed the exit slot and already decremented.
          // Skip the finally block's decrement.
          LAlreadyDropped := True;
          Exit;
        end;
        Continue;  // At minimum — keep waiting for work
      end;

      // Got a semaphore signal — dequeue and execute one work item.
      LWrapper := nil;
      FQueueCS.Enter;
      try
        if FQueue.Count > 0 then
          LWrapper := FQueue.Dequeue;
      finally
        FQueueCS.Leave;
      end;

      if Assigned(LWrapper) then
      begin
        LWork := LWrapper.Work;
        LWrapper.Work := nil;  // Release closure before freeing wrapper
        LWrapper.Free;
        try
          LWork();
        except
          on E: Exception do
            Writeln(ErrOutput, '[pool.workers] WORKER_EX [',
              E.ClassName, ']: ', E.Message);
        end;
        LWork := nil;  // Release closure and captured references
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
  LIdle:    Integer;
  LActive:  Integer;
begin
  if FShutdown then Exit;

  LWrapper      := TWorkWrapper.Create;
  LWrapper.Work := AWork;

  FQueueCS.Enter;
  try
    FQueue.Enqueue(LWrapper);
  finally
    FQueueCS.Leave;
  end;

  FSemaphore.Release(1);

  // Spawn a new worker when all existing workers are busy and below max.
  // TOCTOU: a mild race may briefly spawn one extra worker; it self-terminates
  // on the next idle timeout without impacting correctness.
  LIdle   := TInterlocked.Add(FIdleWorkers, 0);
  LActive := TInterlocked.Add(FActiveWorkers, 0);
  if (LIdle = 0) and (LActive < FMaxWorkers) then
    _SpawnWorker;
end;

procedure TElasticWorkerPool.Shutdown(ATimeoutMs: Integer);
var
  LActive:  Integer;
  LStart:   Int64;
  LWrapper: TWorkWrapper;
begin
  if FShutdown then Exit;
  FShutdown := True;

  // Wake all blocked workers so they check FShutdown and exit cleanly.
  LActive := TInterlocked.Add(FActiveWorkers, 0);
  if LActive > 0 then
    FSemaphore.Release(LActive);

  // Wait for all workers to exit. Shutdown is a rare operation; short Sleep
  // intervals are acceptable here.
  LStart := Int64(TThread.GetTickCount64);
  while TInterlocked.Add(FActiveWorkers, 0) > 0 do
  begin
    if Int64(TThread.GetTickCount64) - LStart >= ATimeoutMs then Break;
    Sleep(10);
  end;

  // Drain any un-executed work items left in the queue (e.g. on timeout).
  FQueueCS.Enter;
  try
    while FQueue.Count > 0 do
    begin
      LWrapper := FQueue.Dequeue;
      LWrapper.Work := nil;
      LWrapper.Free;
    end;
  finally
    FQueueCS.Leave;
  end;
end;

end.
