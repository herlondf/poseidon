unit Poseidon.Tests.Middleware.CircuitBreaker;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TCircuitBreakerMiddlewareTests = class
  public
    [Test]
    procedure ClosedStateCallsNext;
    [Test]
    procedure RecordsSuccess;
    [Test]
    procedure FailureOpensCircuit;
    [Test]
    procedure OpenCircuitReturns503;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.CircuitBreaker;

procedure TCircuitBreakerMiddlewareTests.ClosedStateCallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  CircuitBreakerMiddleware(50, 60, 30)(LCtx,
    procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TCircuitBreakerMiddlewareTests.RecordsSuccess;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := CircuitBreakerMiddleware(50, 60, 30);
  LCtx := TContextBuilder.New.Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
end;

procedure TCircuitBreakerMiddlewareTests.FailureOpensCircuit;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  I: Integer;
begin
  LMw := CircuitBreakerMiddleware(1, 60, 30);
  for I := 1 to 5 do
  begin
    LCtx := TContextBuilder.New.Build;
    try
      LMw(LCtx, procedure begin raise Exception.Create('fail'); end);
    except
    end;
  end;
  LCtx := TContextBuilder.New.Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(503, LCtx.Status);
end;

procedure TCircuitBreakerMiddlewareTests.OpenCircuitReturns503;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  I: Integer;
begin
  LMw := CircuitBreakerMiddleware(1, 60, 300);
  for I := 1 to 10 do
  begin
    LCtx := TContextBuilder.New.Build;
    try
      LMw(LCtx, procedure begin raise Exception.Create('fail'); end);
    except
    end;
  end;
  LCtx := TContextBuilder.New.Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(503, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

initialization
  TDUnitX.RegisterTestFixture(TCircuitBreakerMiddlewareTests);

end.
