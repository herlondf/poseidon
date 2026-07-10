unit Poseidon.Middleware.Digest;

// HTTP Digest Authentication (MD5, qop=auth).
//
// Usage:
//   App.Use(DigestMiddleware('MyRealm',
//     function(const AUser, ARealm: string): string
//     begin
//       Result := DigestHA1(AUser, ARealm, 'password');
//     end));

interface

uses
  System.SysUtils,
  Poseidon.Native.Types;

type
  TGetHA1Func = reference to function(const AUser, ARealm: string): string;

function DigestMiddleware(const ARealm: string; AGetHA1: TGetHA1Func): TNativeMiddlewareFunc;
function DigestHA1(const AUser, ARealm, APass: string): string;

implementation

uses
  System.Classes,
  System.SyncObjs,
  System.NetEncoding,
  System.Hash,
  System.Generics.Collections,
  System.DateUtils;

const
  CNonceTtlSec = 300;      // issued nonces are valid for 5 minutes
  CMaxNonces   = 100000;   // hard cap so a 401 flood cannot exhaust memory

type
  TNonceState = record
    IssuedAt: TDateTime;
    LastNc: Cardinal;
  end;

  // Tracks server-issued nonces so a captured Authorization header cannot be
  // replayed: a nonce must have been issued, not expired, and each reuse must
  // carry a strictly increasing nonce-count (nc). Shared across worker threads.
  TDigestNonceStore = class
  private
    FLock: TCriticalSection;
    FNonces: TDictionary<string, TNonceState>;
    FSecret: string;
    FCounter: Int64;
    procedure Purge(ANow: TDateTime);
  public
    constructor Create;
    destructor Destroy; override;
    function NewNonce: string;
    function Accept(const ANonce: string; ANc: Cardinal): Boolean;
  end;

function MD5HexUTF8(const AInput: string): string;
var
  LMD5: THashMD5;
begin
  // Hash the explicit UTF-8 bytes. The old AnsiString() cast narrowed to Latin-1
  // and diverged from RFC 7616 clients for non-ASCII user/realm/password.
  LMD5 := THashMD5.Create;
  LMD5.Update(TEncoding.UTF8.GetBytes(AInput));
  Result := LowerCase(LMD5.HashAsString);
end;

// Constant-time comparison — never short-circuits on the first differing byte,
// so response timing cannot leak the expected MD5 hash byte-by-byte.
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

function ParseHexNc(const ANc: string): Cardinal;
var
  LVal: Int64;
begin
  LVal := StrToInt64Def('$' + ANc, 0);
  if (LVal < 0) or (LVal > High(Cardinal)) then
    Result := 0
  else
    Result := Cardinal(LVal);
end;

{ TDigestNonceStore }

constructor TDigestNonceStore.Create;
var
  LEntropy: string;
begin
  FLock := TCriticalSection.Create;
  FNonces := TDictionary<string, TNonceState>.Create;
  FCounter := 0;
  Randomize;
  // Per-process secret. Nonce unpredictability is defense-in-depth; the real
  // replay protection is the issued-nonce + nc tracking in Accept().
  LEntropy := IntToStr(TThread.GetTickCount64) + ':' +
    IntToStr(DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), False)) + ':' +
    IntToHex(NativeUInt(Pointer(Self)), 16) + ':' +
    IntToStr(Random(MaxInt)) + ':' + IntToStr(Random(MaxInt));
  FSecret := THashSHA2.GetHashString(LEntropy);
end;

destructor TDigestNonceStore.Destroy;
begin
  FNonces.Free;
  FLock.Free;
  inherited;
end;

procedure TDigestNonceStore.Purge(ANow: TDateTime);
var
  LPair: TPair<string, TNonceState>;
  LStale: TArray<string>;
  LKey: string;
begin
  SetLength(LStale, 0);
  for LPair in FNonces do
    if SecondsBetween(ANow, LPair.Value.IssuedAt) > CNonceTtlSec then
    begin
      SetLength(LStale, Length(LStale) + 1);
      LStale[High(LStale)] := LPair.Key;
    end;
  for LKey in LStale do
    FNonces.Remove(LKey);
end;

function TDigestNonceStore.NewNonce: string;
var
  LState: TNonceState;
begin
  FLock.Enter;
  try
    Purge(Now);
    Inc(FCounter);
    Result := LowerCase(THashSHA2.GetHashString(
      FSecret + ':' + IntToStr(FCounter) + ':' + IntToStr(TThread.GetTickCount64)));
    // Under a sustained 401 flood, stop tracking new nonces rather than grow
    // unbounded. Those requests simply cannot complete Digest until load drops.
    if FNonces.Count < CMaxNonces then
    begin
      LState.IssuedAt := Now;
      LState.LastNc := 0;
      FNonces.AddOrSetValue(Result, LState);
    end;
  finally
    FLock.Leave;
  end;
end;

function TDigestNonceStore.Accept(const ANonce: string; ANc: Cardinal): Boolean;
var
  LState: TNonceState;
begin
  Result := False;
  FLock.Enter;
  try
    Purge(Now);
    if not FNonces.TryGetValue(ANonce, LState) then
      Exit;  // unknown / expired / never issued -> reject (replay or forgery)
    if ANc <= LState.LastNc then
      Exit;  // nc must strictly increase -> blocks replay of a captured header
    LState.LastNc := ANc;
    FNonces.AddOrSetValue(ANonce, LState);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function DigestParam(const AHeader, AKey: string): string;
var
  LPos, LEnd: Integer;
  LSearch: string;
begin
  Result := '';
  LSearch := AKey + '="';
  LPos := Pos(LSearch, AHeader);
  if LPos > 0 then
  begin
    Inc(LPos, Length(LSearch));
    LEnd := LPos;
    while (LEnd <= Length(AHeader)) and (AHeader[LEnd] <> '"') do
      Inc(LEnd);
    Result := Copy(AHeader, LPos, LEnd - LPos);
    Exit;
  end;
  LSearch := AKey + '=';
  LPos := Pos(LSearch, AHeader);
  if LPos > 0 then
  begin
    Inc(LPos, Length(LSearch));
    LEnd := LPos;
    while (LEnd <= Length(AHeader)) and (AHeader[LEnd] <> ',') and (AHeader[LEnd] <> ' ') do
      Inc(LEnd);
    Result := Copy(AHeader, LPos, LEnd - LPos).Trim;
  end;
end;

function WwwAuthenticate(const ARealm, ANonce: string; AStale: Boolean): string;
begin
  Result := 'Digest realm="' + ARealm + '", nonce="' + ANonce +
    '", algorithm=MD5, qop="auth"';
  if AStale then
    Result := Result + ', stale=true';
end;

function DigestHA1(const AUser, ARealm, APass: string): string;
begin
  Result := MD5HexUTF8(AUser + ':' + ARealm + ':' + APass);
end;

procedure Unauthorized(var ACtx: TNativeRequestContext; const ARealm: string;
  AStore: TDigestNonceStore; AStale: Boolean);
var
  LNonce: string;
  LLen: Integer;
begin
  LNonce := AStore.NewNonce;
  ACtx.Status := 401;
  ACtx.ContentType := 'text/plain';
  ACtx.Body := TEncoding.UTF8.GetBytes('Unauthorized');
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(
    'WWW-Authenticate', WwwAuthenticate(ARealm, LNonce, AStale));
  ACtx.Handled := True;
end;

function DigestMiddleware(const ARealm: string; AGetHA1: TGetHA1Func): TNativeMiddlewareFunc;
var
  LStore: TDigestNonceStore;
begin
  LStore := TDigestNonceStore.Create;
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LAuthHeader: string;
      LUsername, LRealm, LNonce, LUri, LQop, LNc, LCnonce, LResponse: string;
      LHA1, LHA2, LExpected: string;
    begin
      LAuthHeader := ACtx.Header('Authorization');

      if (LAuthHeader = '') or not LAuthHeader.StartsWith('Digest ', True) then
      begin
        Unauthorized(ACtx, ARealm, LStore, False);
        Exit;
      end;

      LUsername := DigestParam(LAuthHeader, 'username');
      LRealm    := DigestParam(LAuthHeader, 'realm');
      LNonce    := DigestParam(LAuthHeader, 'nonce');
      LUri      := DigestParam(LAuthHeader, 'uri');
      LQop      := DigestParam(LAuthHeader, 'qop');
      LNc       := DigestParam(LAuthHeader, 'nc');
      LCnonce   := DigestParam(LAuthHeader, 'cnonce');
      LResponse := DigestParam(LAuthHeader, 'response');

      // We only advertise qop="auth"; require it (rejects the weaker legacy mode).
      if not SameText(LQop, 'auth') then
      begin
        Unauthorized(ACtx, ARealm, LStore, False);
        Exit;
      end;

      LHA1 := AGetHA1(LUsername, LRealm);
      if LHA1 = '' then
      begin
        Unauthorized(ACtx, ARealm, LStore, False);
        Exit;
      end;

      LHA2 := MD5HexUTF8(ACtx.Method + ':' + LUri);
      LExpected := MD5HexUTF8(
        LHA1 + ':' + LNonce + ':' + LNc + ':' + LCnonce + ':' + LQop + ':' + LHA2);

      // Constant-time compare first (never leak the expected hash via timing).
      if not ConstantTimeEquals(LExpected, LResponse) then
      begin
        Unauthorized(ACtx, ARealm, LStore, False);
        Exit;
      end;

      // Credentials are correct; now enforce nonce freshness + nc monotonicity.
      // A replayed header reuses an nc already seen -> rejected as stale so the
      // client retries with a freshly issued nonce.
      if not LStore.Accept(LNonce, ParseHexNc(LNc)) then
      begin
        Unauthorized(ACtx, ARealm, LStore, True);
        Exit;
      end;

      ANext();
    end;
end;

end.
