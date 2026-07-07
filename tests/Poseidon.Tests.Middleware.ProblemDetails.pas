unit Poseidon.Tests.Middleware.ProblemDetails;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TProblemDetailsMiddlewareTests = class
  public
    [Test]
    procedure NoExceptionPassesThrough;
    [Test]
    procedure PoseidonExceptionMapsStatus;
    [Test]
    procedure PoseidonExceptionSetsProblemJSON;
    [Test]
    procedure GenericExceptionReturns500;
    [Test]
    procedure DetailContainsMessage;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.ProblemDetails,
  Poseidon.Exception,
  Poseidon.Status;

procedure TProblemDetailsMiddlewareTests.NoExceptionPassesThrough;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  ProblemDetailsMiddleware(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
  Assert.AreEqual(200, LCtx.Status);
end;

procedure TProblemDetailsMiddlewareTests.PoseidonExceptionMapsStatus;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Path('/items/42').Build;
  ProblemDetailsMiddleware(LCtx,
    procedure begin
      raise EPoseidonException.Create('Not found', THTTPStatus.NotFound);
    end);
  Assert.AreEqual(404, LCtx.Status);
end;

procedure TProblemDetailsMiddlewareTests.PoseidonExceptionSetsProblemJSON;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Path('/test').Build;
  ProblemDetailsMiddleware(LCtx,
    procedure begin
      raise EPoseidonException.Create('Forbidden', THTTPStatus.Forbidden);
    end);
  Assert.AreEqual('application/problem+json', LCtx.ContentType);
  Assert.IsTrue(BodyAsString(LCtx).Contains('"status":403'));
end;

procedure TProblemDetailsMiddlewareTests.GenericExceptionReturns500;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  ProblemDetailsMiddleware(LCtx,
    procedure begin raise Exception.Create('oops'); end);
  Assert.AreEqual(500, LCtx.Status);
  Assert.IsTrue(BodyAsString(LCtx).Contains('Internal Server Error'));
end;

procedure TProblemDetailsMiddlewareTests.DetailContainsMessage;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Path('/x').Build;
  ProblemDetailsMiddleware(LCtx,
    procedure begin
      raise EPoseidonException.Create('item not found', THTTPStatus.NotFound);
    end);
  Assert.IsTrue(BodyAsString(LCtx).Contains('item not found'));
end;

initialization
  TDUnitX.RegisterTestFixture(TProblemDetailsMiddlewareTests);

end.
