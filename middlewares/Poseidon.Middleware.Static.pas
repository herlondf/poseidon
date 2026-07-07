unit Poseidon.Middleware.Static;

// Static file serving middleware.
// Features: ETag, Last-Modified, 304 Not Modified, MIME detection, gzip.
//
// Usage:
//   App.Use(StaticMiddleware('/static', 'C:\www\public'));

interface

uses
  Poseidon.Native.Types;

function StaticMiddleware(const AUrlPrefix, ARootDir: string;
  AEnableGzip: Boolean = True): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  System.ZLib;

const
  CMimeMap: array[0..23] of array[0..1] of string = (
    ('.html',  'text/html; charset=utf-8'),
    ('.htm',   'text/html; charset=utf-8'),
    ('.css',   'text/css; charset=utf-8'),
    ('.js',    'application/javascript; charset=utf-8'),
    ('.mjs',   'application/javascript; charset=utf-8'),
    ('.json',  'application/json; charset=utf-8'),
    ('.xml',   'application/xml; charset=utf-8'),
    ('.svg',   'image/svg+xml'),
    ('.png',   'image/png'),
    ('.jpg',   'image/jpeg'),
    ('.jpeg',  'image/jpeg'),
    ('.gif',   'image/gif'),
    ('.ico',   'image/x-icon'),
    ('.webp',  'image/webp'),
    ('.woff',  'font/woff'),
    ('.woff2', 'font/woff2'),
    ('.ttf',   'font/ttf'),
    ('.pdf',   'application/pdf'),
    ('.zip',   'application/zip'),
    ('.mp4',   'video/mp4'),
    ('.webm',  'video/webm'),
    ('.mp3',   'audio/mpeg'),
    ('.txt',   'text/plain; charset=utf-8'),
    ('.csv',   'text/csv; charset=utf-8')
  );

function GetMimeType(const APath: string): string;
var
  LExt: string;
  I: Integer;
begin
  LExt := TPath.GetExtension(APath).ToLower;
  for I := 0 to High(CMimeMap) do
    if CMimeMap[I][0] = LExt then
      Exit(CMimeMap[I][1]);
  Result := 'application/octet-stream';
end;

function IsCompressible(const AMimeType: string): Boolean;
begin
  Result := AMimeType.StartsWith('text/') or
            AMimeType.Contains('javascript') or
            AMimeType.Contains('json') or
            AMimeType.Contains('xml') or
            AMimeType.Contains('svg');
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

function BuildETag(const AInfo: TSearchRec): string;
begin
  Result := Format('"%d-%d"', [AInfo.Size, DateTimeToUnix(AInfo.TimeStamp, False)]);
end;

function FormatHTTPDate(ADate: TDateTime): string;
const
  CDays: array[1..7] of string = ('Sun','Mon','Tue','Wed','Thu','Fri','Sat');
  CMonths: array[1..12] of string = ('Jan','Feb','Mar','Apr','May','Jun',
    'Jul','Aug','Sep','Oct','Nov','Dec');
var
  Y, M, D, H, Mn, S, Ms: Word;
  LDOW: Integer;
begin
  DecodeDateTime(ADate, Y, M, D, H, Mn, S, Ms);
  LDOW := DayOfWeek(ADate);
  Result := Format('%s, %02d %s %04d %02d:%02d:%02d GMT',
    [CDays[LDOW], D, CMonths[M], Y, H, Mn, S]);
end;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function StaticMiddleware(const AUrlPrefix, ARootDir: string;
  AEnableGzip: Boolean): TNativeMiddlewareFunc;
var
  LRoot, LPrefix: string;
begin
  LRoot := TPath.GetFullPath(IncludeTrailingPathDelimiter(ARootDir));
  LPrefix := AUrlPrefix.TrimRight(['/']);

  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LRelative, LAbsolute, LMime, LETag, LIfNoneMatch, LAccept: string;
      LSR: TSearchRec;
      LFileBytes, LCompressed: TBytes;
      LUseGzip: Boolean;
    begin
      if not ACtx.Path.StartsWith(LPrefix) then
      begin
        ANext();
        Exit;
      end;

      LRelative := ACtx.Path.Substring(Length(LPrefix));
      if LRelative.Contains('..') then
      begin
        ACtx.Status := 403;
        ACtx.Body := nil;
        ACtx.Handled := True;
        Exit;
      end;
      LRelative := LRelative.Replace('/', PathDelim).TrimLeft([PathDelim]);
      if LRelative = '' then
        LRelative := 'index.html';

      LAbsolute := TPath.GetFullPath(TPath.Combine(LRoot, LRelative));

      if not LAbsolute.StartsWith(LRoot) then
      begin
        ACtx.Status := 403;
        ACtx.Body := nil;
        ACtx.Handled := True;
        Exit;
      end;

      if not TFile.Exists(LAbsolute) then
      begin
        ANext();
        Exit;
      end;

      if FindFirst(LAbsolute, faAnyFile, LSR) <> 0 then
      begin
        ANext();
        Exit;
      end;
      try
        LETag := BuildETag(LSR);
        LMime := GetMimeType(LAbsolute);

        LIfNoneMatch := ACtx.Header('If-None-Match');
        if (LIfNoneMatch <> '') and (LIfNoneMatch = LETag) then
        begin
          ACtx.Status := 304;
          ACtx.Body := nil;
          AddHeader(ACtx, 'ETag', LETag);
          ACtx.Handled := True;
          Exit;
        end;

        LAccept := ACtx.Header('Accept-Encoding');
        LUseGzip := AEnableGzip and LAccept.Contains('gzip') and IsCompressible(LMime);

        LFileBytes := TFile.ReadAllBytes(LAbsolute);

        ACtx.Status := 200;
        ACtx.ContentType := LMime;
        AddHeader(ACtx, 'ETag', LETag);
        AddHeader(ACtx, 'Last-Modified', FormatHTTPDate(LSR.TimeStamp));
        AddHeader(ACtx, 'Cache-Control', 'public, max-age=3600');

        if LUseGzip then
        begin
          GzipBytes(LFileBytes, LCompressed);
          ACtx.Body := LCompressed;
          AddHeader(ACtx, 'Content-Encoding', 'gzip');
          AddHeader(ACtx, 'Vary', 'Accept-Encoding');
        end
        else
          ACtx.Body := LFileBytes;

        ACtx.Handled := True;
      finally
        FindClose(LSR);
      end;
    end;
end;

end.
