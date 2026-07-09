unit Poseidon.Tests.Middleware.Logger;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TLoggerMiddlewareTests = class
  public
    [Test]
    procedure TextLogContainsMethod;
    [Test]
    procedure TextLogContainsPath;
    [Test]
    procedure TextLogContainsStatus;
    [Test]
    procedure JSONLogContainsFields;
    [Test]
    procedure CallsNext;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Logger;

procedure TLoggerMiddlewareTests.TextLogContainsMethod;
var
  LCtx: TNativeRequestContext;
  LLog: string;
begin
  LCtx := TContextBuilder.New.Method('POST').Path('/users').Build;
  LoggerMiddleware(
    procedure(const ALine: string) begin LLog := ALine; end
  )(LCtx, procedure begin LCtx.Status := 201; end);
  Assert.IsTrue(LLog.Contains('POST'));
end;

procedure TLoggerMiddlewareTests.TextLogContainsPath;
var
  LCtx: TNativeRequestContext;
  LLog: string;
begin
  LCtx := TContextBuilder.New.Path('/items').Build;
  LoggerMiddleware(
    procedure(const ALine: string) begin LLog := ALine; end
  )(LCtx, procedure begin end);
  Assert.IsTrue(LLog.Contains('/items'));
end;

procedure TLoggerMiddlewareTests.TextLogContainsStatus;
var
  LCtx: TNativeRequestContext;
  LLog: string;
begin
  LCtx := TContextBuilder.New.Path('/test').Build;
  LoggerMiddleware(
    procedure(const ALine: string) begin LLog := ALine; end
  )(LCtx, procedure begin LCtx.Status := 404; end);
  Assert.IsTrue(LLog.Contains('404'));
end;

procedure TLoggerMiddlewareTests.JSONLogContainsFields;
var
  LCtx: TNativeRequestContext;
  LLog: string;
begin
  LCtx := TContextBuilder.New.Method('GET').Path('/test').RemoteAddr('10.0.0.1').Build;
  LoggerMiddlewareJSON(
    procedure(const ALine: string) begin LLog := ALine; end
  )(LCtx, procedure begin LCtx.Status := 200; end);
  Assert.IsTrue(LLog.Contains('"method":"GET"'));
  Assert.IsTrue(LLog.Contains('"path":"/test"'));
  Assert.IsTrue(LLog.Contains('"ip":"10.0.0.1"'));
end;

procedure TLoggerMiddlewareTests.CallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  LoggerMiddleware()(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

initialization
  TDUnitX.RegisterTestFixture(TLoggerMiddlewareTests);

end.
