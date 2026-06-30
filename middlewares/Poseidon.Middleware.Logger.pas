unit Poseidon.Middleware.Logger;

// Logs each request: method, path, status, elapsed time.
// Usage:
//   TPoseidon.Use(TPoseidonMiddlewareLogger.New);
//   TPoseidon.Use(TPoseidonMiddlewareLogger.New(LogToFile('app.log')));

interface

uses
  System.SysUtils,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback;

type
  TLogOutput = reference to procedure(const ALine: string);

  TPoseidonMiddlewareLogger = class
  private
    class procedure DefaultOutput(const ALine: string);
  public
    // Logs to console in text format (default)
    class function New: TPoseidonCallback; overload;

    // Custom output handler — text format
    class function New(AOutput: TLogOutput): TPoseidonCallback; overload;

    // JSON structured log — compatible with Loki / ELK / Datadog
    class function NewJSON: TPoseidonCallback; overload;
    class function NewJSON(AOutput: TLogOutput): TPoseidonCallback; overload;

    // Convenience: returns an output handler that appends to a file
    class function LogToFile(const AFileName: string): TLogOutput;
  end;

implementation

uses
  System.Classes,
  System.IOUtils,
  System.DateUtils,
  System.Diagnostics;

class procedure TPoseidonMiddlewareLogger.DefaultOutput(const ALine: string);
begin
  Writeln(ALine);
end;

class function TPoseidonMiddlewareLogger.New: TPoseidonCallback;
begin
  Result := New(DefaultOutput);
end;

class function TPoseidonMiddlewareLogger.New(AOutput: TLogOutput): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LStart: TDateTime;
      LElapsedMs: Int64;
      LLine: string;
    begin
      LStart := Now;
      Next;
      LElapsedMs := MilliSecondsBetween(Now, LStart);
      LLine := Format('[%s] %s %s %d (%dms)',
        [FormatDateTime('yyyy-mm-dd hh:nn:ss', Now),
         Req.RawWebRequest.Method,
         Req.PathInfo,
         Res.StatusCode,
         LElapsedMs]);
      AOutput(LLine);
    end;
end;

class function TPoseidonMiddlewareLogger.NewJSON: TPoseidonCallback;
begin
  Result := NewJSON(DefaultOutput);
end;

class function TPoseidonMiddlewareLogger.NewJSON(AOutput: TLogOutput): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LSW:       TStopwatch;
      LReqID:    string;
      LLine:     string;
    begin
      LSW := TStopwatch.StartNew;
      Next;
      LSW.Stop;
      LReqID := Res.RawWebResponse.CustomHeaders.Values['X-Request-ID'];
      LLine := Format(
        '{"ts":"%s","method":"%s","path":"%s","status":%d,"ms":%d,"ip":"%s","id":"%s"}',
        [FormatDateTime('yyyy-mm-dd"T"hh:nn:ss.zzz', Now),
         Req.RawWebRequest.Method,
         Req.PathInfo,
         Res.StatusCode,
         LSW.ElapsedMilliseconds,
         Req.RawWebRequest.RemoteAddr,
         LReqID]);
      AOutput(LLine);
    end;
end;

class function TPoseidonMiddlewareLogger.LogToFile(const AFileName: string): TLogOutput;
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
