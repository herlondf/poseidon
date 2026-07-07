unit Poseidon.Tests.Middleware.CORS;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TCORSMiddlewareTests = class
  public
    [Test]
    procedure AddsDefaultCORSHeaders;
    [Test]
    procedure PreflightReturns204;
    [Test]
    procedure PreflightSetsHandled;
    [Test]
    procedure NonOptionsCallsNext;
    [Test]
    procedure CustomOriginIsApplied;
    [Test]
    procedure CredentialsHeaderAdded;
  end;

implementation

uses
  Poseidon.Middleware.CORS;

procedure TCORSMiddlewareTests.AddsDefaultCORSHeaders;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LCtx := TContextBuilder.New.Path('/test').Build;
  LMw := CORSMiddleware;
  LMw(LCtx, procedure begin end);

  Assert.AreEqual('*', GetExtraHeader(LCtx, 'Access-Control-Allow-Origin'));
  Assert.IsTrue(GetExtraHeader(LCtx, 'Access-Control-Allow-Methods') <> '');
  Assert.IsTrue(GetExtraHeader(LCtx, 'Access-Control-Allow-Headers') <> '');
end;

procedure TCORSMiddlewareTests.PreflightReturns204;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LCtx := TContextBuilder.New.Method('OPTIONS').Path('/test').Build;
  LMw := CORSMiddleware;
  LMw(LCtx, procedure begin end);

  Assert.AreEqual(204, LCtx.Status);
end;

procedure TCORSMiddlewareTests.PreflightSetsHandled;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LCtx := TContextBuilder.New.Method('OPTIONS').Path('/test').Build;
  LMw := CORSMiddleware;
  LMw(LCtx, procedure begin end);

  Assert.IsTrue(LCtx.Handled);
end;

procedure TCORSMiddlewareTests.NonOptionsCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Method('GET').Path('/test').Build;
  LMw := CORSMiddleware;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);

  Assert.IsTrue(LCalled);
  Assert.IsFalse(LCtx.Handled);
end;

procedure TCORSMiddlewareTests.CustomOriginIsApplied;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LOpts: TCORSOptions;
begin
  LOpts := DefaultCORSOptions;
  LOpts.AllowOrigin := 'https://example.com';
  LCtx := TContextBuilder.New.Path('/test').Build;
  LMw := CORSMiddleware(LOpts);
  LMw(LCtx, procedure begin end);

  Assert.AreEqual('https://example.com', GetExtraHeader(LCtx, 'Access-Control-Allow-Origin'));
end;

procedure TCORSMiddlewareTests.CredentialsHeaderAdded;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LOpts: TCORSOptions;
begin
  LOpts := DefaultCORSOptions;
  LOpts.AllowCredentials := True;
  LCtx := TContextBuilder.New.Path('/test').Build;
  LMw := CORSMiddleware(LOpts);
  LMw(LCtx, procedure begin end);

  Assert.AreEqual('true', GetExtraHeader(LCtx, 'Access-Control-Allow-Credentials'));
end;

initialization
  TDUnitX.RegisterTestFixture(TCORSMiddlewareTests);

end.
