unit Poseidon.Middleware.Compression;

// Gzip compression middleware.
// Compresses text-like responses when client advertises Accept-Encoding: gzip.
//
// Usage:
//   App.Use(CompressionMiddleware);
//   App.Use(CompressionMiddleware(2048));

interface

uses
  Poseidon.Native.Types;

function CompressionMiddleware(AMinSize: Integer = 860): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.ZLib;

function IsCompressibleType(const AContentType: string): Boolean;
begin
  Result := AContentType.Contains('text/') or
            AContentType.Contains('application/json') or
            AContentType.Contains('application/javascript') or
            AContentType.Contains('application/xml') or
            AContentType.Contains('application/x-www-form-urlencoded') or
            AContentType.Contains('image/svg+xml');
end;

procedure GzipBytes(const AInput: TBytes; out AOutput: TBytes);
var
  LOutput: TMemoryStream;
  LZip: TZCompressionStream;
begin
  LOutput := TMemoryStream.Create;
  try
    LZip := TZCompressionStream.Create(LOutput, zcDefault, 31);
    try
      if Length(AInput) > 0 then
        LZip.WriteBuffer(AInput[0], Length(AInput));
    finally
      LZip.Free;
    end;
    SetLength(AOutput, LOutput.Size);
    if LOutput.Size > 0 then
      Move(LOutput.Memory^, AOutput[0], LOutput.Size);
  finally
    LOutput.Free;
  end;
end;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function HasHeaderNamed(const ACtx: TNativeRequestContext; const AName: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(ACtx.ExtraHeaders) do
    if SameText(ACtx.ExtraHeaders[I].Key, AName) then
      Exit(True);
end;

function VaryHasAcceptEncoding(const ACtx: TNativeRequestContext): Boolean;
var
  I: Integer;
begin
  Result := False;
  for I := 0 to High(ACtx.ExtraHeaders) do
    if SameText(ACtx.ExtraHeaders[I].Key, 'Vary') and
       ACtx.ExtraHeaders[I].Value.ToLower.Contains('accept-encoding') then
      Exit(True);
end;

// True only if the q-value string represents zero (e.g. "0", "0.0", "0.000").
function QIsZero(const AQStr: string): Boolean;
var
  LDigits: string;
  I: Integer;
begin
  LDigits := StringReplace(AQStr.Trim, '.', '', [rfReplaceAll]);
  if LDigits = '' then
    Exit(False);
  for I := 1 to Length(LDigits) do
    if LDigits[I] <> '0' then
      Exit(False);
  Result := True;
end;

// Parses Accept-Encoding honoring q-values: gzip is acceptable when it appears
// with q>0, or (when gzip is not listed) when '*' appears with q>0. #M4
function AcceptsGzip(const AAcceptEncoding: string): Boolean;
var
  LParts: TArray<string>;
  I, LSemi, LQPos: Integer;
  LToken, LCoding, LParams, LQStr: string;
  LGzip, LStar: Integer;  // -1 = unset, 0 = q=0, 1 = q>0
begin
  LGzip := -1;
  LStar := -1;
  LParts := AAcceptEncoding.Split([',']);
  for I := 0 to High(LParts) do
  begin
    LToken := LParts[I].Trim;
    if LToken = '' then
      Continue;
    LSemi := Pos(';', LToken);
    if LSemi > 0 then
    begin
      LCoding := Copy(LToken, 1, LSemi - 1).Trim.ToLower;
      LParams := Copy(LToken, LSemi + 1, MaxInt).ToLower;
    end
    else
    begin
      LCoding := LToken.ToLower;
      LParams := '';
    end;

    LQPos := Pos('q=', LParams);
    if LQPos > 0 then
      LQStr := Copy(LParams, LQPos + 2, MaxInt).Trim
    else
      LQStr := '';  // no q -> defaults to 1 (acceptable)

    if LCoding = 'gzip' then
      if (LQStr <> '') and QIsZero(LQStr) then LGzip := 0 else LGzip := 1
    else if LCoding = '*' then
      if (LQStr <> '') and QIsZero(LQStr) then LStar := 0 else LStar := 1;
  end;

  if LGzip = 1 then Exit(True);
  if LGzip = 0 then Exit(False);
  Result := LStar = 1;
end;

function CompressionMiddleware(AMinSize: Integer): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LCompressed: TBytes;
    begin
      ANext();

      // #M2: bodyless responses (204, 304, 1xx) must never carry Content-Encoding.
      if (ACtx.Status = 204) or (ACtx.Status = 304) or
         ((ACtx.Status >= 100) and (ACtx.Status < 200)) then
        Exit;

      if not IsCompressibleType(ACtx.ContentType) then
        Exit;

      // #M5: the response varies by Accept-Encoding even when we end up not
      // compressing (small body / opt-out), so caches must key on it.
      if not VaryHasAcceptEncoding(ACtx) then
        AddHeader(ACtx, 'Vary', 'Accept-Encoding');

      // #M3: don't re-encode a body another middleware already encoded.
      if HasHeaderNamed(ACtx, 'Content-Encoding') then
        Exit;

      if not AcceptsGzip(ACtx.Header('Accept-Encoding')) then
        Exit;

      if Length(ACtx.Body) < AMinSize then
        Exit;

      GzipBytes(ACtx.Body, LCompressed);
      ACtx.Body := LCompressed;
      AddHeader(ACtx, 'Content-Encoding', 'gzip');
    end;
end;

end.
