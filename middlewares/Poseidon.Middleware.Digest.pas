unit Poseidon.Middleware.Digest;

interface

uses
  System.SysUtils,
  System.NetEncoding,
  System.Hash,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback;

type
  TPoseidonMiddlewareDigest = class
  private
    class function _DigestParam(const AHeader, AKey: string): string; static;
    class function _GenerateNonce: string; static;
    class function _WwwAuthenticate(const ARealm, ANonce: string): string; static;
  public
    class function New(
      const ARealm: string;
      AGetHA1: reference to function(const AUser, ARealm: string): string
    ): TPoseidonCallback; static;

    class function HA1(const AUser, ARealm, APass: string): string; static;
  end;

implementation

uses
  System.DateUtils,
  System.Math;

class function TPoseidonMiddlewareDigest._DigestParam(const AHeader, AKey: string): string;
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

class function TPoseidonMiddlewareDigest._GenerateNonce: string;
var
  LTimestamp: string;
  LRandom: string;
  LRaw: string;
begin
  LTimestamp := IntToHex(DateTimeToUnix(TTimeZone.Local.ToUniversalTime(Now), False), 8);
  LRandom    := IntToHex(Random(MaxInt), 8) + IntToHex(Random(MaxInt), 8);
  LRaw       := LTimestamp + ':' + LRandom;
  Result     := TNetEncoding.Base64String.Encode(LRaw);
end;

class function TPoseidonMiddlewareDigest._WwwAuthenticate(const ARealm, ANonce: string): string;
begin
  Result := 'Digest realm="' + ARealm + '", nonce="' + ANonce +
            '", algorithm=MD5, qop="auth"';
end;

class function TPoseidonMiddlewareDigest.HA1(const AUser, ARealm, APass: string): string;
begin
  Result := LowerCase(THashMD5.GetHashString(AnsiString(AUser + ':' + ARealm + ':' + APass)));
end;

class function TPoseidonMiddlewareDigest.New(
  const ARealm: string;
  AGetHA1: reference to function(const AUser, ARealm: string): string
): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LAuthHeader: string;
      LUsername, LRealm, LNonce, LUri, LQop, LNc, LCnonce, LResponse: string;
      LHA1, LHA2, LExpected, LNonce401: string;
      LMethod: string;
    begin
      LAuthHeader := Req.Headers.GetOrDefault('Authorization', '');

      if (LAuthHeader = '') or not LAuthHeader.StartsWith('Digest ', True) then
      begin
        LNonce401 := _GenerateNonce;
        Res.Status(401)
           .Header('WWW-Authenticate', _WwwAuthenticate(ARealm, LNonce401))
           .Send('Unauthorized');
        Exit;
      end;

      LUsername := _DigestParam(LAuthHeader, 'username');
      LRealm    := _DigestParam(LAuthHeader, 'realm');
      LNonce    := _DigestParam(LAuthHeader, 'nonce');
      LUri      := _DigestParam(LAuthHeader, 'uri');
      LQop      := _DigestParam(LAuthHeader, 'qop');
      LNc       := _DigestParam(LAuthHeader, 'nc');
      LCnonce   := _DigestParam(LAuthHeader, 'cnonce');
      LResponse := _DigestParam(LAuthHeader, 'response');

      LHA1 := AGetHA1(LUsername, LRealm);
      if LHA1 = '' then
      begin
        LNonce401 := _GenerateNonce;
        Res.Status(401)
           .Header('WWW-Authenticate', _WwwAuthenticate(ARealm, LNonce401))
           .Send('Unauthorized');
        Exit;
      end;

      LMethod := Req.RawWebRequest.Method;
      LHA2    := LowerCase(THashMD5.GetHashString(AnsiString(LMethod + ':' + LUri)));

      if SameText(LQop, 'auth') then
        LExpected := LowerCase(THashMD5.GetHashString(
          AnsiString(LHA1 + ':' + LNonce + ':' + LNc + ':' + LCnonce + ':' + LQop + ':' + LHA2)))
      else
        LExpected := LowerCase(THashMD5.GetHashString(
          AnsiString(LHA1 + ':' + LNonce + ':' + LHA2)));

      if not SameText(LExpected, LResponse) then
      begin
        LNonce401 := _GenerateNonce;
        Res.Status(401)
           .Header('WWW-Authenticate', _WwwAuthenticate(ARealm, LNonce401))
           .Send('Unauthorized');
        Exit;
      end;

      Next;
    end;
end;

end.
