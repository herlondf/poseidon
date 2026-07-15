unit Poseidon.Tests.Middleware.Digest;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TDigestMiddlewareTests = class
  public
    [Test]
    procedure MissingAuthReturns401;
    [Test]
    procedure UnauthorizedSetsWWWAuthenticate;
    [Test]
    procedure ValidDigestCallsNext;
    [Test]
    procedure WrongPasswordReturns401;
    [Test]
    procedure UriMismatch_Returns401;
    [Test]
    procedure DigestHA1ProducesConsistentHash;
  end;

implementation

uses
  System.SysUtils,
  System.Hash,
  Poseidon.Middleware.Digest;

const
  CRealm = 'test-realm';
  CUser = 'admin';
  CPass = 'secret';

function TestGetHA1(const AUser, ARealm: string): string;
begin
  if (AUser = CUser) and (ARealm = CRealm) then
    Result := DigestHA1(CUser, CRealm, CPass)
  else
    Result := '';
end;

function BuildDigestHeader(const AMethod, AUri, ANonce, AHA1: string): string;
var
  LHA2, LResponse: string;
  LNc, LCnonce: string;
begin
  LNc := '00000001';
  LCnonce := 'abcdef01';
  LHA2 := LowerCase(THashMD5.GetHashString(AnsiString(AMethod + ':' + AUri)));
  LResponse := LowerCase(THashMD5.GetHashString(
    AnsiString(AHA1 + ':' + ANonce + ':' + LNc + ':' + LCnonce + ':auth:' + LHA2)));
  Result := Format(
    'Digest username="%s", realm="%s", nonce="%s", uri="%s", ' +
    'qop=auth, nc=%s, cnonce="%s", response="%s"',
    [CUser, CRealm, ANonce, AUri, LNc, LCnonce, LResponse]);
end;

procedure TDigestMiddlewareTests.MissingAuthReturns401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LCtx := TContextBuilder.New.Build;
  LMw := DigestMiddleware(CRealm, TestGetHA1);
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(401, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TDigestMiddlewareTests.UnauthorizedSetsWWWAuthenticate;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LHeader: string;
begin
  LCtx := TContextBuilder.New.Build;
  LMw := DigestMiddleware(CRealm, TestGetHA1);
  LMw(LCtx, procedure begin end);
  LHeader := GetExtraHeader(LCtx, 'WWW-Authenticate');
  Assert.IsTrue(LHeader.Contains('Digest realm="' + CRealm + '"'));
  Assert.IsTrue(LHeader.Contains('qop="auth"'));
end;

procedure TDigestMiddlewareTests.ValidDigestCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LNonce, LHA1, LAuthHeader: string;
  LCalled: Boolean;
  LProbeCtx: TNativeRequestContext;
begin
  LMw := DigestMiddleware(CRealm, TestGetHA1);

  LProbeCtx := TContextBuilder.New.Build;
  LMw(LProbeCtx, procedure begin end);
  LNonce := '';
  var LWww := GetExtraHeader(LProbeCtx, 'WWW-Authenticate');
  var LPos := Pos('nonce="', LWww);
  if LPos > 0 then
  begin
    Inc(LPos, Length('nonce="'));
    var LEnd := LPos;
    while (LEnd <= Length(LWww)) and (LWww[LEnd] <> '"') do
      Inc(LEnd);
    LNonce := Copy(LWww, LPos, LEnd - LPos);
  end;

  LHA1 := DigestHA1(CUser, CRealm, CPass);
  LAuthHeader := BuildDigestHeader('GET', '/', LNonce, LHA1);

  LCtx := TContextBuilder.New
    .Header('Authorization', LAuthHeader)
    .Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TDigestMiddlewareTests.WrongPasswordReturns401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LNonce, LWrongHA1, LAuthHeader: string;
  LProbeCtx: TNativeRequestContext;
begin
  LMw := DigestMiddleware(CRealm, TestGetHA1);

  LProbeCtx := TContextBuilder.New.Build;
  LMw(LProbeCtx, procedure begin end);
  LNonce := '';
  var LWww := GetExtraHeader(LProbeCtx, 'WWW-Authenticate');
  var LPos := Pos('nonce="', LWww);
  if LPos > 0 then
  begin
    Inc(LPos, Length('nonce="'));
    var LEnd := LPos;
    while (LEnd <= Length(LWww)) and (LWww[LEnd] <> '"') do
      Inc(LEnd);
    LNonce := Copy(LWww, LPos, LEnd - LPos);
  end;

  LWrongHA1 := DigestHA1(CUser, CRealm, 'wrong-password');
  LAuthHeader := BuildDigestHeader('GET', '/', LNonce, LWrongHA1);

  LCtx := TContextBuilder.New
    .Header('Authorization', LAuthHeader)
    .Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(401, LCtx.Status);
end;

// #209 regression: a cryptographically VALID Digest header computed for uri=
// "/admin" must be rejected when replayed on a request whose path is "/public"
// (and vice-versa). The uri field must be bound to the actual request path.
procedure TDigestMiddlewareTests.UriMismatch_Returns401;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LNonce, LHA1, LAuthHeader: string;
  LCalled: Boolean;
  LProbeCtx: TNativeRequestContext;
begin
  LMw := DigestMiddleware(CRealm, TestGetHA1);

  LProbeCtx := TContextBuilder.New.Build;
  LMw(LProbeCtx, procedure begin end);
  LNonce := '';
  var LWww := GetExtraHeader(LProbeCtx, 'WWW-Authenticate');
  var LPos := Pos('nonce="', LWww);
  if LPos > 0 then
  begin
    Inc(LPos, Length('nonce="'));
    var LEnd := LPos;
    while (LEnd <= Length(LWww)) and (LWww[LEnd] <> '"') do
      Inc(LEnd);
    LNonce := Copy(LWww, LPos, LEnd - LPos);
  end;

  LHA1 := DigestHA1(CUser, CRealm, CPass);
  // Valid digest for "/admin" ...
  LAuthHeader := BuildDigestHeader('GET', '/admin', LNonce, LHA1);
  // ... delivered on a request for "/public".
  LCtx := TContextBuilder.New
    .Path('/public')
    .Header('Authorization', LAuthHeader)
    .Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsFalse(LCalled, 'header uri must be bound to the actual request path');
  Assert.AreEqual(401, LCtx.Status);
end;

procedure TDigestMiddlewareTests.DigestHA1ProducesConsistentHash;
var
  LHash1, LHash2: string;
begin
  LHash1 := DigestHA1('user', 'realm', 'pass');
  LHash2 := DigestHA1('user', 'realm', 'pass');
  Assert.AreEqual(LHash1, LHash2);
  Assert.AreEqual(32, Length(LHash1));
end;

initialization
  TDUnitX.RegisterTestFixture(TDigestMiddlewareTests);

end.
