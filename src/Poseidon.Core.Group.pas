unit Poseidon.Core.Group;

// Route groups allow organizing endpoints under a common prefix with shared middlewares.
//
// Usage (fluent):
//   TPoseidon.Group('/api/v1')
//     .Use(AuthMiddleware)
//     .Get('/users', handleGetUsers)
//     .Post('/users', handleCreateUser);
//
// Usage (block — cleaner for large groups):
//   TPoseidon.GroupBlock('/api/v1',
//     procedure(G: TPoseidonGroup)
//     begin
//       G.Get('/users', handleGetUsers);
//       G.Post('/users', handleCreateUser);
//     end);

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Web.HTTPApp,
  Poseidon.Proc,
  Poseidon.Commons,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback,
  Poseidon.Core.RouterTree,
  Poseidon.Core.Registry;

type
  TPoseidonGroup = class
  private
    FRouter: TPoseidonRouterTree;
    FPrefix: string;
    FPendingMiddlewares: TList<TPoseidonCallback>;

    function TrimPath(const APath: string): string;
    function BuildPath(const APath: string): string;
    procedure FlushMiddlewares(AMethod: TMethodType; const APath: string);
    function RegisterRoute(AMethod: TMethodType; const APath: string;
      ACallback: TPoseidonCallback): TPoseidonGroup;
  public
    constructor Create(ARouter: TPoseidonRouterTree; const APrefix: string);
    destructor Destroy; override;

    // Add a middleware scoped to this group (applied to next registered route)
    function Use(ACallback: TPoseidonCallback): TPoseidonGroup; overload;
    function Use(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup; overload;

    function Get(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup; overload;
    function Get(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup; overload;
    function Get(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup; overload;

    function Post(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup; overload;
    function Post(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup; overload;
    function Post(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup; overload;

    function Put(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup; overload;
    function Put(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup; overload;
    function Put(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup; overload;

    function Delete(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup; overload;
    function Delete(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup; overload;
    function Delete(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup; overload;

    function Patch(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup; overload;
    function Patch(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup; overload;
    function Patch(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup; overload;

    function Head(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;

    property Prefix: string read FPrefix;
  end;

  TPoseidonGroupBlock = reference to procedure(G: TPoseidonGroup);

implementation

constructor TPoseidonGroup.Create(ARouter: TPoseidonRouterTree; const APrefix: string);
begin
  FRouter := ARouter;
  FPrefix := '/' + APrefix.Trim(['/']);
  FPendingMiddlewares := TList<TPoseidonCallback>.Create;
end;

destructor TPoseidonGroup.Destroy;
begin
  FPendingMiddlewares.Free;
  inherited;
end;

function TPoseidonGroup.TrimPath(const APath: string): string;
begin
  Result := '/' + APath.Trim(['/']);
end;

function TPoseidonGroup.BuildPath(const APath: string): string;
begin
  if APath = '/' then
    Result := FPrefix
  else
    Result := FPrefix + TrimPath(APath);
end;

procedure TPoseidonGroup.FlushMiddlewares(AMethod: TMethodType; const APath: string);
var
  LCb: TPoseidonCallback;
begin
  for LCb in FPendingMiddlewares do
    FRouter.RegisterRoute(AMethod, APath, LCb);
  FPendingMiddlewares.Clear;
end;

function TPoseidonGroup.RegisterRoute(AMethod: TMethodType; const APath: string;
  ACallback: TPoseidonCallback): TPoseidonGroup;
var
  LFull: string;
begin
  LFull := BuildPath(APath);
  FlushMiddlewares(AMethod, LFull);
  FRouter.RegisterRoute(AMethod, LFull, ACallback);
  TPoseidonRouteRegistry.Register(AMethod, LFull);
  Result := Self;
end;

function TPoseidonGroup.Use(ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  FPendingMiddlewares.Add(ACallback);
  Result := Self;
end;

function TPoseidonGroup.Use(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  FRouter.RegisterMiddleware(BuildPath(APath), ACallback);
  Result := Self;
end;

{ GET }

function TPoseidonGroup.Get(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  Result := RegisterRoute(mtGet, APath, ACallback);
end;

function TPoseidonGroup.Get(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup;
begin
  Result := Get(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req, Res); end);
end;

function TPoseidonGroup.Get(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup;
begin
  Result := Get(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req); end);
end;

{ POST }

function TPoseidonGroup.Post(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  Result := RegisterRoute(mtPost, APath, ACallback);
end;

function TPoseidonGroup.Post(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup;
begin
  Result := Post(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req, Res); end);
end;

function TPoseidonGroup.Post(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup;
begin
  Result := Post(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req); end);
end;

{ PUT }

function TPoseidonGroup.Put(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  Result := RegisterRoute(mtPut, APath, ACallback);
end;

function TPoseidonGroup.Put(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup;
begin
  Result := Put(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req, Res); end);
end;

function TPoseidonGroup.Put(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup;
begin
  Result := Put(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req); end);
end;

{ DELETE }

function TPoseidonGroup.Delete(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  Result := RegisterRoute(mtDelete, APath, ACallback);
end;

function TPoseidonGroup.Delete(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup;
begin
  Result := Delete(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req, Res); end);
end;

function TPoseidonGroup.Delete(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup;
begin
  Result := Delete(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req); end);
end;

{ PATCH }

function TPoseidonGroup.Patch(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  Result := RegisterRoute(mtPatch, APath, ACallback);
end;

function TPoseidonGroup.Patch(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonGroup;
begin
  Result := Patch(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req, Res); end);
end;

function TPoseidonGroup.Patch(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonGroup;
begin
  Result := Patch(APath,
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin ACallback(Req); end);
end;

{ HEAD }

function TPoseidonGroup.Head(const APath: string; ACallback: TPoseidonCallback): TPoseidonGroup;
begin
  Result := RegisterRoute(mtHead, APath, ACallback);
end;

end.
