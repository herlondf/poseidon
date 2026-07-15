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

// AIssuer / AAudience: when non-empty, the token's `iss` / `aud` claim MUST match
// (RFC 7519 §4.1.1 / §4.1.3) — without this, a token minted for another service
// sharing the same HMAC secret is accepted (cross-service replay). ARequireExp:
// when True, a token without an `exp` claim is rejected (no everlasting tokens).
function JWTMiddleware(const ASecret: string;
  const AUnauthorizedMsg: string = 'Unauthorized';
  const AIssuer: string = '';
  const AAudience: string = '';
  ARequireExp: Boolean = False): TNativeMiddlewareFunc;

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
  // A JWT segment must be valid UTF-8 JSON. TEncoding.UTF8.GetString RAISES
  // EEncodingError on invalid UTF-8 in this RTL; a malformed-but-signed token
  // would then surface as a 500 instead of a clean 401. Treat undecodable
  // bytes as an invalid segment (empty → JSON parse fails → Unauthorized).
  try
    Result := TEncoding.UTF8.GetString(LBytes);
  except
    on EEncodingError do
      Result := '';
  end;
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
  LValue: TJSONValue;
  LAlg: string;
begin
  Result := False;
  // Parse into a TJSONValue (not `as TJSONObject`): a valid but non-object
  // header (e.g. base64url of "[]") would make the cast raise EInvalidCast and
  // leak the parsed TJSONArray on every unauthenticated request.
  try
    LValue := TJSONObject.ParseJSONValue(Base64URLDecode(AHeaderB64));
  except
    LValue := nil;
  end;
  if LValue = nil then
    Exit;
  try
    if (LValue is TJSONObject) and
       TJSONObject(LValue).TryGetValue<string>('alg', LAlg) then
      Result := LAlg = 'HS256';
  finally
    LValue.Free;
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

// RFC 7519 §4.1.3 — `aud` may be a single string OR an array of strings; the
// token is acceptable when the configured audience is present in either form.
function _AudienceMatches(AJSON: TJSONObject; const AAudience: string): Boolean;
var
  LStr: string;
  LVal: TJSONValue;
  LArr: TJSONArray;
  I: Integer;
begin
  if AJSON.TryGetValue<string>('aud', LStr) then
    Exit(LStr = AAudience);
  LVal := AJSON.GetValue('aud');
  if LVal is TJSONArray then
  begin
    LArr := TJSONArray(LVal);
    for I := 0 to LArr.Count - 1 do
      if LArr.Items[I].Value = AAudience then
        Exit(True);
  end;
  Result := False;
end;

function JWTMiddleware(const ASecret: string;
  const AUnauthorizedMsg: string;
  const AIssuer: string;
  const AAudience: string;
  ARequireExp: Boolean): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LAuthHeader, LToken: string;
      LParts: TArray<string>;
      LPayloadJSON: string;
      LValue: TJSONValue;
      LJSON: TJSONObject;
      LExp: Int64;
      LNbf: Int64;
      LNowUnix: Int64;
      LHasExp: Boolean;
      LIss: string;
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
      // Parse into a TJSONValue: a non-object payload (e.g. a JSON array) would
      // make `as TJSONObject` raise EInvalidCast -> a 500 (not 401) and leak the
      // parsed value. `nil.Free` is safe; a non-object value is freed too.
      LValue := TJSONObject.ParseJSONValue(LPayloadJSON);
      if not (LValue is TJSONObject) then
      begin
        LValue.Free;
        raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);
      end;
      LJSON := TJSONObject(LValue);
      try
        LNowUnix := DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now));
        LHasExp := LJSON.TryGetValue<Int64>('exp', LExp);
        if LHasExp and (LExp < LNowUnix) then
          raise EPoseidonException.Create('Token expired', THTTPStatus.Unauthorized);
        if ARequireExp and not LHasExp then
          raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);
        // RFC 7519 §4.1.5 — reject a token used before its not-before time.
        if LJSON.TryGetValue<Int64>('nbf', LNbf) then
        begin
          if LNowUnix < LNbf then
            raise EPoseidonException.Create('Token not yet valid', THTTPStatus.Unauthorized);
        end;
        // RFC 7519 §4.1.1 issuer / §4.1.3 audience — enforced only when configured.
        if (AIssuer <> '') and
           ((not LJSON.TryGetValue<string>('iss', LIss)) or (LIss <> AIssuer)) then
          raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);
        if (AAudience <> '') and (not _AudienceMatches(LJSON, AAudience)) then
          raise EPoseidonException.Create(AUnauthorizedMsg, THTTPStatus.Unauthorized);
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
