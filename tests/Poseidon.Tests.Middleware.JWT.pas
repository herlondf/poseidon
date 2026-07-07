unit Poseidon.Tests.Middleware.JWT;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TJWTMiddlewareTests = class
  public
    [Test]
    procedure MissingAuthHeaderRaises401;
    [Test]
    procedure InvalidTokenRaises401;
    [Test]
    procedure ValidTokenCallsNext;
    [Test]
    procedure ExpiredTokenRaises401;
    [Test]
    procedure SignProducesValidToken;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  System.DateUtils,
  Poseidon.Middleware.JWT,
  Poseidon.Exception;

const
  CSecret = 'test-secret-key-123';

procedure TJWTMiddlewareTests.MissingAuthHeaderRaises401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LCtx := TContextBuilder.New.Build;
  LMw := JWTMiddleware(CSecret);
  Assert.WillRaise(
    procedure begin LMw(LCtx, procedure begin end); end,
    EPoseidonException);
end;

procedure TJWTMiddlewareTests.InvalidTokenRaises401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LCtx := TContextBuilder.New
    .Header('Authorization', 'Bearer invalid.token.here')
    .Build;
  LMw := JWTMiddleware(CSecret);
  Assert.WillRaise(
    procedure begin LMw(LCtx, procedure begin end); end,
    EPoseidonException);
end;

procedure TJWTMiddlewareTests.ValidTokenCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LPayload: TJSONObject;
  LToken: string;
  LCalled: Boolean;
begin
  LPayload := TJSONObject.Create;
  try
    LPayload.AddPair('sub', 'user1');
    LPayload.AddPair('exp', TJSONNumber.Create(
      DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now)) + 3600));
    LToken := JWTSign(LPayload, CSecret);
  finally
    LPayload.Free;
  end;

  LCtx := TContextBuilder.New
    .Header('Authorization', 'Bearer ' + LToken)
    .Build;
  LMw := JWTMiddleware(CSecret);
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TJWTMiddlewareTests.ExpiredTokenRaises401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LPayload: TJSONObject;
  LToken: string;
begin
  LPayload := TJSONObject.Create;
  try
    LPayload.AddPair('sub', 'user1');
    LPayload.AddPair('exp', TJSONNumber.Create(
      DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now)) - 3600));
    LToken := JWTSign(LPayload, CSecret);
  finally
    LPayload.Free;
  end;

  LCtx := TContextBuilder.New
    .Header('Authorization', 'Bearer ' + LToken)
    .Build;
  LMw := JWTMiddleware(CSecret);
  Assert.WillRaise(
    procedure begin LMw(LCtx, procedure begin end); end,
    EPoseidonException);
end;

procedure TJWTMiddlewareTests.SignProducesValidToken;
var
  LPayload: TJSONObject;
  LToken: string;
  LParts: TArray<string>;
begin
  LPayload := TJSONObject.Create;
  try
    LPayload.AddPair('sub', 'test');
    LToken := JWTSign(LPayload, CSecret);
  finally
    LPayload.Free;
  end;
  LParts := LToken.Split(['.']);
  Assert.AreEqual(3, Length(LParts));
end;

initialization
  TDUnitX.RegisterTestFixture(TJWTMiddlewareTests);

end.
