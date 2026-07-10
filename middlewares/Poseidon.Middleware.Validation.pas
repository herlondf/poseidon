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
  System.JSON,
  Poseidon.Exception;

function ValidationMiddleware: TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LObj: TJSONObject;
    begin
      try
        ANext();
      except
        on E: EPoseidonValidation do
        begin
          ACtx.Status := 422;
          ACtx.ContentType := 'application/problem+json';
          // Build via TJSONObject so E.Message is escaped (no JSON injection).
          LObj := TJSONObject.Create;
          try
            LObj.AddPair('type', 'about:blank');
            LObj.AddPair('title', 'Unprocessable Entity');
            LObj.AddPair('status', TJSONNumber.Create(422));
            LObj.AddPair('detail', E.Message);
            ACtx.Body := TEncoding.UTF8.GetBytes(LObj.ToJSON);
          finally
            LObj.Free;
          end;
        end;
      end;
    end;
end;

end.
