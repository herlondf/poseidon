unit Poseidon.Tests.Middleware;

interface

uses
  DUnitX.TestFramework,
  System.SysUtils,
  System.DateUtils,
  System.JSON,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback,
  Poseidon.Exception,
  Poseidon.Commons,
  Poseidon.Middleware.JWT,
  Poseidon.Middleware.RateLimit,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse;

type
  [TestFixture]
  TPoseidonJWTTests = class
  private
    const SECRET = 'test-secret-key';
    function ValidToken: string;
    function ExpiredToken: string;
  public
    [Test]
    procedure ValidToken_CallsNext;
    [Test]
    procedure ValidToken_SetsClaims;
    [Test]
    procedure MissingHeader_Raises401;
    [Test]
    procedure WrongPrefix_Raises401;
    [Test]
    procedure InvalidSignature_Raises401;
    [Test]
    procedure ExpiredToken_Raises401;
    [Test]
    procedure MalformedToken_Raises401;
  end;

  [TestFixture]
  TPoseidonRateLimitTests = class
  public
    [Test]
    procedure UnderLimit_CallsNext;
    [Test]
    procedure UnderLimit_SetsRemainingHeader;
    [Test]
    procedure OverLimit_Raises429;
    [Test]
    procedure OverLimit_RemainingHeaderIsZero;
    [Test]
    procedure DifferentIPs_IndependentCounters;
    [Test]
    procedure XForwardedFor_UsedAsIP;
  end;

implementation

{ Helpers }

function TPoseidonJWTTests.ValidToken: string;
var
  LPayload: TJSONObject;
begin
  LPayload := TJSONObject.Create;
  LPayload.AddPair('sub', 'user123');
  LPayload.AddPair('iss', 'test');
  LPayload.AddPair('exp', TJSONNumber.Create(DateTimeToUnix(Now, False) + 3600));
  try
    Result := TPoseidonMiddlewareJWT.Sign(LPayload, SECRET);
  finally
    LPayload.Free;
  end;
end;

function TPoseidonJWTTests.ExpiredToken: string;
var
  LPayload: TJSONObject;
begin
  LPayload := TJSONObject.Create;
  LPayload.AddPair('sub', 'user123');
  LPayload.AddPair('exp', TJSONNumber.Create(DateTimeToUnix(Now, False) - 3600));
  try
    Result := TPoseidonMiddlewareJWT.Sign(LPayload, SECRET);
  finally
    LPayload.Free;
  end;
end;

{ TPoseidonJWTTests }

procedure TPoseidonJWTTests.ValidToken_CallsNext;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNextCalled: Boolean;
begin
  LNextCalled := False;
  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('Authorization', 'Bearer ' + ValidToken);
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareJWT.New(SECRET);
    LMiddleware(LReq, LRes, procedure begin LNextCalled := True end);
    Assert.IsTrue(LNextCalled, 'Next should be called for a valid token');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonJWTTests.ValidToken_SetsClaims;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LClaims: TJWTClaims;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('Authorization', 'Bearer ' + ValidToken);
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareJWT.New(SECRET);
    LMiddleware(LReq, LRes, procedure begin end);
    LClaims := LReq.GetBody<TJWTClaims>;
    Assert.IsNotNull(LClaims, 'Claims should be set on request body');
    Assert.AreEqual('user123', LClaims.Subject);
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonJWTTests.MissingHeader_Raises401;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
begin
  LMockReq := TMockWebRequest.Create;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareJWT.New(SECRET);
    try
      LMiddleware(LReq, LRes, procedure begin end);
      Assert.Fail('Expected EPoseidonException for missing header');
    except
      on E: EPoseidonException do
        Assert.AreEqual(401, E.Status.ToInteger);
    end;
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonJWTTests.WrongPrefix_Raises401;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('Authorization', 'Basic dXNlcjpwYXNz');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareJWT.New(SECRET);
    try
      LMiddleware(LReq, LRes, procedure begin end);
      Assert.Fail('Expected EPoseidonException for wrong auth scheme');
    except
      on E: EPoseidonException do
        Assert.AreEqual(401, E.Status.ToInteger);
    end;
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonJWTTests.InvalidSignature_Raises401;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LToken: string;
  LPayload: TJSONObject;
begin
  LPayload := TJSONObject.Create;
  LPayload.AddPair('sub', 'user');
  LPayload.AddPair('exp', TJSONNumber.Create(DateTimeToUnix(Now, False) + 3600));
  LToken := TPoseidonMiddlewareJWT.Sign(LPayload, 'wrong-secret');
  LPayload.Free;

  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('Authorization', 'Bearer ' + LToken);
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareJWT.New(SECRET);
    try
      LMiddleware(LReq, LRes, procedure begin end);
      Assert.Fail('Expected EPoseidonException for invalid signature');
    except
      on E: EPoseidonException do
        Assert.AreEqual(401, E.Status.ToInteger);
    end;
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonJWTTests.ExpiredToken_Raises401;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('Authorization', 'Bearer ' + ExpiredToken);
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareJWT.New(SECRET);
    try
      LMiddleware(LReq, LRes, procedure begin end);
      Assert.Fail('Expected EPoseidonException for expired token');
    except
      on E: EPoseidonException do
        Assert.AreEqual(401, E.Status.ToInteger);
    end;
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonJWTTests.MalformedToken_Raises401;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.AddHeader('Authorization', 'Bearer not.a.valid.jwt.token');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareJWT.New(SECRET);
    try
      LMiddleware(LReq, LRes, procedure begin end);
      Assert.Fail('Expected EPoseidonException for malformed token');
    except
      on E: EPoseidonException do
        Assert.AreEqual(401, E.Status.ToInteger);
    end;
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

{ TPoseidonRateLimitTests }

procedure TPoseidonRateLimitTests.UnderLimit_CallsNext;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNextCalled: Boolean;
begin
  LNextCalled := False;
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetRemoteAddr('10.0.0.1');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareRateLimit.New(10, 60);
    LMiddleware(LReq, LRes, procedure begin LNextCalled := True end);
    Assert.IsTrue(LNextCalled, 'Next should be called within limit');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonRateLimitTests.UnderLimit_SetsRemainingHeader;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetRemoteAddr('10.0.0.2');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareRateLimit.New(5, 60);
    LMiddleware(LReq, LRes, procedure begin end);
    Assert.AreEqual('5', LMockRes.SentHeaders.Values['X-RateLimit-Limit']);
    Assert.AreEqual('4', LMockRes.SentHeaders.Values['X-RateLimit-Remaining']);
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonRateLimitTests.OverLimit_Raises429;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  I: Integer;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetRemoteAddr('10.0.0.3');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareRateLimit.New(3, 60);
    for I := 1 to 3 do
      LMiddleware(LReq, LRes, procedure begin end);
    try
      LMiddleware(LReq, LRes, procedure begin end);
      Assert.Fail('Expected EPoseidonException 429 after limit exceeded');
    except
      on E: EPoseidonException do
        Assert.AreEqual(429, E.Status.ToInteger);
    end;
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonRateLimitTests.OverLimit_RemainingHeaderIsZero;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  I: Integer;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetRemoteAddr('10.0.0.4');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware := TPoseidonMiddlewareRateLimit.New(2, 60);
    for I := 1 to 2 do
      LMiddleware(LReq, LRes, procedure begin end);
    try
      LMiddleware(LReq, LRes, procedure begin end);
    except
      on EPoseidonException do;
    end;
    Assert.AreEqual('0', LMockRes.SentHeaders.Values['X-RateLimit-Remaining'],
      'Remaining must be clamped to 0 when over limit');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPoseidonRateLimitTests.DifferentIPs_IndependentCounters;
var
  LMockReq1, LMockReq2: TMockWebRequest;
  LMockRes1, LMockRes2: TMockWebResponse;
  LReq1, LReq2: TPoseidonRequest;
  LRes1, LRes2: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext1, LNext2: Boolean;
begin
  LNext1 := False;
  LNext2 := False;
  LMockReq1 := TMockWebRequest.Create;
  LMockReq1.SetRemoteAddr('192.168.1.1');
  LMockReq2 := TMockWebRequest.Create;
  LMockReq2.SetRemoteAddr('192.168.1.2');
  LMockRes1 := TMockWebResponse.Create(LMockReq1);
  LMockRes2 := TMockWebResponse.Create(LMockReq2);
  LReq1 := TPoseidonRequest.Create(LMockReq1);
  LReq2 := TPoseidonRequest.Create(LMockReq2);
  LRes1 := TPoseidonResponse.Create(LMockRes1);
  LRes2 := TPoseidonResponse.Create(LMockRes2);
  try
    LMiddleware := TPoseidonMiddlewareRateLimit.New(1, 60);
    LMiddleware(LReq1, LRes1, procedure begin LNext1 := True end);
    LMiddleware(LReq2, LRes2, procedure begin LNext2 := True end);
    Assert.IsTrue(LNext1, 'IP1 first request should pass');
    Assert.IsTrue(LNext2, 'IP2 first request should pass independently');
  finally
    LReq1.Free; LReq2.Free;
    LRes1.Free; LRes2.Free;
    LMockRes1.Free; LMockRes2.Free;
    LMockReq1.Free; LMockReq2.Free;
  end;
end;

procedure TPoseidonRateLimitTests.XForwardedFor_UsedAsIP;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNextCalled: Boolean;
begin
  // Strategy: exhaust the limit for RemoteAddr '10.0.0.1'.
  // Then send a request from the same RemoteAddr but with X-Forwarded-For pointing
  // to a different IP — if forwarded-for is used, the 2nd request passes.
  LMiddleware := TPoseidonMiddlewareRateLimit.New(1, 60);

  // First request — direct IP '10.0.0.1', no forwarded header
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetRemoteAddr('10.0.0.1');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware(LReq, LRes, procedure begin end);
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;

  // Second request — same RemoteAddr but X-Forwarded-For is a new IP
  LNextCalled := False;
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetRemoteAddr('10.0.0.1');
  LMockReq.AddHeader('X-Forwarded-For', '203.0.113.5');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LMiddleware(LReq, LRes, procedure begin LNextCalled := True end);
    Assert.IsTrue(LNextCalled,
      'X-Forwarded-For IP should have its own independent counter');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonJWTTests);
  TDUnitX.RegisterTestFixture(TPoseidonRateLimitTests);

end.
