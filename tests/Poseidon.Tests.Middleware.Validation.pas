unit Poseidon.Tests.Middleware.Validation;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TValidationMiddlewareTests = class
  public
    [Test]
    procedure NoExceptionCallsNext;
    [Test]
    procedure ValidationExceptionReturns422;
    [Test]
    procedure ValidationExceptionSetsProblemJSON;
    [Test]
    procedure OtherExceptionsPropagate;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Validation,
  Poseidon.Exception;

procedure TValidationMiddlewareTests.NoExceptionCallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  ValidationMiddleware()(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TValidationMiddlewareTests.ValidationExceptionReturns422;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  ValidationMiddleware()(LCtx,
    procedure begin raise EPoseidonValidation.Create('Name is required'); end);
  Assert.AreEqual(422, LCtx.Status);
end;

procedure TValidationMiddlewareTests.ValidationExceptionSetsProblemJSON;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  ValidationMiddleware()(LCtx,
    procedure begin raise EPoseidonValidation.Create('Field missing'); end);
  Assert.AreEqual('application/problem+json', LCtx.ContentType);
  Assert.IsTrue(BodyAsString(LCtx).Contains('Unprocessable Entity'));
end;

procedure TValidationMiddlewareTests.OtherExceptionsPropagate;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  Assert.WillRaise(
    procedure
    begin
      ValidationMiddleware()(LCtx,
        procedure begin raise Exception.Create('generic'); end);
    end,
    Exception);
end;

initialization
  TDUnitX.RegisterTestFixture(TValidationMiddlewareTests);

end.
