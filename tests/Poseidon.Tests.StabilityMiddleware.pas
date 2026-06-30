unit Poseidon.Tests.StabilityMiddleware;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TBodyLimitTests = class
  public
    [Test] procedure SmallBody_PassesThrough;
    [Test] procedure LargeBody_Returns413;
    [Test] procedure ZeroContentLength_PassesThrough;
  end;

  [TestFixture]
  TRequestIDTests = class
  public
    [Test] procedure NoIncomingID_GeneratesGUID;
    [Test] procedure IncomingID_EchoedBack;
    [Test] procedure ID_StoredInParams;
  end;

  [TestFixture]
  TCircuitBreakerTests = class
  public
    [Test] procedure Closed_AllowsRequests;
    [Test] procedure OpenAfterThreshold_Returns503;
    [Test] procedure HalfOpen_AllowsOneRequest;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Callback,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Middleware.BodyLimit,
  Poseidon.Middleware.RequestID,
  Poseidon.Middleware.CircuitBreaker,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse;

{ TBodyLimitTests }

procedure TBodyLimitTests.SmallBody_PassesThrough;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetContent('{"x":1}');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareBodyLimit.New(1024);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsTrue(LNextCalled, 'Next should be called for small body');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TBodyLimitTests.LargeBody_Returns413;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetContent(StringOfChar('x', 2048));
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareBodyLimit.New(1024);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsFalse(LNextCalled, 'Next should not be called for oversized body');
    Assert.AreEqual(413, LMockRes.SentStatusCode);
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TBodyLimitTests.ZeroContentLength_PassesThrough;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareBodyLimit.New(1024);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsTrue(LNextCalled, 'Next should be called when Content-Length is 0');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

{ TRequestIDTests }

procedure TRequestIDTests.NoIncomingID_GeneratesGUID;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  LMiddleware := TPoseidonMiddlewareRequestID.New();
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsFalse(LMockRes.SentHeaders.Values['X-Request-ID'].IsEmpty,
      'Response should contain X-Request-ID');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TRequestIDTests.IncomingID_EchoedBack;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
const
  TEST_ID = 'my-request-123';
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('X-Request-ID', TEST_ID);
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  LMiddleware := TPoseidonMiddlewareRequestID.New();
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.AreEqual(TEST_ID, LMockRes.SentHeaders.Values['X-Request-ID']);
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TRequestIDTests.ID_StoredInParams;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
const
  TEST_ID = 'stored-id-456';
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('X-Request-ID', TEST_ID);
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  LMiddleware := TPoseidonMiddlewareRequestID.New();
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.AreEqual(TEST_ID, LReq.Params.Get('__request_id'));
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

{ TCircuitBreakerTests }

procedure TCircuitBreakerTests.Closed_AllowsRequests;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareCircuitBreaker.New(50, 60, 30);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsTrue(LNextCalled, 'Circuit closed: handler should be called');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TCircuitBreakerTests.OpenAfterThreshold_Returns503;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
  I:           Integer;
begin
  // 50% error threshold, send 10 failures to trip the breaker
  LMiddleware := TPoseidonMiddlewareCircuitBreaker.New(50, 60, 30);
  LNext := procedure begin raise Exception.Create('simulated error'); end;
  for I := 1 to 10 do
  begin
    LMockReq := TMockWebRequest.Create;
    LMockRes := TMockWebResponse.Create(LMockReq);
    LReq     := TPoseidonRequest.Create(LMockReq);
    LRes     := TPoseidonResponse.Create(LMockRes);
    try
      LMiddleware(LReq, LRes, LNext);
    except
      // swallow
    end;
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
  // Circuit should now be open
  LMockReq    := TMockWebRequest.Create;
  LMockRes    := TMockWebResponse.Create(LMockReq);
  LReq        := TPoseidonRequest.Create(LMockReq);
  LRes        := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsFalse(LNextCalled, 'Circuit open: handler should NOT be called');
    Assert.AreEqual(503, LMockRes.SentStatusCode);
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TCircuitBreakerTests.HalfOpen_AllowsOneRequest;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  // open duration 0s so it immediately becomes HalfOpen
  LMiddleware := TPoseidonMiddlewareCircuitBreaker.New(1, 60, 0);
  // Trip with one failure
  LMockReq := TMockWebRequest.Create;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq     := TPoseidonRequest.Create(LMockReq);
  LRes     := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin raise Exception.Create('fail'); end;
  try
    LMiddleware(LReq, LRes, LNext);
  except end;
  LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  // Next request: open duration = 0 → HalfOpen → allowed
  LMockReq    := TMockWebRequest.Create;
  LMockRes    := TMockWebResponse.Create(LMockReq);
  LReq        := TPoseidonRequest.Create(LMockReq);
  LRes        := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsTrue(LNextCalled, 'HalfOpen: one request should be allowed');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TBodyLimitTests);
  TDUnitX.RegisterTestFixture(TRequestIDTests);
  TDUnitX.RegisterTestFixture(TCircuitBreakerTests);

end.
