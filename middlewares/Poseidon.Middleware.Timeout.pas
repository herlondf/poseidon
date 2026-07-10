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

// #192: the timeout replaces the body, so content headers an inner middleware
// added for the ORIGINAL body (Content-Encoding, Content-Length, ETag) are now
// stale — e.g. a leftover 'Content-Encoding: gzip' makes the client try to
// gunzip plain JSON. Strip only those; keep everything else (CORS, security...).
procedure StripStaleContentHeaders(var ACtx: TNativeRequestContext);
var
  I, LDst: Integer;
  LName: string;
begin
  LDst := 0;
  for I := 0 to High(ACtx.ExtraHeaders) do
  begin
    LName := ACtx.ExtraHeaders[I].Key;
    if SameText(LName, 'Content-Encoding') or
       SameText(LName, 'Content-Length') or
       SameText(LName, 'ETag') then
      Continue;
    ACtx.ExtraHeaders[LDst] := ACtx.ExtraHeaders[I];
    Inc(LDst);
  end;
  SetLength(ACtx.ExtraHeaders, LDst);
end;

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
        StripStaleContentHeaders(ACtx);
        ACtx.Handled := True;
      end;
    end;
end;

end.
