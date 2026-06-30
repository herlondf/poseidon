unit Poseidon.Middleware.CORS;

// Usage:
//   TPoseidon.Use(TPoseidonMiddlewareCORS.New);
//   TPoseidon.Use(TPoseidonMiddlewareCORS.New('https://myapp.com', 'GET,POST,PUT,DELETE'));

interface

uses
  Web.HTTPApp,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback;

type
  TPoseidonMiddlewareCORS = class
  public
    class function New(
      const AAllowOrigin: string = '*';
      const AAllowMethods: string = 'GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS';
      const AAllowHeaders: string = 'Content-Type, Authorization, Accept'
    ): TPoseidonCallback;
  end;

implementation

class function TPoseidonMiddlewareCORS.New(const AAllowOrigin, AAllowMethods, AAllowHeaders: string): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      Res.Header('Access-Control-Allow-Origin', AAllowOrigin)
         .Header('Access-Control-Allow-Methods', AAllowMethods)
         .Header('Access-Control-Allow-Headers', AAllowHeaders)
         .Header('Access-Control-Max-Age', '86400');

      // Preflight — respond immediately with 204
      // TMethodType has no mtOptions in Delphi 11; HTTP spec mandates uppercase
      if Req.RawWebRequest.Method = 'OPTIONS' then
        Res.Status(204).Send('')
      else
        Next;
    end;
end;

end.
