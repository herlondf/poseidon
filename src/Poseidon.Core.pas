unit Poseidon.Core;

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
  Poseidon.Core.Registry,
  Poseidon.Core.Group;

type
  TPoseidonCore = class
  private
    class var FRoutes: TPoseidonRouterTree;
    class var FPendingCallbacks: TList<TPoseidonCallback>;
    class var FInstance: TPoseidonCore;

    class function GetInstance: TPoseidonCore;
    class function GetRoutes: TPoseidonRouterTree; static;
    class function TrimPath(const APath: string): string;
    class function WrapReqRes(ACallback: TPoseidonCallbackReqRes): TPoseidonCallback;
    class function WrapReq(ACallback: TPoseidonCallbackReq): TPoseidonCallback;
    class function FlushPending(AMethod: TMethodType; const APath: string): TPoseidonCore;
    class function RegisterRoute(AMethod: TMethodType; const APath: string;
      ACallback: TPoseidonCallback): TPoseidonCore;
  public
    constructor Create; virtual;
    class destructor UnInitialize;

    // Register a middleware applied to all subsequent routes
    class function Use(ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function Use(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function Use(ACallbacks: array of TPoseidonCallback): TPoseidonCore; overload;

    // HTTP method handlers
    class function Get(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function Get(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore; overload;
    class function Get(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore; overload;

    class function Post(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function Post(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore; overload;
    class function Post(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore; overload;

    class function Put(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function Put(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore; overload;
    class function Put(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore; overload;

    class function Delete(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function Delete(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore; overload;
    class function Delete(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore; overload;

    class function Patch(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function Patch(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore; overload;
    class function Patch(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore; overload;

    class function Head(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;

    class function All(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore; overload;
    class function All(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore; overload;

    // Create a route group with a common prefix (fluent — caller must free)
    class function Group(const APrefix: string): TPoseidonGroup;

    // Create a route group using a block — group is freed automatically
    class procedure GroupBlock(const APrefix: string; ABlock: TPoseidonGroupBlock);

    class property Routes: TPoseidonRouterTree read GetRoutes;
    class function GetSingleton: TPoseidonCore;
    class function Version: string;
  end;

implementation

const
  PEGASUS_VERSION = '0.1.0';

{ TPoseidonCore }

constructor TPoseidonCore.Create;
begin
  if FInstance <> nil then
    raise Exception.Create('TPoseidonCore instance already exists');
  if FRoutes = nil then
    FRoutes := TPoseidonRouterTree.Create;
  FInstance := Self;
end;

class destructor TPoseidonCore.UnInitialize;
begin
  FreeAndNil(FInstance);
  FreeAndNil(FRoutes);
  FreeAndNil(FPendingCallbacks);
end;

class function TPoseidonCore.GetInstance: TPoseidonCore;
begin
  if FInstance = nil then
    FInstance := TPoseidonCore.Create;
  Result := FInstance;
end;

class function TPoseidonCore.GetSingleton: TPoseidonCore;
begin
  Result := GetInstance;
end;

class function TPoseidonCore.GetRoutes: TPoseidonRouterTree;
begin
  GetInstance; // ensures FRoutes is initialized
  Result := FRoutes;
end;

class function TPoseidonCore.TrimPath(const APath: string): string;
begin
  Result := '/' + APath.Trim(['/']);
end;

class function TPoseidonCore.Version: string;
begin
  Result := PEGASUS_VERSION;
end;

class function TPoseidonCore.WrapReqRes(ACallback: TPoseidonCallbackReqRes): TPoseidonCallback;
begin
  Result := procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      ACallback(Req, Res);
    end;
end;

class function TPoseidonCore.WrapReq(ACallback: TPoseidonCallbackReq): TPoseidonCallback;
begin
  Result := procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      ACallback(Req);
    end;
end;

class function TPoseidonCore.FlushPending(AMethod: TMethodType; const APath: string): TPoseidonCore;
var
  LCb: TPoseidonCallback;
begin
  Result := GetInstance;
  if FPendingCallbacks = nil then
    Exit;
  for LCb in FPendingCallbacks do
    FRoutes.RegisterRoute(AMethod, TrimPath(APath), LCb);
  FPendingCallbacks.Clear;
end;

class function TPoseidonCore.RegisterRoute(AMethod: TMethodType; const APath: string;
  ACallback: TPoseidonCallback): TPoseidonCore;
var
  LTrimmed: string;
begin
  LTrimmed := TrimPath(APath);
  FlushPending(AMethod, LTrimmed);
  FRoutes.RegisterRoute(AMethod, LTrimmed, ACallback);
  TPoseidonRouteRegistry.Register(AMethod, LTrimmed);
  Result := GetInstance;
end;

{ Use }

class function TPoseidonCore.Use(ACallback: TPoseidonCallback): TPoseidonCore;
begin
  GetInstance;
  FRoutes.RegisterMiddleware('/', ACallback);
  Result := FInstance;
end;

class function TPoseidonCore.Use(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
begin
  GetInstance;
  FRoutes.RegisterMiddleware(TrimPath(APath), ACallback);
  Result := FInstance;
end;

class function TPoseidonCore.Use(ACallbacks: array of TPoseidonCallback): TPoseidonCore;
var
  LCb: TPoseidonCallback;
begin
  for LCb in ACallbacks do
    Use(LCb);
  Result := GetInstance;
end;

{ GET }

class function TPoseidonCore.Get(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
begin
  Result := RegisterRoute(mtGet, APath, ACallback);
end;

class function TPoseidonCore.Get(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore;
begin
  Result := Get(APath, WrapReqRes(ACallback));
end;

class function TPoseidonCore.Get(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore;
begin
  Result := Get(APath, WrapReq(ACallback));
end;

{ POST }

class function TPoseidonCore.Post(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
begin
  Result := RegisterRoute(mtPost, APath, ACallback);
end;

class function TPoseidonCore.Post(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore;
begin
  Result := Post(APath, WrapReqRes(ACallback));
end;

class function TPoseidonCore.Post(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore;
begin
  Result := Post(APath, WrapReq(ACallback));
end;

{ PUT }

class function TPoseidonCore.Put(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
begin
  Result := RegisterRoute(mtPut, APath, ACallback);
end;

class function TPoseidonCore.Put(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore;
begin
  Result := Put(APath, WrapReqRes(ACallback));
end;

class function TPoseidonCore.Put(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore;
begin
  Result := Put(APath, WrapReq(ACallback));
end;

{ DELETE }

class function TPoseidonCore.Delete(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
begin
  Result := RegisterRoute(mtDelete, APath, ACallback);
end;

class function TPoseidonCore.Delete(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore;
begin
  Result := Delete(APath, WrapReqRes(ACallback));
end;

class function TPoseidonCore.Delete(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore;
begin
  Result := Delete(APath, WrapReq(ACallback));
end;

{ PATCH }

class function TPoseidonCore.Patch(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
begin
  Result := RegisterRoute(mtPatch, APath, ACallback);
end;

class function TPoseidonCore.Patch(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore;
begin
  Result := Patch(APath, WrapReqRes(ACallback));
end;

class function TPoseidonCore.Patch(const APath: string; ACallback: TPoseidonCallbackReq): TPoseidonCore;
begin
  Result := Patch(APath, WrapReq(ACallback));
end;

{ HEAD }

class function TPoseidonCore.Head(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
begin
  Result := RegisterRoute(mtHead, APath, ACallback);
end;

{ ALL }

class function TPoseidonCore.All(const APath: string; ACallback: TPoseidonCallback): TPoseidonCore;
var
  LMethod: TMethodType;
begin
  for LMethod := Low(TMethodType) to High(TMethodType) do
    RegisterRoute(LMethod, APath, ACallback);
  Result := GetInstance;
end;

class function TPoseidonCore.All(const APath: string; ACallback: TPoseidonCallbackReqRes): TPoseidonCore;
begin
  Result := All(APath, WrapReqRes(ACallback));
end;

class function TPoseidonCore.Group(const APrefix: string): TPoseidonGroup;
begin
  Result := TPoseidonGroup.Create(GetRoutes, APrefix);
end;

class procedure TPoseidonCore.GroupBlock(const APrefix: string; ABlock: TPoseidonGroupBlock);
var
  LGroup: TPoseidonGroup;
begin
  LGroup := TPoseidonGroup.Create(GetRoutes, APrefix);
  try
    ABlock(LGroup);
  finally
    LGroup.Free;
  end;
end;

end.
