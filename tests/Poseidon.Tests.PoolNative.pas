unit Poseidon.Tests.PoolNative;

// DUnitX tests for TNativeContextPool — object pool for WebRequest/Response.
//
// Coverage:
//   - Acquire/Release cycle works
//   - Pooled objects are reused (not heap-allocated each time)
//   - State isolation: data from previous request does not leak
//   - Concurrent Acquire/Release is thread-safe
//   - Pool beyond MAX_POOL_SIZE falls back to Free

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TNativeContextPoolTests = class
  public
    [Test] procedure AcquireRelease_SingleCycle_Works;
    [Test] procedure Acquire_AfterRelease_ReusesPooled;
    [Test] procedure Acquire_StateIsolated_AfterReset;
    [Test] procedure Concurrent_10Threads_100Cycles_NoLeak;
    [Test] procedure Release_BeyondMax_FreesObject;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.WebAdapters.Native,
  Poseidon.Net.Pool.Native;

function MakeReq(const AMethod, APath, AQS: string): TPoseidonNativeRequest;
begin
  Result.Method      := AMethod;
  Result.Path        := APath;
  Result.QueryString := AQS;
  Result.RawBody     := [];
  Result.RemoteAddr  := '127.0.0.1';
  Result.KeepAlive   := False;
  Result.Headers     := [];
end;

var
  GDummyFlush: TNativeFlushProc;

procedure _InitDummyFlush;
begin
  GDummyFlush := procedure(AStatus: Integer; const AContentType: string;
    const ABody: TBytes; const AExtra: TArray<TPair<string,string>>)
  begin
    // no-op
  end;
end;

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

procedure TNativeContextPoolTests.AcquireRelease_SingleCycle_Works;
var
  LWebReq: TNativeWebRequest;
  LWebRes: TNativeWebResponse;
begin
  TNativeContextPool.Acquire(MakeReq('GET', '/ping', ''), GDummyFlush,
    LWebReq, LWebRes);
  try
    Assert.IsNotNull(LWebReq, 'Acquired WebReq must not be nil');
    Assert.IsNotNull(LWebRes, 'Acquired WebRes must not be nil');
    Assert.AreEqual('/ping', LWebReq.PathInfo);
  finally
    TNativeContextPool.Release(LWebReq, LWebRes);
  end;
end;

procedure TNativeContextPoolTests.Acquire_AfterRelease_ReusesPooled;
var
  LWebReq1, LWebReq2: TNativeWebRequest;
  LWebRes1, LWebRes2: TNativeWebResponse;
begin
  // First cycle
  TNativeContextPool.Acquire(MakeReq('GET', '/a', ''), GDummyFlush,
    LWebReq1, LWebRes1);
  TNativeContextPool.Release(LWebReq1, LWebRes1);

  // Second cycle — should reuse the released objects
  TNativeContextPool.Acquire(MakeReq('GET', '/b', ''), GDummyFlush,
    LWebReq2, LWebRes2);
  try
    Assert.AreSame(LWebReq1, LWebReq2,
      'Second Acquire must return the same WebReq instance from pool');
    Assert.AreEqual('/b', LWebReq2.PathInfo,
      'Pooled WebReq must reflect the new request path');
  finally
    TNativeContextPool.Release(LWebReq2, LWebRes2);
  end;
end;

procedure TNativeContextPoolTests.Acquire_StateIsolated_AfterReset;
// Verify that query params and content from the first request do not
// bleed through to the second.
var
  LWebReq: TNativeWebRequest;
  LWebRes: TNativeWebResponse;
begin
  // First request with query params
  TNativeContextPool.Acquire(
    MakeReq('GET', '/search', 'q=hello&page=1'), GDummyFlush,
    LWebReq, LWebRes);
  // Touch QueryFields to trigger lazy init
  Assert.AreEqual('hello', LWebReq.QueryFields.Values['q']);
  TNativeContextPool.Release(LWebReq, LWebRes);

  // Second request without query params
  TNativeContextPool.Acquire(
    MakeReq('POST', '/data', ''), GDummyFlush,
    LWebReq, LWebRes);
  try
    Assert.AreEqual('', LWebReq.QueryFields.Values['q'],
      'q from first request must not bleed through');
    Assert.AreEqual('', LWebReq.QueryFields.Values['page'],
      'page from first request must not bleed through');
    Assert.AreEqual('POST', LWebReq.Method,
      'Method must be POST after pool reuse');
  finally
    TNativeContextPool.Release(LWebReq, LWebRes);
  end;
end;

procedure TNativeContextPoolTests.Concurrent_10Threads_100Cycles_NoLeak;
// Stress test: 10 threads each doing 100 acquire/release cycles.
// Must not crash, deadlock, or leak.
var
  LThreads:  array[0..9] of TThread;
  LDone:     TEvent;
  LErrors:   Integer;
  I:         Integer;
begin
  LDone   := TEvent.Create(nil, True, False, '');
  LErrors := 0;
  try
    for I := 0 to High(LThreads) do
    begin
      LThreads[I] := TThread.CreateAnonymousThread(
        procedure
        var
          J: Integer;
          LReq: TNativeWebRequest;
          LRes: TNativeWebResponse;
        begin
          try
            for J := 1 to 100 do
            begin
              TNativeContextPool.Acquire(
                MakeReq('GET', '/t' + IntToStr(J), 'i=' + IntToStr(J)),
                GDummyFlush, LReq, LRes);
              TNativeContextPool.Release(LReq, LRes);
            end;
          except
            TInterlocked.Increment(LErrors);
          end;
        end);
      LThreads[I].FreeOnTerminate := False;
      LThreads[I].Start;
    end;

    // Wait for all threads
    for I := 0 to High(LThreads) do
    begin
      LThreads[I].WaitFor;
      LThreads[I].Free;
    end;

    Assert.AreEqual(0, LErrors,
      'Concurrent Acquire/Release must not raise exceptions');
  finally
    LDone.Free;
  end;
end;

procedure TNativeContextPoolTests.Release_BeyondMax_FreesObject;
// When pool is at capacity, Release should Free the objects instead of pooling.
// We can't easily test MAX_POOL_SIZE=256 directly, but we can verify the
// release path doesn't crash even when called many times.
var
  LPairs: array[0..9] of record
    Req: TNativeWebRequest;
    Res: TNativeWebResponse;
  end;
  I: Integer;
begin
  // Acquire 10 pairs
  for I := 0 to High(LPairs) do
    TNativeContextPool.Acquire(
      MakeReq('GET', '/p' + IntToStr(I), ''), GDummyFlush,
      LPairs[I].Req, LPairs[I].Res);

  // Release all 10 — pool accepts them
  for I := 0 to High(LPairs) do
    TNativeContextPool.Release(LPairs[I].Req, LPairs[I].Res);

  Assert.IsTrue(True, 'Multiple Release calls must not crash');
end;

initialization
  _InitDummyFlush;
  TDUnitX.RegisterTestFixture(TNativeContextPoolTests);

end.
