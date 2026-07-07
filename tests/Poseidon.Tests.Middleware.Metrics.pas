unit Poseidon.Tests.Middleware.Metrics;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TMetricsMiddlewareTests = class
  public
    [Test]
    procedure MetricsEndpointReturns200;
    [Test]
    procedure MetricsEndpointReturnsPrometheusFormat;
    [Test]
    procedure NormalRequestCallsNext;
    [Test]
    procedure RecordsRequestAfterHandler;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Metrics;

procedure TMetricsMiddlewareTests.MetricsEndpointReturns200;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := MetricsMiddleware('/metrics');
  LCtx := TContextBuilder.New.Path('/metrics').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TMetricsMiddlewareTests.MetricsEndpointReturnsPrometheusFormat;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := MetricsMiddleware('/metrics');

  LCtx := TContextBuilder.New.Path('/test').Build;
  LMw(LCtx, procedure begin LCtx.Status := 200; end);

  LCtx := TContextBuilder.New.Path('/metrics').Build;
  LMw(LCtx, procedure begin end);

  Assert.IsTrue(BodyAsString(LCtx).Contains('poseidon_requests_total'));
end;

procedure TMetricsMiddlewareTests.NormalRequestCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LMw := MetricsMiddleware('/metrics');
  LCtx := TContextBuilder.New.Path('/api/data').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TMetricsMiddlewareTests.RecordsRequestAfterHandler;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LBody: string;
begin
  LMw := MetricsMiddleware('/metrics');

  LCtx := TContextBuilder.New.Path('/users').Build;
  LMw(LCtx, procedure begin LCtx.Status := 200; end);
  LCtx := TContextBuilder.New.Path('/users').Build;
  LMw(LCtx, procedure begin LCtx.Status := 500; end);

  LCtx := TContextBuilder.New.Path('/metrics').Build;
  LMw(LCtx, procedure begin end);

  LBody := BodyAsString(LCtx);
  Assert.IsTrue(LBody.Contains('poseidon_requests_total{path="/users"} 2'));
  Assert.IsTrue(LBody.Contains('poseidon_errors_total{path="/users"} 1'));
end;

initialization
  TDUnitX.RegisterTestFixture(TMetricsMiddlewareTests);

end.
