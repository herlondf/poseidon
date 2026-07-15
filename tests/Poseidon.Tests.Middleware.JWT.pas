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
    procedure IssuerMismatchRaises401;
    [Test]
    procedure IssuerMatchCallsNext;
    [Test]
    procedure AudienceMismatchRaises401;
    [Test]
    procedure AudienceInArrayMatchCallsNext;
    [Test]
    procedure RequireExpWithoutExpRaises401;
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

function NowUnix: Int64;
begin
  Result := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now));
end;

// Builds a signed token; AConfig fills the payload claims.
function SignPayload(const AConfig: TProc<TJSONObject>): string;
var
  LPayload: TJSONObject;
begin
  LPayload := TJSONObject.Create;
  try
    AConfig(LPayload);
    Result := JWTSign(LPayload, CSecret);
  finally
    LPayload.Free;
  end;
end;

function BearerCtx(const AToken: string): TNativeRequestContext;
begin
  Result := TContextBuilder.New
    .Header('Authorization', 'Bearer ' + AToken)
    .Build;
end;

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

// #209: iss enforced only when configured — a token from another issuer (same
// shared secret) must be rejected (cross-service replay).
procedure TJWTMiddlewareTests.IssuerMismatchRaises401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LToken: string;
begin
  LToken := SignPayload(procedure(P: TJSONObject)
    begin
      P.AddPair('iss', 'issuer-B');
      P.AddPair('exp', TJSONNumber.Create(NowUnix + 3600));
    end);
  LCtx := BearerCtx(LToken);
  LMw := JWTMiddleware(CSecret, 'Unauthorized', 'issuer-A');
  Assert.WillRaise(
    procedure begin LMw(LCtx, procedure begin end); end, EPoseidonException);
end;

procedure TJWTMiddlewareTests.IssuerMatchCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LToken: string;
  LCalled: Boolean;
begin
  LToken := SignPayload(procedure(P: TJSONObject)
    begin
      P.AddPair('iss', 'issuer-A');
      P.AddPair('exp', TJSONNumber.Create(NowUnix + 3600));
    end);
  LCtx := BearerCtx(LToken);
  LMw := JWTMiddleware(CSecret, 'Unauthorized', 'issuer-A');
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TJWTMiddlewareTests.AudienceMismatchRaises401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LToken: string;
begin
  LToken := SignPayload(procedure(P: TJSONObject)
    begin
      P.AddPair('aud', 'aud-Y');
      P.AddPair('exp', TJSONNumber.Create(NowUnix + 3600));
    end);
  LCtx := BearerCtx(LToken);
  LMw := JWTMiddleware(CSecret, 'Unauthorized', '', 'aud-X');
  Assert.WillRaise(
    procedure begin LMw(LCtx, procedure begin end); end, EPoseidonException);
end;

// RFC 7519 §4.1.3 — aud may be an array; a match on any element is accepted.
procedure TJWTMiddlewareTests.AudienceInArrayMatchCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LToken: string;
  LCalled: Boolean;
begin
  LToken := SignPayload(procedure(P: TJSONObject)
    var LArr: TJSONArray;
    begin
      LArr := TJSONArray.Create;
      LArr.Add('aud-other');
      LArr.Add('aud-X');
      P.AddPair('aud', LArr);
      P.AddPair('exp', TJSONNumber.Create(NowUnix + 3600));
    end);
  LCtx := BearerCtx(LToken);
  LMw := JWTMiddleware(CSecret, 'Unauthorized', '', 'aud-X');
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TJWTMiddlewareTests.RequireExpWithoutExpRaises401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LToken: string;
begin
  LToken := SignPayload(procedure(P: TJSONObject)
    begin
      P.AddPair('sub', 'user1');  // deliberately no exp
    end);
  LCtx := BearerCtx(LToken);
  LMw := JWTMiddleware(CSecret, 'Unauthorized', '', '', True);
  Assert.WillRaise(
    procedure begin LMw(LCtx, procedure begin end); end, EPoseidonException);
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
  Assert.AreEqual(3, Integer(Length(LParts)));
end;

initialization
  TDUnitX.RegisterTestFixture(TJWTMiddlewareTests);

end.
