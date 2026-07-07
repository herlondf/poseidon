unit Poseidon.Middleware.Timeout;

// Measures handler execution time. If it exceeds ATimeoutMs,
// overrides the response with 504 Gateway Timeout.
//
// Note: this is a post-execution check, not a preemptive abort.
// The handler runs to completion but the response is replaced if slow.

interface

uses
  Poseidon.Native.Types;

function TimeoutMiddleware(ATimeoutMs: Integer): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Diagnostics;

function TimeoutMiddleware(ATimeoutMs: Integer): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LSW: TStopwatch;
    begin
      LSW := TStopwatch.StartNew;
      ANext();
      LSW.Stop;

      if LSW.ElapsedMilliseconds > ATimeoutMs then
      begin
        ACtx.Status := 504;
        ACtx.ContentType := 'application/problem+json';
        ACtx.Body := TEncoding.UTF8.GetBytes(
          Format('{"type":"about:blank","title":"Gateway Timeout",' +
            '"status":504,"detail":"Request processing exceeded %d ms"}',
            [ATimeoutMs]));
      end;
    end;
end;

end.
