unit Poseidon.Tests.Middleware.Timeout;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TTimeoutMiddlewareTests = class
  public
    [Test]
    procedure FastRequestKeepsStatus;
    [Test]
    procedure SlowRequestReturns504;
    [Test]
    procedure SlowRequestSetsProblemJSON;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Timeout;

procedure TTimeoutMiddlewareTests.FastRequestKeepsStatus;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  LCtx.Status := 200;
  TimeoutMiddleware(5000)(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
end;

procedure TTimeoutMiddlewareTests.SlowRequestReturns504;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  TimeoutMiddleware(1)(LCtx, procedure begin Sleep(50); end);
  Assert.AreEqual(504, LCtx.Status);
end;

procedure TTimeoutMiddlewareTests.SlowRequestSetsProblemJSON;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  TimeoutMiddleware(1)(LCtx, procedure begin Sleep(50); end);
  Assert.AreEqual('application/problem+json', LCtx.ContentType);
end;

initialization
  TDUnitX.RegisterTestFixture(TTimeoutMiddlewareTests);

end.
