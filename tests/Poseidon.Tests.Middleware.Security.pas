unit Poseidon.Tests.Middleware.Security;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TSecurityMiddlewareTests = class
  public
    [Test]
    procedure DefaultsAddXContentTypeOptions;
    [Test]
    procedure DefaultsAddXFrameOptions;
    [Test]
    procedure DefaultsAddReferrerPolicy;
    [Test]
    procedure DefaultsAddCSP;
    [Test]
    procedure DefaultsAddHSTS;
    [Test]
    procedure CallsNextBeforeAddingHeaders;
    [Test]
    procedure EmptyCSPOmitsHeader;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Security;

procedure TSecurityMiddlewareTests.DefaultsAddXContentTypeOptions;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  SecurityMiddleware()(LCtx, procedure begin end);
  Assert.AreEqual('nosniff', GetExtraHeader(LCtx, 'X-Content-Type-Options'));
end;

procedure TSecurityMiddlewareTests.DefaultsAddXFrameOptions;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  SecurityMiddleware()(LCtx, procedure begin end);
  Assert.AreEqual('DENY', GetExtraHeader(LCtx, 'X-Frame-Options'));
end;

procedure TSecurityMiddlewareTests.DefaultsAddReferrerPolicy;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  SecurityMiddleware()(LCtx, procedure begin end);
  Assert.AreEqual('strict-origin-when-cross-origin', GetExtraHeader(LCtx, 'Referrer-Policy'));
end;

procedure TSecurityMiddlewareTests.DefaultsAddCSP;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  SecurityMiddleware()(LCtx, procedure begin end);
  Assert.AreEqual('default-src ''self''', GetExtraHeader(LCtx, 'Content-Security-Policy'));
end;

procedure TSecurityMiddlewareTests.DefaultsAddHSTS;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  SecurityMiddleware()(LCtx, procedure begin end);
  Assert.IsTrue(GetExtraHeader(LCtx, 'Strict-Transport-Security').Contains('max-age='));
end;

procedure TSecurityMiddlewareTests.CallsNextBeforeAddingHeaders;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  SecurityMiddleware()(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TSecurityMiddlewareTests.EmptyCSPOmitsHeader;
var
  LCtx: TNativeRequestContext;
  LOpts: TSecurityOptions;
begin
  LOpts := DefaultSecurityOptions;
  LOpts.CSP := '';
  LCtx := TContextBuilder.New.Build;
  SecurityMiddleware(LOpts)(LCtx, procedure begin end);
  Assert.AreEqual('', GetExtraHeader(LCtx, 'Content-Security-Policy'));
end;

initialization
  TDUnitX.RegisterTestFixture(TSecurityMiddlewareTests);

end.
