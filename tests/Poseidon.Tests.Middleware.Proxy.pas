unit Poseidon.Tests.Middleware.Proxy;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TProxyMiddlewareTests = class
  public
    [Test]
    procedure ProxyReturns502OnInvalidUpstream;
    [Test]
    procedure PrefixProxyCallsNextWhenNoMatch;
    [Test]
    procedure PrefixProxyHandlesMatchingPath;
    [Test]
    procedure ProxySetsHandled;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Proxy;

procedure TProxyMiddlewareTests.ProxyReturns502OnInvalidUpstream;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := ProxyMiddleware('http://localhost:1');
  LCtx := TContextBuilder.New.Path('/test').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(502, LCtx.Status);
  Assert.IsTrue(BodyAsString(LCtx).Contains('Bad Gateway'));
end;

procedure TProxyMiddlewareTests.PrefixProxyCallsNextWhenNoMatch;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LMw := ProxyMiddlewareWithPrefix('http://localhost:1', '/api');
  LCtx := TContextBuilder.New.Path('/other/path').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TProxyMiddlewareTests.PrefixProxyHandlesMatchingPath;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := ProxyMiddlewareWithPrefix('http://localhost:1', '/api');
  LCtx := TContextBuilder.New.Path('/api/users').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(502, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TProxyMiddlewareTests.ProxySetsHandled;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := ProxyMiddleware('http://localhost:1');
  LCtx := TContextBuilder.New.Path('/').Build;
  LMw(LCtx, procedure begin end);
  Assert.IsTrue(LCtx.Handled);
end;

initialization
  TDUnitX.RegisterTestFixture(TProxyMiddlewareTests);

end.
