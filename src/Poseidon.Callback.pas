unit Poseidon.Callback;

interface

uses
  System.Generics.Collections,
  Web.HTTPApp,
  Poseidon.Proc,
  Poseidon.Commons,
  Poseidon.Request,
  Poseidon.Response;

type
  TPoseidonCallback    = reference to procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc);
  TPoseidonCallbackReqRes = reference to procedure(Req: TPoseidonRequest; Res: TPoseidonResponse);
  TPoseidonCallbackReq    = reference to procedure(Req: TPoseidonRequest);

  TCallNextPath = reference to function(const ASegs: TArray<string>; AIdx: Integer;
    const AMethod: TMethodType;
    const ARequest: TPoseidonRequest; const AResponse: TPoseidonResponse): Boolean;

implementation

end.
