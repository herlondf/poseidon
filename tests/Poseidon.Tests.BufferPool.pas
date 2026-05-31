unit Poseidon.Tests.BufferPool;

// DUnitX unit tests for Poseidon.Net.Pool.Buffer (TBufferPool).
//
// Covers:
//   Acquire(0)            → Tier-0 (8 KB) buffer
//   Acquire(n<=8192)      → Tier-0
//   Acquire(n<=65536)     → Tier-1
//   Acquire(n<=524288)    → Tier-2
//   Acquire(n>524288)     → oversized heap alloc (correct length)
//   Release → Acquire     → buffer is reused (same reference identity via Length)
//   Release oversized     → does not crash, ABuf becomes nil
//   Concurrent Acquire/Release → no deadlock / corruption (smoke test)

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TBufferPoolTests = class
  public
    [Test] procedure Acquire_ZeroSize_ReturnsTier0;
    [Test] procedure Acquire_Tier0Boundary_ReturnsTier0;
    [Test] procedure Acquire_OneByteBeyondTier0_ReturnsTier1;
    [Test] procedure Acquire_Tier1Boundary_ReturnsTier1;
    [Test] procedure Acquire_OneByteBeyondTier1_ReturnsTier2;
    [Test] procedure Acquire_Tier2Boundary_ReturnsTier2;
    [Test] procedure Acquire_OversizedBypass_ReturnsExactSize;
    [Test] procedure Release_Tier0_BufBecomesNil;
    [Test] procedure Release_Tier1_BufBecomesNil;
    [Test] procedure Release_Tier2_BufBecomesNil;
    [Test] procedure Release_Oversized_BufBecomesNil;
    [Test] procedure ReleaseAndAcquire_Tier0_BufferReused;
    [Test] procedure ReleaseAndAcquire_Tier1_BufferReused;
    [Test] procedure ReleaseAndAcquire_Tier2_BufferReused;
    [Test] procedure Acquire_SmallRequest_ReturnsTier0;
    [Test] procedure Acquire_1_ReturnsTier0;
    [Test] procedure ConcurrentAcquireRelease_NoDeadlock;
    [Test] procedure Release_NilBuffer_DoesNotCrash;
    [Test] procedure ConcurrentAcquireRelease_MultiTier_NoDeadlock;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Threading,
  Poseidon.Net.Pool.Buffer;

procedure TBufferPoolTests.Acquire_ZeroSize_ReturnsTier0;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(0);
  try
    Assert.AreEqual(POOL_TIER0_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_Tier0Boundary_ReturnsTier0;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER0_SIZE);
  try
    Assert.AreEqual(POOL_TIER0_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_OneByteBeyondTier0_ReturnsTier1;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER0_SIZE + 1);
  try
    Assert.AreEqual(POOL_TIER1_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_Tier1Boundary_ReturnsTier1;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER1_SIZE);
  try
    Assert.AreEqual(POOL_TIER1_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_OneByteBeyondTier1_ReturnsTier2;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER1_SIZE + 1);
  try
    Assert.AreEqual(POOL_TIER2_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_Tier2Boundary_ReturnsTier2;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER2_SIZE);
  try
    Assert.AreEqual(POOL_TIER2_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_OversizedBypass_ReturnsExactSize;
var
  LBuf:  TBytes;
  LSize: Integer;
begin
  LSize := POOL_TIER2_SIZE + 1;
  LBuf  := TBufferPool.Acquire(LSize);
  try
    Assert.AreEqual(LSize, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Release_Tier0_BufBecomesNil;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(0);
  TBufferPool.Release(LBuf);
  Assert.IsNull(LBuf);
end;

procedure TBufferPoolTests.Release_Tier1_BufBecomesNil;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER0_SIZE + 1);
  TBufferPool.Release(LBuf);
  Assert.IsNull(LBuf);
end;

procedure TBufferPoolTests.Release_Tier2_BufBecomesNil;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER1_SIZE + 1);
  TBufferPool.Release(LBuf);
  Assert.IsNull(LBuf);
end;

procedure TBufferPoolTests.Release_Oversized_BufBecomesNil;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER2_SIZE + 100);
  TBufferPool.Release(LBuf);
  Assert.IsNull(LBuf);
end;

procedure TBufferPoolTests.ReleaseAndAcquire_Tier0_BufferReused;
var
  LFirst:  TBytes;
  LSecond: TBytes;
begin
  // After releasing, Acquire should return a buffer of the same size
  // (verifies that the pool stack is functional, not that it's the same pointer —
  //  managed TBytes identity is opaque, length is the observable contract).
  LFirst := TBufferPool.Acquire(0);
  TBufferPool.Release(LFirst);
  LSecond := TBufferPool.Acquire(0);
  try
    Assert.AreEqual(POOL_TIER0_SIZE, Length(LSecond));
  finally
    TBufferPool.Release(LSecond);
  end;
end;

procedure TBufferPoolTests.ReleaseAndAcquire_Tier1_BufferReused;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER0_SIZE + 1);
  TBufferPool.Release(LBuf);
  LBuf := TBufferPool.Acquire(POOL_TIER0_SIZE + 1);
  try
    Assert.AreEqual(POOL_TIER1_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.ReleaseAndAcquire_Tier2_BufferReused;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(POOL_TIER1_SIZE + 1);
  TBufferPool.Release(LBuf);
  LBuf := TBufferPool.Acquire(POOL_TIER1_SIZE + 1);
  try
    Assert.AreEqual(POOL_TIER2_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_SmallRequest_ReturnsTier0;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(100);
  try
    Assert.AreEqual(POOL_TIER0_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.Acquire_1_ReturnsTier0;
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(1);
  try
    Assert.AreEqual(POOL_TIER0_SIZE, Length(LBuf));
  finally
    TBufferPool.Release(LBuf);
  end;
end;

procedure TBufferPoolTests.ConcurrentAcquireRelease_NoDeadlock;
// Smoke test: 8 parallel tasks each Acquire+Release 200 times.
// If TMonitor is broken this will deadlock or AV.
const
  TASK_COUNT  = 8;
  ITER_COUNT  = 200;
var
  LTasks: array[0..TASK_COUNT - 1] of ITask;
  I:      Integer;
begin
  for I := 0 to TASK_COUNT - 1 do
  begin
    LTasks[I] := TTask.Run(
      procedure
      var
        J:    Integer;
        LBuf: TBytes;
      begin
        for J := 0 to ITER_COUNT - 1 do
        begin
          LBuf := TBufferPool.Acquire(0);
          TBufferPool.Release(LBuf);
        end;
      end);
  end;
  TTask.WaitForAll(LTasks);
  // If we reach here without hanging/crashing: pass.
  Assert.Pass;
end;

procedure TBufferPoolTests.Release_NilBuffer_DoesNotCrash;
var
  LBuf: TBytes;
begin
  // A nil/empty TBytes should be released without crash or exception.
  LBuf := nil;
  Assert.WillNotRaise(
    procedure begin TBufferPool.Release(LBuf); end);
  Assert.AreEqual(0, Length(LBuf));
end;

procedure TBufferPoolTests.ConcurrentAcquireRelease_MultiTier_NoDeadlock;
// Stress test across all three tiers simultaneously.
const
  TASK_COUNT = 6;
  ITER_COUNT = 100;
var
  LTasks: array[0..TASK_COUNT - 1] of ITask;
  I:      Integer;
begin
  for I := 0 to TASK_COUNT - 1 do
  begin
    LTasks[I] := TTask.Run(
      procedure
      var
        J:     Integer;
        LBuf0: TBytes;
        LBuf1: TBytes;
        LBuf2: TBytes;
      begin
        for J := 0 to ITER_COUNT - 1 do
        begin
          LBuf0 := TBufferPool.Acquire(0);
          LBuf1 := TBufferPool.Acquire(POOL_TIER0_SIZE + 1);
          LBuf2 := TBufferPool.Acquire(POOL_TIER1_SIZE + 1);
          TBufferPool.Release(LBuf0);
          TBufferPool.Release(LBuf1);
          TBufferPool.Release(LBuf2);
        end;
      end);
  end;
  TTask.WaitForAll(LTasks);
  Assert.Pass;
end;

initialization
  TDUnitX.RegisterTestFixture(TBufferPoolTests);

end.
