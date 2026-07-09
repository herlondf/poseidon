unit Poseidon.Tests.Middleware.BodyLimit;

interface

uses
  System.SysUtils,
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TBodyLimitMiddlewareTests = class
  public
    [Test]
    procedure SmallBodyCallsNext;
    [Test]
    procedure OversizedBodyReturns413;
    [Test]
    procedure OversizedBodySetsHandled;
    [Test]
    procedure ExactLimitCallsNext;
    [Test]
    procedure EmptyBodyCallsNext;
  end;

implementation

uses
  Poseidon.Middleware.BodyLimit;

procedure TBodyLimitMiddlewareTests.SmallBodyCallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.RawBody('hello').Build;
  LCalled := False;
  BodyLimitMiddleware(1024)(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TBodyLimitMiddlewareTests.OversizedBodyReturns413;
var
  LCtx: TNativeRequestContext;
  LBody: TBytes;
begin
  SetLength(LBody, 2048);
  LCtx := TContextBuilder.New.RawBody(LBody).Build;
  BodyLimitMiddleware(1024)(LCtx, procedure begin end);
  Assert.AreEqual(413, LCtx.Status);
end;

procedure TBodyLimitMiddlewareTests.OversizedBodySetsHandled;
var
  LCtx: TNativeRequestContext;
  LBody: TBytes;
begin
  SetLength(LBody, 2048);
  LCtx := TContextBuilder.New.RawBody(LBody).Build;
  BodyLimitMiddleware(1024)(LCtx, procedure begin end);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TBodyLimitMiddlewareTests.ExactLimitCallsNext;
var
  LCtx: TNativeRequestContext;
  LBody: TBytes;
  LCalled: Boolean;
begin
  SetLength(LBody, 1024);
  LCtx := TContextBuilder.New.RawBody(LBody).Build;
  LCalled := False;
  BodyLimitMiddleware(1024)(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TBodyLimitMiddlewareTests.EmptyBodyCallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  BodyLimitMiddleware(1024)(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

initialization
  TDUnitX.RegisterTestFixture(TBodyLimitMiddlewareTests);

end.
