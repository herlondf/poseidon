unit Poseidon.Middleware.Logger;

// Logs each request: method, path, status, elapsed time.
//
// Usage:
//   App.Use(LoggerMiddleware);
//   App.Use(LoggerMiddleware(MyOutput));
//   App.Use(LoggerMiddlewareJSON);

interface

uses
  System.SysUtils,
  Poseidon.Native.Types;

type
  TLogOutput = reference to procedure(const ALine: string);

function LoggerMiddleware: TNativeMiddlewareFunc; overload;
function LoggerMiddleware(AOutput: TLogOutput): TNativeMiddlewareFunc; overload;
function LoggerMiddlewareJSON: TNativeMiddlewareFunc; overload;
function LoggerMiddlewareJSON(AOutput: TLogOutput): TNativeMiddlewareFunc; overload;
function LogToFile(const AFileName: string): TLogOutput;

implementation

uses
  System.Classes,
  System.SyncObjs,
  System.Diagnostics;

// Escapes a string for embedding inside a JSON string literal. Escapes the
// characters JSON requires (quote, backslash, control chars) but NOT '/', so
// paths stay readable ("/test", not "\/test"). Prevents log-line injection via
// client-controlled values (path, X-Request-ID).
function JSONEscape(const S: string): string;
var
  I: Integer;
  LSB: TStringBuilder;
begin
  LSB := TStringBuilder.Create;
  try
    for I := 1 to Length(S) do
      case S[I] of
        '"': LSB.Append('\"');
        '\': LSB.Append('\\');
        #8:  LSB.Append('\b');
        #9:  LSB.Append('\t');
        #10: LSB.Append('\n');
        #12: LSB.Append('\f');
        #13: LSB.Append('\r');
        #0..#7, #11, #14..#31:
          LSB.Append('\u').Append(IntToHex(Ord(S[I]), 4));
      else
        LSB.Append(S[I]);
      end;
    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure DefaultOutput(const ALine: string);
begin
  Writeln(ALine);
end;

function FindExtraHeader(const ACtx: TNativeRequestContext; const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ACtx.ExtraHeaders) do
    if SameText(ACtx.ExtraHeaders[I].Key, AName) then
      Exit(ACtx.ExtraHeaders[I].Value);
end;

function LoggerMiddleware: TNativeMiddlewareFunc;
begin
  Result := LoggerMiddleware(DefaultOutput);
end;

function LoggerMiddleware(AOutput: TLogOutput): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LSW: TStopwatch;
    begin
      LSW := TStopwatch.StartNew;
      ANext();
      LSW.Stop;
      AOutput(Format('[%s] %s %s %d (%dms)',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
         ACtx.Method, ACtx.Path, ACtx.Status,
         LSW.ElapsedMilliseconds]));
    end;
end;

function LoggerMiddlewareJSON: TNativeMiddlewareFunc;
begin
  Result := LoggerMiddlewareJSON(DefaultOutput);
end;

function LoggerMiddlewareJSON(AOutput: TLogOutput): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LSW: TStopwatch;
      LReqID: string;
    begin
      LSW := TStopwatch.StartNew;
      ANext();
      LSW.Stop;
      LReqID := FindExtraHeader(ACtx, 'X-Request-ID');
      // Escape client-controlled values (path, id from X-Request-ID) so they
      // cannot break the line and inject a forged log entry.
      AOutput(Format(
        '{"ts":"%s","method":"%s","path":"%s","status":%d,"ms":%d,"ip":"%s","id":"%s"}',
        [FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now),
         JSONEscape(ACtx.Method), JSONEscape(ACtx.Path), ACtx.Status,
         LSW.ElapsedMilliseconds, JSONEscape(ACtx.RemoteAddr), JSONEscape(LReqID)]));
    end;
end;

function LogToFile(const AFileName: string): TLogOutput;
var
  LLock: TCriticalSection;
  LStream: TFileStream;
begin
  // #182: open the file ONCE and serialize writes with a lock. Creating a new
  // TStreamWriter per line raced across worker threads (Windows sharing
  // violation; Linux interleaved partial lines / corrupted file).
  if FileExists(AFileName) then
    LStream := TFileStream.Create(AFileName, fmOpenReadWrite or fmShareDenyWrite)
  else
    LStream := TFileStream.Create(AFileName, fmCreate or fmShareDenyWrite);
  LStream.Seek(0, soEnd);
  LLock := TCriticalSection.Create;
  Result :=
    procedure(const ALine: string)
    var
      LBytes: TBytes;
    begin
      LBytes := TEncoding.UTF8.GetBytes(ALine + sLineBreak);
      LLock.Enter;
      try
        LStream.WriteBuffer(LBytes[0], Length(LBytes));
      finally
        LLock.Leave;
      end;
    end;
end;

end.
