unit Poseidon.Cookies;

// Cookie support for Poseidon.
//
// Request side: TCookieJar parses the inbound `Cookie:` header into a dict.
//   Jar := TCookieJar.Parse(Req.HeaderValue('Cookie'));
//   if Jar.Has('session') then UserID := Jar.Get('session');
//
// Response side: TPoseidonResponse helpers (defined in Poseidon.Response.pas)
//   Res.SetCookie('lang', 'pt-BR');
//   Res.SetCookie('cart', LId, TCookieOptions.New.HttpOnly(True).MaxAge(3600));
//   Res.SetSignedCookie('session', LUserId, MY_SECRET, ...);
//   Res.ClearCookie('session');
//
// Signing uses HMAC-SHA256(secret, value); the wire format is
//   `<value-base64url>.<sig-base64url>`
// which is URL-safe and self-describing.

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TCookieSameSite = (csUnset, csStrict, csLax, csNone);

  TCookieOptions = record
    Path:     string;
    Domain:   string;
    MaxAge:   Integer;   // seconds; 0 = session cookie; -1 = expire now (clear)
    HttpOnly: Boolean;
    Secure:   Boolean;
    SameSite: TCookieSameSite;
    class function Default: TCookieOptions; static;
    function WithPath(const APath: string): TCookieOptions;
    function WithDomain(const ADomain: string): TCookieOptions;
    function WithMaxAge(ASeconds: Integer): TCookieOptions;
    function AsHttpOnly: TCookieOptions;
    function AsSecure: TCookieOptions;
    function WithSameSite(ASame: TCookieSameSite): TCookieOptions;
  end;

  TCookieJar = class
  private
    FItems: TDictionary<string, string>;
  public
    constructor Create;
    destructor  Destroy; override;
    procedure Parse(const ACookieHeader: string);
    function  Has(const AName: string): Boolean;
    function  Get(const AName: string; const ADefault: string = ''): string;
    function  Count: Integer;
  end;

  TCookieFormat = class
  public
    // Builds a Set-Cookie header value: `name=value; Path=/; HttpOnly; ...`
    class function Build(const AName, AValue: string;
      const AOptions: TCookieOptions): string; static;

    // Computes HMAC-SHA256(secret, value) and returns `<value>.<sig>` using
    // URL-safe base64 (no padding) for both parts.
    class function Sign(const AValue, ASecret: string): string; static;

    // Returns True (with the decoded value) when ASigned matches the expected
    // signature for ASecret. Constant-time comparison.
    class function VerifySigned(const ASigned, ASecret: string;
      out AValue: string): Boolean; static;
  end;

implementation

uses
  System.Hash,
  System.NetEncoding;

{ TCookieOptions }

class function TCookieOptions.Default: TCookieOptions;
begin
  Result.Path     := '/';
  Result.Domain   := '';
  Result.MaxAge   := 0;
  Result.HttpOnly := False;
  Result.Secure   := False;
  Result.SameSite := csUnset;
end;

function TCookieOptions.WithPath(const APath: string): TCookieOptions;
begin
  Result := Self;
  Result.Path := APath;
end;

function TCookieOptions.WithDomain(const ADomain: string): TCookieOptions;
begin
  Result := Self;
  Result.Domain := ADomain;
end;

function TCookieOptions.WithMaxAge(ASeconds: Integer): TCookieOptions;
begin
  Result := Self;
  Result.MaxAge := ASeconds;
end;

function TCookieOptions.AsHttpOnly: TCookieOptions;
begin
  Result := Self;
  Result.HttpOnly := True;
end;

function TCookieOptions.AsSecure: TCookieOptions;
begin
  Result := Self;
  Result.Secure := True;
end;

function TCookieOptions.WithSameSite(ASame: TCookieSameSite): TCookieOptions;
begin
  Result := Self;
  Result.SameSite := ASame;
end;

{ TCookieJar }

constructor TCookieJar.Create;
begin
  inherited Create;
  FItems := TDictionary<string, string>.Create;
end;

destructor TCookieJar.Destroy;
begin
  FItems.Free;
  inherited;
end;

procedure TCookieJar.Parse(const ACookieHeader: string);
var
  LPart: string;
  LParts: TArray<string>;
  LEq: Integer;
  LName: string;
  LValue: string;
begin
  FItems.Clear;
  if ACookieHeader = '' then Exit;

  LParts := ACookieHeader.Split([';']);
  for LPart in LParts do
  begin
    LEq := Pos('=', LPart);
    if LEq <= 0 then Continue;
    LName  := Trim(Copy(LPart, 1, LEq - 1));
    LValue := Trim(Copy(LPart, LEq + 1, MaxInt));
    if LName <> '' then
      FItems.AddOrSetValue(LName, LValue);
  end;
end;

function TCookieJar.Has(const AName: string): Boolean;
begin
  Result := FItems.ContainsKey(AName);
end;

function TCookieJar.Get(const AName: string; const ADefault: string): string;
begin
  if not FItems.TryGetValue(AName, Result) then
    Result := ADefault;
end;

function TCookieJar.Count: Integer;
begin
  Result := FItems.Count;
end;

{ TCookieFormat }

function SameSiteString(AValue: TCookieSameSite): string;
begin
  case AValue of
    csStrict: Result := 'Strict';
    csLax:    Result := 'Lax';
    csNone:   Result := 'None';
  else        Result := '';
  end;
end;

class function TCookieFormat.Build(const AName, AValue: string;
  const AOptions: TCookieOptions): string;
var
  LSame: string;
begin
  Result := AName + '=' + AValue;

  if AOptions.Path <> '' then
    Result := Result + '; Path=' + AOptions.Path;
  if AOptions.Domain <> '' then
    Result := Result + '; Domain=' + AOptions.Domain;
  if AOptions.MaxAge <> 0 then
    Result := Result + '; Max-Age=' + IntToStr(AOptions.MaxAge);
  if AOptions.HttpOnly then
    Result := Result + '; HttpOnly';
  if AOptions.Secure then
    Result := Result + '; Secure';

  LSame := SameSiteString(AOptions.SameSite);
  if LSame <> '' then
    Result := Result + '; SameSite=' + LSame;
end;

function UrlSafeB64Encode(const ABytes: TBytes): string;
var
  I: Integer;
begin
  Result := TNetEncoding.Base64.EncodeBytesToString(ABytes);
  // strip padding and translate +/ → -_
  while (Length(Result) > 0) and (Result[Length(Result)] = '=') do
    SetLength(Result, Length(Result) - 1);
  for I := 1 to Length(Result) do
    case Result[I] of
      '+': Result[I] := '-';
      '/': Result[I] := '_';
    end;
end;

function UrlSafeB64Decode(const AStr: string): TBytes;
var
  LWork: string;
  I: Integer;
begin
  LWork := AStr;
  for I := 1 to Length(LWork) do
    case LWork[I] of
      '-': LWork[I] := '+';
      '_': LWork[I] := '/';
    end;
  // restore padding to multiple of 4
  case Length(LWork) mod 4 of
    2: LWork := LWork + '==';
    3: LWork := LWork + '=';
  end;
  Result := TNetEncoding.Base64.DecodeStringToBytes(LWork);
end;

function Sha256Bytes(const AData: TBytes): TBytes;
var
  H: THashSHA2;
begin
  H := THashSHA2.Create(SHA256);
  H.Update(AData);
  Result := H.HashAsBytes;
end;

function HmacSha256(const ASecret, AData: TBytes): TBytes;
const
  CBlockSize = 64;
  CIPad = $36;
  COPad = $5C;
var
  LKey: TBytes;
  LInnerKey: TBytes;
  LOuterKey: TBytes;
  LInner: TBytes;
  LOuter: TBytes;
  I: Integer;
begin
  // Step 1: hash long keys down to block size
  if Length(ASecret) > CBlockSize then
    LKey := Sha256Bytes(ASecret)
  else
    LKey := ASecret;

  // Step 2: pad to CBlockSize with zeros (SetLength zero-fills new TBytes bytes)
  if Length(LKey) < CBlockSize then
    SetLength(LKey, CBlockSize);

  // Step 3: build inner/outer XOR'd keys
  SetLength(LInnerKey, CBlockSize);
  SetLength(LOuterKey, CBlockSize);
  for I := 0 to CBlockSize - 1 do
  begin
    LInnerKey[I] := LKey[I] xor CIPad;
    LOuterKey[I] := LKey[I] xor COPad;
  end;

  // Step 4: inner = sha256(LInnerKey || data)
  SetLength(LInner, Length(LInnerKey) + Length(AData));
  if Length(LInnerKey) > 0 then
    Move(LInnerKey[0], LInner[0], Length(LInnerKey));
  if Length(AData) > 0 then
    Move(AData[0], LInner[Length(LInnerKey)], Length(AData));
  LInner := Sha256Bytes(LInner);

  // Step 5: outer = sha256(LOuterKey || inner)
  SetLength(LOuter, Length(LOuterKey) + Length(LInner));
  if Length(LOuterKey) > 0 then
    Move(LOuterKey[0], LOuter[0], Length(LOuterKey));
  if Length(LInner) > 0 then
    Move(LInner[0], LOuter[Length(LOuterKey)], Length(LInner));
  Result := Sha256Bytes(LOuter);
end;

class function TCookieFormat.Sign(const AValue, ASecret: string): string;
var
  LValBytes: TBytes;
  LSig:      TBytes;
begin
  LValBytes := TEncoding.UTF8.GetBytes(AValue);
  LSig := HmacSha256(TEncoding.UTF8.GetBytes(ASecret), LValBytes);
  Result := UrlSafeB64Encode(LValBytes) + '.' + UrlSafeB64Encode(LSig);
end;

function ConstantTimeEqual(const A, B: TBytes): Boolean;
var
  I:   Integer;
  Acc: Byte;
begin
  if Length(A) <> Length(B) then Exit(False);
  Acc := 0;
  for I := 0 to High(A) do
    Acc := Acc or (A[I] xor B[I]);
  Result := Acc = 0;
end;

class function TCookieFormat.VerifySigned(const ASigned, ASecret: string;
  out AValue: string): Boolean;
var
  LDot: Integer;
  LValPart: string;
  LSigPart: string;
  LValBytes: TBytes;
  LSigBytes: TBytes;
  LExpected: TBytes;
begin
  Result := False;
  AValue := '';

  LDot := Pos('.', ASigned);
  if LDot <= 1 then Exit;
  LValPart := Copy(ASigned, 1, LDot - 1);
  LSigPart := Copy(ASigned, LDot + 1, MaxInt);
  if (LValPart = '') or (LSigPart = '') then Exit;

  try
    LValBytes := UrlSafeB64Decode(LValPart);
    LSigBytes := UrlSafeB64Decode(LSigPart);
  except
    Exit;
  end;

  LExpected := HmacSha256(TEncoding.UTF8.GetBytes(ASecret), LValBytes);
  if not ConstantTimeEqual(LSigBytes, LExpected) then Exit;

  AValue := TEncoding.UTF8.GetString(LValBytes);
  Result := True;
end;

end.
