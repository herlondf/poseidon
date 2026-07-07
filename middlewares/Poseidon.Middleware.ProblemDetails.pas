unit Poseidon.Middleware.ProblemDetails;

// Converts exceptions to RFC 7807 Problem Details responses.
//
// Usage:
//   App.Use(ProblemDetailsMiddleware);

interface

uses
  Poseidon.Native.Types;

function ProblemDetailsMiddleware: TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.JSON,
  Poseidon.Exception,
  Poseidon.Problem;

function ProblemDetailsMiddleware: TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LProblem: TProblemDetail;
      LJson: TJSONObject;
    begin
      try
        ANext();
      except
        on E: EPoseidonException do
        begin
          LProblem := TProblemDetail.FromException(E, ACtx.Path);
          LJson := LProblem.ToJSON;
          try
            ACtx.Status := LProblem.Status;
            ACtx.ContentType := 'application/problem+json';
            ACtx.Body := TEncoding.UTF8.GetBytes(LJson.ToJSON);
          finally
            LJson.Free;
          end;
        end;
        on E: Exception do
        begin
          LProblem.TypeURI := 'about:blank';
          LProblem.Title := 'Internal Server Error';
          LProblem.Status := 500;
          LProblem.Detail := E.Message;
          LProblem.Instance := ACtx.Path;
          LJson := LProblem.ToJSON;
          try
            ACtx.Status := 500;
            ACtx.ContentType := 'application/problem+json';
            ACtx.Body := TEncoding.UTF8.GetBytes(LJson.ToJSON);
          finally
            LJson.Free;
          end;
        end;
      end;
    end;
end;

end.
