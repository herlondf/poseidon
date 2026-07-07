unit Poseidon.Middleware.BodyLimit;

// Rejects requests whose body exceeds AMaxBytes.
// Returns 413 application/problem+json.

interface

uses
  Poseidon.Native.Types;

function BodyLimitMiddleware(AMaxBytes: Int64): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils;

function BodyLimitMiddleware(AMaxBytes: Int64): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      if Length(ACtx.RawBody) > AMaxBytes then
      begin
        ACtx.Status := 413;
        ACtx.ContentType := 'application/problem+json';
        ACtx.Body := TEncoding.UTF8.GetBytes(
          Format('{"type":"about:blank","title":"Payload Too Large",' +
            '"status":413,"detail":"Body size %d exceeds limit of %d bytes"}',
            [Length(ACtx.RawBody), AMaxBytes]));
        ACtx.Handled := True;
        Exit;
      end;
      ANext();
    end;
end;

end.
