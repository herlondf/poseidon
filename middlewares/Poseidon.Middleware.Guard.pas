unit Poseidon.Middleware.Guard;

// Middleware de protecao de requests: method whitelist, path traversal,
// request smuggling detection.
//
// Uso:
//   TPoseidon.Use(TPoseidonGuardMiddleware.Handler);
//   TPoseidon.Use(TPoseidonGuardMiddleware.Handler(['GET', 'POST']));
//
// Verifica antes de chegar ao handler:
//   - Path traversal (../, %2e%2e, backslash, NUL)
//   - Request smuggling (Content-Length + Transfer-Encoding)
//   - Method whitelist (se configurado)

interface

uses
  Poseidon.Callback;

type
  TPoseidonGuardMiddleware = class
  public
    class function Handler: TPoseidonCallback; overload;
    class function Handler(const AAllowedMethods: TArray<string>): TPoseidonCallback; overload;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Proc,
  Poseidon.Net.Security;

class function TPoseidonGuardMiddleware.Handler: TPoseidonCallback;
begin
  Result := Handler([]);
end;

class function TPoseidonGuardMiddleware.Handler(const AAllowedMethods: TArray<string>): TPoseidonCallback;
var
  LMethods: TArray<string>;
begin
  LMethods := AAllowedMethods;
  Result := procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
  var
    LMethod, LTE: string;
    LHasCL: Boolean;
  begin
    // Method whitelist
    if Length(LMethods) > 0 then
    begin
      LMethod := Req.RawWebRequest.Method;
      if not IsMethodAllowed(LMethod, LMethods) then
      begin
        Res.Status(405).Send('Method Not Allowed');
        Exit;
      end;
    end;

    // Path traversal
    if not IsPathSafe(Req.PathInfo) then
    begin
      Res.Status(400).Send('Bad Request');
      Exit;
    end;

    // Request smuggling
    LHasCL := Req.RawWebRequest.GetFieldByName('Content-Length') <> '';
    LTE := LowerCase(Req.RawWebRequest.GetFieldByName('Transfer-Encoding'));
    if HasRequestSmuggling(LHasCL, Pos('chunked', LTE) > 0) then
    begin
      Res.Status(400).Send('Bad Request');
      Exit;
    end;

    Next();
  end;
end;

end.
