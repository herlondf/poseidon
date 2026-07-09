unit Poseidon.Tests.Middleware.HealthCheck;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  THealthCheckMiddlewareTests = class
  public
    [Test]
    procedure LiveReturns200;
    [Test]
    procedure HealthReturnsOkWhenAllPass;
    [Test]
    procedure HealthReturns503WhenCheckFails;
    [Test]
    procedure NonHealthPathCallsNext;
    [Test]
    procedure ReadyReturnsOkWhenAllPass;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.HealthCheck;

procedure THealthCheckMiddlewareTests.LiveReturns200;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := TPoseidonHealthCheck.Create.Build();
  LCtx := TContextBuilder.New.Path('/health/live').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure THealthCheckMiddlewareTests.HealthReturnsOkWhenAllPass;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := TPoseidonHealthCheck.Create
    .AddCheck('db', function: THealthCheckResult begin Result := THealthCheckResult.OK; end)
    .Build();
  LCtx := TContextBuilder.New.Path('/health').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.IsTrue(BodyAsString(LCtx).Contains('"status":"ok"'));
end;

procedure THealthCheckMiddlewareTests.HealthReturns503WhenCheckFails;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := TPoseidonHealthCheck.Create
    .AddCheck('redis', function: THealthCheckResult begin Result := THealthCheckResult.Failed('timeout'); end)
    .Build();
  LCtx := TContextBuilder.New.Path('/health').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(503, LCtx.Status);
  Assert.IsTrue(BodyAsString(LCtx).Contains('"status":"degraded"'));
end;

procedure THealthCheckMiddlewareTests.NonHealthPathCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LMw := TPoseidonHealthCheck.Create.Build();
  LCtx := TContextBuilder.New.Path('/api/data').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
  Assert.IsFalse(LCtx.Handled);
end;

procedure THealthCheckMiddlewareTests.ReadyReturnsOkWhenAllPass;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := TPoseidonHealthCheck.Create
    .AddCheck('db', function: THealthCheckResult begin Result := THealthCheckResult.OK; end)
    .Build();
  LCtx := TContextBuilder.New.Path('/health/ready').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
end;

initialization
  TDUnitX.RegisterTestFixture(THealthCheckMiddlewareTests);

end.
