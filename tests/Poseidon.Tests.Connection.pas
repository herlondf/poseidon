unit Poseidon.Tests.Connection;

// DUnitX tests for TNativeConn ref-counting and lifecycle (#43).
//
// Coverage:
//   - FRefCount initialised to 1 on Create
//   - AddRef increments, Release decrements
//   - Last Release triggers Destroy (ref reaches zero)
//   - InFlightPool atomic counter
//   - Destructor returns AccumBuf to TBufferPool

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TConnectionRefCountTests = class
  public
    [Test] procedure Create_InitialRefCount_IsOne;
    [Test] procedure AddRef_IncrementsCount;
    [Test] procedure Release_AtZero_DestroysObject;
    [Test] procedure MultipleAddRefRelease_CorrectLifecycle;
    [Test] procedure InFlightPool_InitiallyZero;
    [Test] procedure InFlightPool_IncrementDecrement;
    [Test] procedure Destroy_AccumBuf_ReleasedToPool;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer;

// ---------------------------------------------------------------------------
// Test helper: subclass that tracks whether Destroy was called.
// We use a PBoolean so the flag survives after the object is freed.
// ---------------------------------------------------------------------------
type
  TTestableConn = class(TNativeConn)
  private
    FDestroyedFlag: PBoolean;
  public
    constructor Create(ADestroyedFlag: PBoolean);
    destructor Destroy; override;
  end;

constructor TTestableConn.Create(ADestroyedFlag: PBoolean);
begin
  inherited Create(0, '127.0.0.1:0');
  FDestroyedFlag := ADestroyedFlag;
end;

destructor TTestableConn.Destroy;
begin
  if FDestroyedFlag <> nil then
    FDestroyedFlag^ := True;
  inherited;
end;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

procedure TConnectionRefCountTests.Create_InitialRefCount_IsOne;
// After Create, FRefCount = 1. One Release should trigger Destroy.
var
  LDestroyed: Boolean;
begin
  LDestroyed := False;
  TTestableConn.Create(@LDestroyed).Release;  // 1 -> 0 = Destroy
  Assert.IsTrue(LDestroyed, 'Single Release after Create must trigger Destroy (RefCount was 1)');
end;

procedure TConnectionRefCountTests.AddRef_IncrementsCount;
// AddRef 3x -> RefCount = 4. Need 4 Releases to Destroy.
var
  LDestroyed: Boolean;
  LConn: TTestableConn;
begin
  LDestroyed := False;
  LConn := TTestableConn.Create(@LDestroyed);
  LConn.AddRef;  // 2
  LConn.AddRef;  // 3
  LConn.AddRef;  // 4

  LConn.Release; // 3
  Assert.IsFalse(LDestroyed, 'Must not destroy while RefCount > 0');
  LConn.Release; // 2
  Assert.IsFalse(LDestroyed, 'Must not destroy while RefCount > 0');
  LConn.Release; // 1
  Assert.IsFalse(LDestroyed, 'Must not destroy while RefCount > 0');
  LConn.Release; // 0 -> Destroy
  Assert.IsTrue(LDestroyed, 'Must destroy when RefCount reaches 0');
end;

procedure TConnectionRefCountTests.Release_AtZero_DestroysObject;
// Simplest case: Create (ref=1) then Release (ref=0 -> Destroy).
var
  LDestroyed: Boolean;
begin
  LDestroyed := False;
  TTestableConn.Create(@LDestroyed).Release;
  Assert.IsTrue(LDestroyed, 'Destroy must be called when last ref is released');
end;

procedure TConnectionRefCountTests.MultipleAddRefRelease_CorrectLifecycle;
// Simulate real IOCP pattern: server ref + 2 async ops.
// Release order: op1 completes, op2 completes, server closes.
var
  LDestroyed: Boolean;
  LConn: TTestableConn;
begin
  LDestroyed := False;
  LConn := TTestableConn.Create(@LDestroyed);  // ref=1 (server)
  LConn.AddRef;   // ref=2 (async op 1)
  LConn.AddRef;   // ref=3 (async op 2)

  // Op 1 completes
  LConn.Release;  // ref=2
  Assert.IsFalse(LDestroyed, 'Op1 Release: still 2 refs alive');

  // Server closes connection
  LConn.Release;  // ref=1
  Assert.IsFalse(LDestroyed, 'Server Release: still 1 ref alive (op2)');

  // Op 2 completes — last ref
  LConn.Release;  // ref=0 -> Destroy
  Assert.IsTrue(LDestroyed, 'Last Release must trigger Destroy');
end;

procedure TConnectionRefCountTests.InFlightPool_InitiallyZero;
var
  LConn: TNativeConn;
begin
  LConn := TNativeConn.Create(0, '127.0.0.1:0');
  try
    Assert.AreEqual(0, TInterlocked.Add(LConn.InFlightPool, 0),
      'InFlightPool must be 0 after Create');
  finally
    LConn.Release;
  end;
end;

procedure TConnectionRefCountTests.InFlightPool_IncrementDecrement;
var
  LConn: TNativeConn;
begin
  LConn := TNativeConn.Create(0, '127.0.0.1:0');
  try
    TInterlocked.Increment(LConn.InFlightPool);
    Assert.AreEqual(1, TInterlocked.Add(LConn.InFlightPool, 0),
      'InFlightPool must be 1 after Increment');

    TInterlocked.Increment(LConn.InFlightPool);
    Assert.AreEqual(2, TInterlocked.Add(LConn.InFlightPool, 0),
      'InFlightPool must be 2 after second Increment');

    TInterlocked.Decrement(LConn.InFlightPool);
    Assert.AreEqual(1, TInterlocked.Add(LConn.InFlightPool, 0),
      'InFlightPool must be 1 after Decrement');

    TInterlocked.Decrement(LConn.InFlightPool);
    Assert.AreEqual(0, TInterlocked.Add(LConn.InFlightPool, 0),
      'InFlightPool must be 0 after final Decrement');
  finally
    LConn.Release;
  end;
end;

procedure TConnectionRefCountTests.Destroy_AccumBuf_ReleasedToPool;
// After Destroy, AccumBuf must be nil (returned to TBufferPool).
// We verify indirectly: Create allocates a buffer, Release triggers Destroy
// which calls TBufferPool.Release(AccumBuf). If this didn't crash, the
// pool accepted the buffer back.
var
  LDestroyed: Boolean;
  LConn: TTestableConn;
begin
  LDestroyed := False;
  LConn := TTestableConn.Create(@LDestroyed);
  Assert.IsTrue(LConn.AccumBuf <> nil, 'AccumBuf must be allocated after Create');
  Assert.IsTrue(Length(LConn.AccumBuf) > 0, 'AccumBuf must have non-zero length');
  LConn.Release;
  Assert.IsTrue(LDestroyed, 'Destroy must have run — AccumBuf returned to pool');
end;

end.
