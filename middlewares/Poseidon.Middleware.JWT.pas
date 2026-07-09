unit Poseidon.Middleware.JWT;

// Validates Bearer JWT tokens (HMAC-SHA256 / HS256).
// Raises EPoseidonException(401) if invalid/missing/expired.
//
// Usage:
//   App.Use(JWTMiddleware('my-secret-key'));
//
// Token generation:
//   var Token := JWTSign(Payload, 'my-secret-key');

interface

uses
  System.SysUtils,
  System.JSON,
  Poseidon.Native.Types;

function JWTMiddleware(const ASecret: string;
  const AUnauthorizedMsg: string = 'Unauthorized'): TNativeMiddlewareFunc;

function JWTSign(APayload: TJSONObject; const ASecret: string): string;

implementation

uses
  System.NetEncoding,
  System.Hash,
  System.DateUtils,
  Poseidon.Exception,
  Poseidon.Status;

function Base64URLDecode(const AInput: string): string;
var
  LPadded, LBase64: string;
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

// Constant-time string comparison — never short-circuits on the first
// differing byte, so an attacker cannot recover the expected signature by
// measuring response timing byte-by-byte. Length mismatch is safe to leak here
// (HS256 signatures have a fixed length).
function ConstantTimeEquals(const A, B: string): Boolean;
var
  I: Integer;
  LDiff: Integer;
begin
  if Length(A) <> Length(B) then
    Exit(False);
  LDiff := 0;
  for I := 1 to Length(A) do
    LDiff := LDiff or (Ord(A[I]) xor Ord(B[I]));
  Result := LDiff = 0;
end;

// Decodes and validates the JWT header, pinning the algorithm to HS256 (the
// only algorithm implemented). Rejecting anything else closes both alg:none
// and HS/RS confusion if an asymmetric verifier is added later.
function HeaderAlgIsHS256(const AHeaderB64: string): Boolean;
var
  LJSON: TJSONObject;
  LAlg: string;
begin
  Result := False;
  try
    LJSON := TJSONObject.ParseJSONValue(Base64URLDecode(AHeaderB64)) as TJSONObject;
  except
    Exit;  // malformed base64url / JSON header → reject
  end;
  if LJSON = nil then
    Exit;
  try
    if LJSON.TryGetValue<string>('alg', LAlg) then
      Result := LAlg = 'HS256';
  finally
    LJSON.Free;
  end;
end;

function VerifySignature(const AHeader, APayload, ASignature, ASecret: string): Boolean;
var
  LInput, LExpected: string;
  LBytes: TBytes;
begin
  LInput := AHeader + '.' + APayload;
  LBytes := THashSHA2.GetHMACAsBytes(
    TEncoding.UTF8.GetBytes(LInput),
    TEncoding.UTF8.GetBytes(ASecret),
    SHA256);
  LExpected := TNetEncoding.Base64URL.EncodeBytesToString(LBytes);
  Result := ConstantTimeEquals(LExpected, ASignature);
end;

function JWTMiddleware(const ASecret: string;
  const AUnauthorizedMsg: string): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LAuthHeader, LToken: string;
      LParts: TArray<string>;
      LPayloadJSON: string;
      LJSON: TJSONObject;
      LExp: Int64;
      LNbf: Int64;
      LNowUnix: Int64;
    begin
      LAuthHeader := ACtx.Header('Authorization');
      if not LAuthHeader.StartsWith('Bearer ', True) then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);

      LToken := LAuthHeader.Substring(7).Trim;
      LParts := LToken.Split(['.']);
      if Length(LParts) <> 3 then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);

      // Pin the signing algorithm before trusting the signature.
      if not HeaderAlgIsHS256(LParts[0]) then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);

      if not VerifySignature(LParts[0], LParts[1], LParts[2], ASecret) then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);

      LPayloadJSON := Base64URLDecode(LParts[1]);
      LJSON := TJSONObject.ParseJSONValue(LPayloadJSON) as TJSONObject;
      if LJSON = nil then
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);
      try
        LNowUnix := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now));
        if LJSON.TryGetValue<Int64>('exp', LExp) then
        begin
          if LExp < LNowUnix then
            raise EPoseidonException.Create('Token expired', THTTPStatus.Unauthorized);
        end;
        // RFC 7519 §4.1.5 — reject a token used before its not-before time.
        if LJSON.TryGetValue<Int64>('nbf', LNbf) then
        begin
          if LNowUnix < LNbf then
            raise EPoseidonException.Create('Token not yet valid', THTTPStatus.Unauthorized);
        end;
      finally
        LJSON.Free;
      end;

      ANext();
    end;
end;

function JWTSign(APayload: TJSONObject; const ASecret: string): string;
var
  LHeaderStr, LPayloadStr, LInput, LSignature: string;
  LBytes: TBytes;
begin
  LHeaderStr := TNetEncoding.Base64URL.EncodeBytesToString(
    TEncoding.UTF8.GetBytes('{"alg":"HS256","typ":"JWT"}'));
  LPayloadStr := TNetEncoding.Base64URL.EncodeBytesToString(
    TEncoding.UTF8.GetBytes(APayload.ToString));

  LInput := LHeaderStr + '.' + LPayloadStr;
  LBytes := THashSHA2.GetHMACAsBytes(
    TEncoding.UTF8.GetBytes(LInput),
    TEncoding.UTF8.GetBytes(ASecret),
    SHA256);
  LSignature := TNetEncoding.Base64URL.EncodeBytesToString(LBytes);

  Result := LInput + '.' + LSignature;
end;

end.
