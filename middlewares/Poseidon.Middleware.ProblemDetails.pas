unit Poseidon.Middleware.ProblemDetails;

// Middleware que converte excecoes em respostas RFC 7807 Problem Details.
//
// Uso:
//   TPoseidon.Use(TPoseidonProblemDetailsMiddleware.Handler);
//
// Captura EPoseidonException e Exception generica, converte para JSON
// no formato Problem Details com type, title, status, detail.

interface

uses
  Poseidon.Callback;

type
  TPoseidonProblemDetailsMiddleware = class
  public
    class function Handler: TPoseidonCallback;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Proc,
  Poseidon.Exception,
  Poseidon.Problem;

class function TPoseidonProblemDetailsMiddleware.Handler: TPoseidonCallback;
begin
  Result := procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
  var
    LProblem: TProblemDetail;
    LJson: TJSONObject;
  begin
    try
      Next();
    except
      on E: EPoseidonException do
      begin
        LProblem := TProblemDetail.FromException(E, Req.PathInfo);
        LJson := LProblem.ToJSON;
        try
          Res.Status(LProblem.Status)
             .ContentType('application/problem+json')
             .Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      end;
      on E: Exception do
      begin
        LProblem.TypeURI  := 'about:blank';
        LProblem.Title    := 'Internal Server Error';
        LProblem.Status   := 500;
        LProblem.Detail   := E.Message;
        LProblem.Instance := Req.PathInfo;
        LJson := LProblem.ToJSON;
        try
          Res.Status(500)
             .ContentType('application/problem+json')
             .Send(LJson.ToJSON);
        finally
          LJson.Free;
        end;
      end;
    end;
  end;
end;

end.
