unit Poseidon.Middleware.JWT;

// Validates Bearer JWT tokens (HMAC-SHA256 / HS256).
// Sets the parsed claims object on the request body for downstream handlers.
//
// Usage:
//   TPoseidon.Use(TPoseidonMiddlewareJWT.New('my-secret-key'));
//
// In your handler:
//   var Claims := Req.GetBody<TJWTClaims>;
//   Writeln(Claims.Subject);

interface

uses
  System.SysUtils,
  System.JSON,
  System.NetEncoding,
  System.Hash,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback,
  Poseidon.Commons,
  Poseidon.Exception;

type
  // Basic claims extracted from JWT payload
  TJWTClaims = class
  public
    Subject: string;     // sub
    Issuer: string;      // iss
    Audience: string;    // aud
    IssuedAt: Int64;     // iat
    ExpiresAt: Int64;    // exp
    RawPayload: TJSONObject;

    constructor Create; virtual;
    destructor Destroy; override;
    function IsExpired: Boolean;
  end;

  TPoseidonMiddlewareJWT = class
  private
    class function Base64URLDecode(const AInput: string): string;
    class function VerifySignature(const AHeader, APayload, ASignature, ASecret: string): Boolean;
    class function ParseClaims(const APayloadJSON: string): TJWTClaims;
  public
    // Validates token from Authorization: Bearer <token> header.
    // Raises EPoseidonException(401) if invalid/missing/expired.
    class function New(const ASecret: string): TPoseidonCallback; overload;

    // Same but with custom unauthorized message
    class function New(const ASecret, AUnauthorizedMsg: string): TPoseidonCallback; overload;

    // Sign a payload and return a JWT token (server-side token generation)
    class function Sign(APayload: TJSONObject; const ASecret: string): string;
  end;

implementation

uses
  System.DateUtils;

{ TJWTClaims }

constructor TJWTClaims.Create;
begin
  RawPayload := nil;
end;

destructor TJWTClaims.Destroy;
begin
  RawPayload.Free;
  inherited;
end;

function TJWTClaims.IsExpired: Boolean;
begin
  Result := (ExpiresAt > 0) and (ExpiresAt < DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now)));
end;

{ TPoseidonMiddlewareJWT }

class function TPoseidonMiddlewareJWT.Base64URLDecode(const AInput: string): string;
var
  LPadded: string;
  LBase64: string;
  LBytes: TBytes;
begin
  LBase64 := AInput.Replace('-', '+').Replace('_', '/');
  case Length(LBase64) mod 4 of
    2: LPadded := LBase64 + '==';
    3: LPadded := LBase64 + '=';
  else
    LPadded := LBase64;
  end;
  LBytes := TNetEncoding.Base64.DecodeStringToBytes(LPadded);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

class function TPoseidonMiddlewareJWT.VerifySignature(const AHeader, APayload, ASignature, ASecret: string): Boolean;
var
  LInput: string;
  LExpected: string;
  LBytes: TBytes;
begin
  LInput := AHeader + '.' + APayload;
  LBytes := THashSHA2.GetHMACAsBytes(
    TEncoding.UTF8.GetBytes(LInput),
    TEncoding.UTF8.GetBytes(ASecret),
    SHA256);
  LExpected := TNetEncoding.Base64URL.EncodeBytesToString(LBytes);
  Result := LExpected = ASignature;
end;

class function TPoseidonMiddlewareJWT.ParseClaims(const APayloadJSON: string): TJWTClaims;
var
  LJSON: TJSONObject;
  LValue: TJSONValue;
begin
  Result := TJWTClaims.Create;
  LJSON := TJSONObject.ParseJSONValue(APayloadJSON) as TJSONObject;
  if LJSON = nil then
    Exit;
  Result.RawPayload := LJSON;
  LValue := LJSON.GetValue('sub');
  if LValue <> nil then Result.Subject := LValue.Value;
  LValue := LJSON.GetValue('iss');
  if LValue <> nil then Result.Issuer := LValue.Value;
  LValue := LJSON.GetValue('aud');
  if LValue <> nil then Result.Audience := LValue.Value;
  LValue := LJSON.GetValue('iat');
  if LValue <> nil then Result.IssuedAt := (LValue as TJSONNumber).AsInt64;
  LValue := LJSON.GetValue('exp');
  if LValue <> nil then Result.ExpiresAt := (LValue as TJSONNumber).AsInt64;
end;

class function TPoseidonMiddlewareJWT.New(const ASecret: string): TPoseidonCallback;
begin
  Result := New(ASecret, 'Unauthorized');
end;

class function TPoseidonMiddlewareJWT.New(const ASecret, AUnauthorizedMsg: string): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LAuthHeader, LToken: string;
      LParts: TArray<string>;
      LHeader, LPayload, LSignature: string;
      LClaims: TJWTClaims;
    begin
      LAuthHeader := Req.Headers.GetOrDefault('Authorization', '');
      if not LAuthHeader.StartsWith('Bearer ', True) then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);

      LToken := LAuthHeader.Substring(7).Trim;
      LParts := LToken.Split(['.']);
      if Length(LParts) <> 3 then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);

      LHeader    := LParts[0];
      LPayload   := LParts[1];
      LSignature := LParts[2];

      if not VerifySignature(LHeader, LPayload, LSignature, ASecret) then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);

      LClaims := ParseClaims(Base64URLDecode(LPayload));
      if LClaims.IsExpired then
      begin
        LClaims.Free;
        raise EPoseidonException.Create('Token expired', THTTPStatus.Unauthorized);
      end;

      Req.SetBody(LClaims);  // Claims accessible via Req.GetBody<TJWTClaims>
      Next;
    end;
end;

class function TPoseidonMiddlewareJWT.Sign(APayload: TJSONObject; const ASecret: string): string;
var
  LHeaderJSON, LPayloadStr, LHeaderStr: string;
  LInput: string;
  LBytes: TBytes;
  LSignature: string;
begin
  LHeaderJSON := '{"alg":"HS256","typ":"JWT"}';
  LHeaderStr  := TNetEncoding.Base64URL.EncodeBytesToString(TEncoding.UTF8.GetBytes(LHeaderJSON));
  LPayloadStr := TNetEncoding.Base64URL.EncodeBytesToString(TEncoding.UTF8.GetBytes(APayload.ToString));

  LInput := LHeaderStr + '.' + LPayloadStr;
  LBytes := THashSHA2.GetHMACAsBytes(
    TEncoding.UTF8.GetBytes(LInput),
    TEncoding.UTF8.GetBytes(ASecret),
    SHA256);
  LSignature := TNetEncoding.Base64URL.EncodeBytesToString(LBytes);

  Result := LInput + '.' + LSignature;
end;

end.
