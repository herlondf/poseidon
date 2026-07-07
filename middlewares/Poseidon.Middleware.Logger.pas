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
  System.Diagnostics;

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
      AOutput(Format(
        '{"ts":"%s","method":"%s","path":"%s","status":%d,"ms":%d,"ip":"%s","id":"%s"}',
        [FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now),
         ACtx.Method, ACtx.Path, ACtx.Status,
         LSW.ElapsedMilliseconds, ACtx.RemoteAddr, LReqID]));
    end;
end;

function LogToFile(const AFileName: string): TLogOutput;
begin
  Result :=
    procedure(const ALine: string)
    var
      LFile: TStreamWriter;
    begin
      LFile := TStreamWriter.Create(AFileName, True, TEncoding.UTF8);
      try
        LFile.WriteLine(ALine);
      finally
        LFile.Free;
      end;
    end;
end;

end.
