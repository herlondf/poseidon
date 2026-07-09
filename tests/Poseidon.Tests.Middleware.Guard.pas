unit Poseidon.Tests.Middleware.Guard;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TGuardMiddlewareTests = class
  public
    [Test]
    procedure AllowedMethodCallsNext;
    [Test]
    procedure DisallowedMethodReturns405;
    [Test]
    procedure NoWhitelistAllowsAnyMethod;
    [Test]
    procedure PathTraversalReturns400;
    [Test]
    procedure SafePathCallsNext;
    [Test]
    procedure RequestSmugglingReturns400;
  end;

implementation

uses
  Poseidon.Middleware.Guard;

procedure TGuardMiddlewareTests.AllowedMethodCallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Method('GET').Path('/test').Build;
  LCalled := False;
  GuardMiddleware(['GET', 'POST'])(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TGuardMiddlewareTests.DisallowedMethodReturns405;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Method('DELETE').Path('/test').Build;
  GuardMiddleware(['GET', 'POST'])(LCtx, procedure begin end);
  Assert.AreEqual(405, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TGuardMiddlewareTests.NoWhitelistAllowsAnyMethod;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Method('PATCH').Path('/test').Build;
  LCalled := False;
  GuardMiddleware()(LCtx,procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TGuardMiddlewareTests.PathTraversalReturns400;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Path('/../etc/passwd').Build;
  GuardMiddleware()(LCtx,procedure begin end);
  Assert.AreEqual(400, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TGuardMiddlewareTests.SafePathCallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Path('/api/users').Build;
  LCalled := False;
  GuardMiddleware()(LCtx,procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TGuardMiddlewareTests.RequestSmugglingReturns400;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New
    .Path('/test')
    .Header('Content-Length', '10')
    .Header('Transfer-Encoding', 'chunked')
    .Build;
  GuardMiddleware()(LCtx,procedure begin end);
  Assert.AreEqual(400, LCtx.Status);
end;

initialization
  TDUnitX.RegisterTestFixture(TGuardMiddlewareTests);

end.
