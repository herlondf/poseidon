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
  System.NetEncoding,
  System.Hash,
  System.Generics.Collections,
  System.DateUtils;

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

function GenerateNonce: string;
var
  LRaw: string;
begin
  LRaw := IntToHex(DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), False), 8) +
    ':' + IntToHex(Random(MaxInt), 8) + IntToHex(Random(MaxInt), 8);
  Result := TNetEncoding.Base64String.Encode(LRaw);
end;

function WwwAuthenticate(const ARealm, ANonce: string): string;
begin
  Result := 'Digest realm="' + ARealm + '", nonce="' + ANonce +
    '", algorithm=MD5, qop="auth"';
end;

function DigestHA1(const AUser, ARealm, APass: string): string;
begin
  Result := LowerCase(THashMD5.GetHashString(AnsiString(AUser + ':' + ARealm + ':' + APass)));
end;

procedure Unauthorized(var ACtx: TNativeRequestContext; const ARealm: string);
var
  LNonce: string;
  LLen: Integer;
begin
  LNonce := GenerateNonce;
  ACtx.Status := 401;
  ACtx.ContentType := 'text/plain';
  ACtx.Body := TEncoding.UTF8.GetBytes('Unauthorized');
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(
    'WWW-Authenticate', WwwAuthenticate(ARealm, LNonce));
  ACtx.Handled := True;
end;

function DigestMiddleware(const ARealm: string; AGetHA1: TGetHA1Func): TNativeMiddlewareFunc;
begin
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
        Unauthorized(ACtx, ARealm);
        Exit;
      end;

      LUsername := DigestParam(LAuthHeader, 'username');
      LRealm := DigestParam(LAuthHeader, 'realm');
      LNonce := DigestParam(LAuthHeader, 'nonce');
      LUri := DigestParam(LAuthHeader, 'uri');
      LQop := DigestParam(LAuthHeader, 'qop');
      LNc := DigestParam(LAuthHeader, 'nc');
      LCnonce := DigestParam(LAuthHeader, 'cnonce');
      LResponse := DigestParam(LAuthHeader, 'response');

      LHA1 := AGetHA1(LUsername, LRealm);
      if LHA1 = '' then
      begin
        Unauthorized(ACtx, ARealm);
        Exit;
      end;

      LHA2 := LowerCase(THashMD5.GetHashString(AnsiString(ACtx.Method + ':' + LUri)));

      if SameText(LQop, 'auth') then
        LExpected := LowerCase(THashMD5.GetHashString(
          AnsiString(LHA1 + ':' + LNonce + ':' + LNc + ':' + LCnonce + ':' + LQop + ':' + LHA2)))
      else
        LExpected := LowerCase(THashMD5.GetHashString(
          AnsiString(LHA1 + ':' + LNonce + ':' + LHA2)));

      if not SameText(LExpected, LResponse) then
      begin
        Unauthorized(ACtx, ARealm);
        Exit;
      end;

      ANext();
    end;
end;

end.
