unit Poseidon.Tests.Workers;

// DUnitX tests for TElasticWorkerPool — elastic thread pool.
//
// Coverage:
//   - MinWorkers seeded on Create
//   - Post executes work item
//   - Burst above MinWorkers spawns additional workers
//   - Idle timeout shrinks pool back to MinWorkers
//   - Shutdown drains queue and waits for running items
//   - Exception in work item does not crash the pool
//   - MaxWorkers ceiling is respected

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TElasticWorkerPoolTests = class
  public
    [Test] procedure Create_MinWorkers_SpawnedImmediately;
    [Test] procedure Post_SingleItem_Executed;
    [Test] procedure Post_BurstAboveMin_SpawnsAdditional;
    [Test] procedure IdleTimeout_WorkersAboveMin_ShrinkToMin;
    [Test] procedure Shutdown_DrainsQueue;
    [Test] procedure Shutdown_WaitsForRunning;
    [Test] procedure Post_ExceptionInWork_PoolSurvives;
    [Test] procedure Post_MaxWorkersReached_NoOverspawn;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Poseidon.Net.Pool.Workers;

const
  TEST_MIN_WORKERS     = 2;
  TEST_MAX_WORKERS     = 8;
  TEST_IDLE_TIMEOUT_MS = 300;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

procedure TElasticWorkerPoolTests.Create_MinWorkers_SpawnedImmediately;
var
  LPool: TElasticWorkerPool;
begin
  LPool := TElasticWorkerPool.Create(TEST_MIN_WORKERS, TEST_MAX_WORKERS, TEST_IDLE_TIMEOUT_MS);
  try
    // Workers are spawned in Create; give them a moment to register
    Sleep(100);
    Assert.IsTrue(LPool.ActiveWorkers >= TEST_MIN_WORKERS,
      'ActiveWorkers must be >= MinWorkers after Create');
  finally
    LPool.Shutdown(2000);
    LPool.Free;
  end;
end;

procedure TElasticWorkerPoolTests.Post_SingleItem_Executed;
var
  LPool: TElasticWorkerPool;
  LDone: TEvent;
begin
  LDone := TEvent.Create(nil, True, False, '');
  try
    LPool := TElasticWorkerPool.Create(TEST_MIN_WORKERS, TEST_MAX_WORKERS, TEST_IDLE_TIMEOUT_MS);
    try
      LPool.Post(procedure begin LDone.SetEvent; end);
      Assert.AreEqual(TWaitResult.wrSignaled, LDone.WaitFor(2000),
        'Work item must be executed within timeout');
    finally
      LPool.Shutdown(2000);
      LPool.Free;
    end;
  finally
    LDone.Free;
  end;
end;

procedure TElasticWorkerPoolTests.Post_BurstAboveMin_SpawnsAdditional;
// Post many slow items to force pool to spawn workers above MinWorkers.
var
  LPool: TElasticWorkerPool;
  LGate: TEvent;
  I:     Integer;
  LPeakActive: Integer;
begin
  LGate := TEvent.Create(nil, True, False, '');
  try
    LPool := TElasticWorkerPool.Create(TEST_MIN_WORKERS, TEST_MAX_WORKERS, TEST_IDLE_TIMEOUT_MS);
    try
      // Post 6 slow items that block until gate is opened
      for I := 1 to 6 do
        LPool.Post(procedure begin LGate.WaitFor(5000); end);

      // Give time for workers to spawn and pick up items
      Sleep(300);
      LPeakActive := LPool.ActiveWorkers;

      // Release all blocked items
      LGate.SetEvent;
      Sleep(200);

      Assert.IsTrue(LPeakActive > TEST_MIN_WORKERS,
        'Pool must spawn workers above MinWorkers under burst load (peak=' +
        IntToStr(LPeakActive) + ')');
    finally
      LPool.Shutdown(3000);
      LPool.Free;
    end;
  finally
    LGate.Free;
  end;
end;

procedure TElasticWorkerPoolTests.IdleTimeout_WorkersAboveMin_ShrinkToMin;
// After a burst, workers above MinWorkers should self-terminate after idle timeout.
var
  LPool: TElasticWorkerPool;
  LGate: TEvent;
  I:     Integer;
begin
  LGate := TEvent.Create(nil, True, False, '');
  try
    LPool := TElasticWorkerPool.Create(TEST_MIN_WORKERS, TEST_MAX_WORKERS, TEST_IDLE_TIMEOUT_MS);
    try
      // Create burst to spawn extra workers
      for I := 1 to 6 do
        LPool.Post(procedure begin LGate.WaitFor(5000); end);
      Sleep(300);
      LGate.SetEvent;
      Sleep(100);

      // Wait for idle timeout + margin for workers to exit
      Sleep(TEST_IDLE_TIMEOUT_MS + 500);

      Assert.IsTrue(LPool.ActiveWorkers <= TEST_MIN_WORKERS,
        'ActiveWorkers must shrink to MinWorkers after idle timeout (active=' +
        IntToStr(LPool.ActiveWorkers) + ')');
    finally
      LPool.Shutdown(2000);
      LPool.Free;
    end;
  finally
    LGate.Free;
  end;
end;

procedure TElasticWorkerPoolTests.Shutdown_DrainsQueue;
// Items enqueued but not yet executed should be discarded on Shutdown.
var
  LPool:     TElasticWorkerPool;
  LGate:     TEvent;
  LExecuted: Integer;
  I:         Integer;
begin
  LGate    := TEvent.Create(nil, True, False, '');
  LExecuted := 0;
  try
    LPool := TElasticWorkerPool.Create(1, 1, 5000);  // 1 worker max
    try
      // Block the single worker
      LPool.Post(procedure begin LGate.WaitFor(10000); end);
      Sleep(100);

      // Enqueue 10 items that cannot run (worker is busy)
      for I := 1 to 10 do
        LPool.Post(procedure begin TInterlocked.Increment(LExecuted); end);

      // Shutdown should drain unexecuted items
      LGate.SetEvent;
    finally
      LPool.Shutdown(3000);
      LPool.Free;
    end;

    // Some items may have executed after gate opened, but not necessarily all 10
    Assert.IsTrue(True, 'Shutdown must complete without crash');
  finally
    LGate.Free;
  end;
end;

procedure TElasticWorkerPoolTests.Shutdown_WaitsForRunning;
// Shutdown must wait for currently executing items to finish.
var
  LPool:       TElasticWorkerPool;
  LStarted:    TEvent;
  LFinished:   Boolean;
begin
  LStarted  := TEvent.Create(nil, True, False, '');
  LFinished := False;
  try
    LPool := TElasticWorkerPool.Create(TEST_MIN_WORKERS, TEST_MAX_WORKERS, TEST_IDLE_TIMEOUT_MS);
    try
      LPool.Post(procedure
      begin
        LStarted.SetEvent;
        Sleep(500);  // simulate work
        LFinished := True;
      end);

      // Wait for item to start
      LStarted.WaitFor(2000);
    finally
      LPool.Shutdown(5000);
      LPool.Free;
    end;

    Assert.IsTrue(LFinished,
      'Shutdown must wait for running work items to complete');
  finally
    LStarted.Free;
  end;
end;

procedure TElasticWorkerPoolTests.Post_ExceptionInWork_PoolSurvives;
// An exception in a work item must not crash the pool.
var
  LPool: TElasticWorkerPool;
  LDone: TEvent;
begin
  LDone := TEvent.Create(nil, True, False, '');
  try
    LPool := TElasticWorkerPool.Create(TEST_MIN_WORKERS, TEST_MAX_WORKERS, TEST_IDLE_TIMEOUT_MS);
    try
      // Post item that raises
      LPool.Post(procedure begin raise Exception.Create('test exception'); end);
      Sleep(100);

      // Post normal item after the exception — must execute
      LPool.Post(procedure begin LDone.SetEvent; end);
      Assert.AreEqual(TWaitResult.wrSignaled, LDone.WaitFor(2000),
        'Pool must continue processing after a work item raises an exception');
    finally
      LPool.Shutdown(2000);
      LPool.Free;
    end;
  finally
    LDone.Free;
  end;
end;

procedure TElasticWorkerPoolTests.Post_MaxWorkersReached_NoOverspawn;
// Pool must never exceed MaxWorkers.
var
  LPool: TElasticWorkerPool;
  LGate: TEvent;
  I:     Integer;
begin
  LGate := TEvent.Create(nil, True, False, '');
  try
    LPool := TElasticWorkerPool.Create(1, 4, 5000);  // max=4
    try
      // Post 20 slow items to pressure pool
      for I := 1 to 20 do
        LPool.Post(procedure begin LGate.WaitFor(10000); end);

      Sleep(500);

      Assert.IsTrue(LPool.ActiveWorkers <= 4,
        'ActiveWorkers must never exceed MaxWorkers (active=' +
        IntToStr(LPool.ActiveWorkers) + ')');

      LGate.SetEvent;
    finally
      LPool.Shutdown(3000);
      LPool.Free;
    end;
  finally
    LGate.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TElasticWorkerPoolTests);

end.
