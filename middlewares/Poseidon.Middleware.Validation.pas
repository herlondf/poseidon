unit Poseidon.Middleware.Validation;

// Middleware que intercepta excecoes de validacao e retorna RFC 7807.
//
// Uso:
//   TPoseidon.Use(TPoseidonValidationMiddleware.Handler);
//
// Quando BodyAs<T> lanca EPoseidonValidation, este middleware converte
// automaticamente para uma resposta 422 Problem Details.
// Se nao registrar este middleware, a excecao sobe normalmente.

interface

uses
  Poseidon.Callback;

type
  TPoseidonValidationMiddleware = class
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
  Poseidon.Exception;

class function TPoseidonValidationMiddleware.Handler: TPoseidonCallback;
begin
  Result := procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
  begin
    try
      Next();
    except
      on E: EPoseidonValidation do
      begin
        Res.Status(422)
           .ContentType('application/problem+json')
           .Send(
             '{"type":"about:blank",' +
             '"title":"Unprocessable Entity",' +
             '"status":422,' +
             '"detail":"' + E.Message + '"}'
           );
      end;
    end;
  end;
end;

end.
