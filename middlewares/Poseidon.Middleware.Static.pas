unit Poseidon.Middleware.Static;

// Static file serving middleware for Poseidon.
//
// Serves files under ARootDir for requests matching AUrlPrefix.
// Features: ETag (size+mtime), Last-Modified, 304 Not Modified,
//           MIME type detection, gzip for compressible types.
// Directory traversal is blocked by canonicalizing the resolved path.
//
// Usage:
//   TPoseidon.Use(TPoseidonMiddlewareStatic.New('/static', 'C:\www\public'));
//   // GET /static/app.js  → serves C:\www\public\app.js

interface

uses
  Poseidon.Callback,
  Poseidon.Proc;

type
  TPoseidonMiddlewareStatic = class
  public
    class function New(const AUrlPrefix, ARootDir: string;
      AEnableGzip: Boolean = True): TPoseidonCallback; static;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  System.ZLib,
  Web.HTTPApp,
  Poseidon.Request,
  Poseidon.Response;

const
  MIME_MAP: array[0..23] of array[0..1] of string = (
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
  I:    Integer;
begin
  LExt := TPath.GetExtension(APath).ToLower;
  for I := 0 to High(MIME_MAP) do
    if MIME_MAP[I][0] = LExt then
      Exit(MIME_MAP[I][1]);
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

procedure GzipStream(AInput: TStream; AOutput: TStream);
var
  LZip: TZCompressionStream;
begin
  AInput.Position := 0;
  // WindowBits = 31 (15 + 16) = proper gzip envelope
  LZip := TZCompressionStream.Create(AOutput, zcDefault, 31);
  try
    LZip.CopyFrom(AInput, 0);
  finally
    LZip.Free;
  end;
end;

function BuildETag(const AInfo: TSearchRec): string;
begin
  Result := Format('"%d-%d"', [AInfo.Size, DateTimeToUnix(AInfo.TimeStamp, False)]);
end;

function FormatHTTPDate(ADate: TDateTime): string;
const
  DAYS:   array[1..7] of string = ('Sun','Mon','Tue','Wed','Thu','Fri','Sat');
  MONTHS: array[1..12] of string = ('Jan','Feb','Mar','Apr','May','Jun',
                                     'Jul','Aug','Sep','Oct','Nov','Dec');
var
  Y, M, D, H, Mn, S, Ms: Word;
  DOW: Integer;
begin
  DecodeDateTime(ADate, Y, M, D, H, Mn, S, Ms);
  DOW := DayOfWeek(ADate);
  Result := Format('%s, %02d %s %04d %02d:%02d:%02d GMT',
    [DAYS[DOW], D, MONTHS[M], Y, H, Mn, S]);
end;

class function TPoseidonMiddlewareStatic.New(const AUrlPrefix, ARootDir: string;
  AEnableGzip: Boolean): TPoseidonCallback;
var
  LRoot:   string;
  LPrefix: string;
begin
  LRoot   := TPath.GetFullPath(IncludeTrailingPathDelimiter(ARootDir));
  LPrefix := AUrlPrefix.TrimRight(['/']);

  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LPath:      string;
      LRelative:  string;
      LAbsolute:  string;
      LMime:      string;
      LSR:        TSearchRec;
      LETag:      string;
      LFileStream: TFileStream;
      LOutStream:  TMemoryStream;
      LAccept:    string;
      LUseGzip:   Boolean;
      LIfNoneMatch: string;
    begin
      LPath := Req.PathInfo;

      // Only handle paths matching the prefix
      if not LPath.StartsWith(LPrefix) then
      begin
        Next();
        Exit;
      end;

      // Extract relative path and block traversal sequences immediately
      LRelative := LPath.Substring(Length(LPrefix));
      if LRelative.Contains('..') then
      begin
        Res.Status(403).Send('');
        Exit;
      end;
      LRelative := LRelative.Replace('/', PathDelim);
      LRelative := LRelative.TrimLeft([PathDelim]);
      if LRelative.IsEmpty then
        LRelative := 'index.html';

      LAbsolute := TPath.GetFullPath(TPath.Combine(LRoot, LRelative));

      // Secondary traversal check after canonicalization
      if not LAbsolute.StartsWith(LRoot) then
      begin
        Res.Status(403).Send('');
        Exit;
      end;

      if not TFile.Exists(LAbsolute) then
      begin
        Next();
        Exit;
      end;

      // Get file info for ETag and Last-Modified
      if FindFirst(LAbsolute, faAnyFile, LSR) <> 0 then
      begin
        Next();
        Exit;
      end;
      try
        LETag := BuildETag(LSR);
        LMime := GetMimeType(LAbsolute);

        // 304 Not Modified check
        LIfNoneMatch := Req.RawWebRequest.GetFieldByName('If-None-Match');
        if (LIfNoneMatch <> '') and (LIfNoneMatch = LETag) then
        begin
          Res.Status(304)
             .Header('ETag', LETag)
             .Send('');
          Exit;
        end;

        LAccept   := Req.RawWebRequest.GetFieldByName('Accept-Encoding');
        LUseGzip  := AEnableGzip and LAccept.Contains('gzip') and IsCompressible(LMime);

        LFileStream := TFileStream.Create(LAbsolute, fmOpenRead or fmShareDenyWrite);
        try
          Res.Status(200);
          Res.Header('Content-Type', LMime);
          Res.Header('ETag', LETag);
          Res.Header('Last-Modified',
            FormatHTTPDate(LSR.TimeStamp));
          Res.Header('Cache-Control', 'public, max-age=3600');

          if LUseGzip then
          begin
            LOutStream := TMemoryStream.Create;
            GzipStream(LFileStream, LOutStream);
            LOutStream.Position := 0;
            Res.Header('Content-Encoding', 'gzip');
            Res.Header('Vary', 'Accept-Encoding');
            Res.RawWebResponse.ContentStream  := LOutStream;
            Res.RawWebResponse.ContentLength  := LOutStream.Size;
          end
          else
          begin
            Res.RawWebResponse.ContentStream := LFileStream;
            Res.RawWebResponse.ContentLength := LFileStream.Size;
            LFileStream := nil; // ownership transferred
          end;
        finally
          LFileStream.Free;
        end;

      finally
        FindClose(LSR);
      end;
    end;
end;

end.
