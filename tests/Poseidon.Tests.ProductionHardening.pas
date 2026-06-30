unit Poseidon.Tests.ProductionHardening;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSecurityMiddlewareTests = class
  public
    [Test] procedure DefaultsSetAllStandardHeaders;
    [Test] procedure HSTSDisabledWhenMaxAgeZero;
    [Test] procedure CSPEmptyStringOmitsHeader;
    [Test] procedure FluentBuilderReturnsSelf;
    [Test] procedure HSTSIncludeSubDomainsAndPreload;
  end;

  [TestFixture]
  THealthCheckMiddlewareTests = class
  public
    [Test] procedure LiveEndpointAlwaysReturns200;
    [Test] procedure HealthEndpointWithNoChecksReturns200;
    [Test] procedure HealthEndpointAllPassReturnsOK;
    [Test] procedure HealthEndpointAnyFailureReturns503;
    [Test] procedure CheckExceptionTreatedAsFailure;
    [Test] procedure NonHealthPathFallsThroughNext;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  Poseidon.Callback,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse,
  Poseidon.Middleware.Security,
  Poseidon.Middleware.HealthCheck;

function InvokeMiddleware(const ACallback: TPoseidonCallback;
  const APath: string): TMockWebResponse;
var
  LReq:     TMockWebRequest;
  LRes:     TMockWebResponse;
  LPReq:    TPoseidonRequest;
  LPRes:    TPoseidonResponse;
  LCalled:  Boolean;
begin
  LReq := TMockWebRequest.Create;
  LReq.SetMethod('GET');
  LReq.SetPathInfo(APath);
  LRes := TMockWebResponse.Create(LReq);
  LPReq := TPoseidonRequest.Create(LReq);
  LPRes := TPoseidonResponse.Create(LRes);
  try
    LCalled := False;
    ACallback(LPReq, LPRes, procedure begin LCalled := True; end);
  finally
    LPReq.Free;
    LPRes.Free;
    LReq.Free;
  end;
  Result := LRes;
end;

{ TSecurityMiddlewareTests }

procedure TSecurityMiddlewareTests.DefaultsSetAllStandardHeaders;
var
  LRes: TMockWebResponse;
begin
  LRes := InvokeMiddleware(TPoseidonMiddlewareSecurity.Defaults(), '/anything');
  try
    Assert.IsTrue(LRes.SentHeaders.Values['Strict-Transport-Security']
      .StartsWith('max-age=31536000'), 'HSTS header missing or wrong default');
    Assert.AreEqual('default-src ''self''',
      LRes.SentHeaders.Values['Content-Security-Policy']);
    Assert.AreEqual('DENY', LRes.SentHeaders.Values['X-Frame-Options']);
    Assert.AreEqual('nosniff', LRes.SentHeaders.Values['X-Content-Type-Options']);
    Assert.AreEqual('strict-origin-when-cross-origin',
      LRes.SentHeaders.Values['Referrer-Policy']);
  finally
    LRes.Free;
  end;
end;

procedure TSecurityMiddlewareTests.HSTSDisabledWhenMaxAgeZero;
var
  LRes: TMockWebResponse;
begin
  LRes := InvokeMiddleware(
    TPoseidonMiddlewareSecurity.New.HSTS(0).Build(), '/anything');
  try
    Assert.AreEqual('', LRes.SentHeaders.Values['Strict-Transport-Security'],
      'HSTS should be omitted when max-age = 0');
  finally
    LRes.Free;
  end;
end;

procedure TSecurityMiddlewareTests.CSPEmptyStringOmitsHeader;
var
  LRes: TMockWebResponse;
begin
  LRes := InvokeMiddleware(
    TPoseidonMiddlewareSecurity.New.CSP('').Build(), '/anything');
  try
    Assert.AreEqual('', LRes.SentHeaders.Values['Content-Security-Policy']);
  finally
    LRes.Free;
  end;
end;

procedure TSecurityMiddlewareTests.FluentBuilderReturnsSelf;
var
  LBuilder, LChained: TPoseidonMiddlewareSecurity;
begin
  LBuilder := TPoseidonMiddlewareSecurity.New;
  LChained := LBuilder.HSTS(3600).CSP('test').XFrameOptions('SAMEORIGIN');
  Assert.AreSame(LBuilder, LChained, 'Fluent methods should return Self');
  LBuilder.Build();  // Build() frees the builder internally after capturing
end;

procedure TSecurityMiddlewareTests.HSTSIncludeSubDomainsAndPreload;
var
  LRes:   TMockWebResponse;
  LValue: string;
begin
  LRes := InvokeMiddleware(
    TPoseidonMiddlewareSecurity.New.HSTS(60, True, True).Build(), '/anything');
  try
    LValue := LRes.SentHeaders.Values['Strict-Transport-Security'];
    Assert.IsTrue(LValue.Contains('max-age=60'), 'max-age wrong: ' + LValue);
    Assert.IsTrue(LValue.Contains('includeSubDomains'), 'includeSubDomains missing');
    Assert.IsTrue(LValue.Contains('preload'), 'preload missing');
  finally
    LRes.Free;
  end;
end;

{ THealthCheckMiddlewareTests }

procedure THealthCheckMiddlewareTests.LiveEndpointAlwaysReturns200;
var
  LRes:  TMockWebResponse;
  LMid:  TPoseidonCallback;
  LH:    TPoseidonMiddlewareHealthCheck;
begin
  LH := TPoseidonMiddlewareHealthCheck.New;
  LH.AddCheck('always-fail',
    function: THealthCheckResult begin Result := THealthCheckResult.Failed('always'); end);
  LMid := LH.Build();
  LRes := InvokeMiddleware(LMid, '/health/live');
  try
    Assert.AreEqual(200, LRes.SentStatusCode,
      'Liveness must always return 200 regardless of check results');
    Assert.IsTrue(LRes.SentContent.Contains('"status":"ok"'));
  finally
    LRes.Free;
  end;
end;

procedure THealthCheckMiddlewareTests.HealthEndpointWithNoChecksReturns200;
var
  LRes: TMockWebResponse;
begin
  LRes := InvokeMiddleware(TPoseidonMiddlewareHealthCheck.New.Build(), '/health');
  try
    Assert.AreEqual(200, LRes.SentStatusCode);
    Assert.IsTrue(LRes.SentContent.Contains('"status":"ok"'));
  finally
    LRes.Free;
  end;
end;

procedure THealthCheckMiddlewareTests.HealthEndpointAllPassReturnsOK;
var
  LRes:  TMockWebResponse;
  LH:    TPoseidonMiddlewareHealthCheck;
begin
  LH := TPoseidonMiddlewareHealthCheck.New;
  LH.AddCheck('db', function: THealthCheckResult begin Result := THealthCheckResult.OK; end);
  LH.AddCheck('cache', function: THealthCheckResult begin Result := THealthCheckResult.OK; end);
  LRes := InvokeMiddleware(LH.Build(), '/health');
  try
    Assert.AreEqual(200, LRes.SentStatusCode);
    Assert.IsTrue(LRes.SentContent.Contains('"status":"ok"'));
    Assert.IsTrue(LRes.SentContent.Contains('"db"'));
    Assert.IsTrue(LRes.SentContent.Contains('"cache"'));
  finally
    LRes.Free;
  end;
end;

procedure THealthCheckMiddlewareTests.HealthEndpointAnyFailureReturns503;
var
  LRes:  TMockWebResponse;
  LH:    TPoseidonMiddlewareHealthCheck;
begin
  LH := TPoseidonMiddlewareHealthCheck.New;
  LH.AddCheck('ok-check', function: THealthCheckResult begin Result := THealthCheckResult.OK; end);
  LH.AddCheck('failing-check',
    function: THealthCheckResult begin Result := THealthCheckResult.Failed('connection refused'); end);
  LRes := InvokeMiddleware(LH.Build(), '/health');
  try
    Assert.AreEqual(503, LRes.SentStatusCode);
    Assert.IsTrue(LRes.SentContent.Contains('"status":"degraded"'));
    Assert.IsTrue(LRes.SentContent.Contains('connection refused'));
  finally
    LRes.Free;
  end;
end;

procedure THealthCheckMiddlewareTests.CheckExceptionTreatedAsFailure;
var
  LRes:  TMockWebResponse;
  LH:    TPoseidonMiddlewareHealthCheck;
begin
  LH := TPoseidonMiddlewareHealthCheck.New;
  LH.AddCheck('boom',
    function: THealthCheckResult
    begin
      raise EAccessViolation.Create('simulated failure');
    end);
  LRes := InvokeMiddleware(LH.Build(), '/health/ready');
  try
    Assert.AreEqual(503, LRes.SentStatusCode);
    Assert.IsTrue(LRes.SentContent.Contains('simulated failure'));
  finally
    LRes.Free;
  end;
end;

procedure THealthCheckMiddlewareTests.NonHealthPathFallsThroughNext;
var
  LReq:    TMockWebRequest;
  LRes:    TMockWebResponse;
  LPReq:   TPoseidonRequest;
  LPRes:   TPoseidonResponse;
  LCalled: Boolean;
  LMid:    TPoseidonCallback;
begin
  LMid := TPoseidonMiddlewareHealthCheck.New.Build();
  LReq := TMockWebRequest.Create;
  LReq.SetMethod('GET');
  LReq.SetPathInfo('/api/users');
  LRes := TMockWebResponse.Create(LReq);
  LPReq := TPoseidonRequest.Create(LReq);
  LPRes := TPoseidonResponse.Create(LRes);
  try
    LCalled := False;
    LMid(LPReq, LPRes, procedure begin LCalled := True; end);
    Assert.IsTrue(LCalled, 'Next() must be invoked for non-health paths');
  finally
    LPReq.Free;
    LPRes.Free;
    LRes.Free;
    LReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSecurityMiddlewareTests);
  TDUnitX.RegisterTestFixture(THealthCheckMiddlewareTests);

end.
