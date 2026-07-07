unit Poseidon.Middleware.Validation;

// Catches EPoseidonValidation and returns RFC 7807 response (422).
//
// Usage:
//   App.Use(ValidationMiddleware);

interface

uses
  Poseidon.Native.Types;

function ValidationMiddleware: TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  Poseidon.Exception;

function ValidationMiddleware: TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      try
        ANext();
      except
        on E: EPoseidonValidation do
        begin
          ACtx.Status := 422;
          ACtx.ContentType := 'application/problem+json';
          ACtx.Body := TEncoding.UTF8.GetBytes(
            '{"type":"about:blank",' +
            '"title":"Unprocessable Entity",' +
            '"status":422,' +
            '"detail":"' + E.Message + '"}');
        end;
      end;
    end;
end;

end.
