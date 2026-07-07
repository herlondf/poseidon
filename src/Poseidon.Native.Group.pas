unit Poseidon.Native.Group;

// Native route groups — organize endpoints under a common prefix.
//
// Usage (fluent):
//   Server.Group('/api/v1')
//     .Use(AuthMiddleware)
//     .Get('/users', HandleGetUsers)
//     .Post('/users', HandleCreateUser);
//
// Usage (block):
//   Server.GroupBlock('/api/v1',
//     procedure(G: TNativeGroup)
//     begin
//       G.Get('/users', HandleGetUsers);
//       G.Post('/users', HandleCreateUser);
//     end);

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Native.Types,
  Poseidon.Native.Router;

type
  TNativeGroup = class
  private
    FRouter: TNativeRouter;
    FPrefix: string;
    FPendingMiddlewares: TList<TNativeMiddlewareEntry>;

    function TrimPath(const APath: string): string;
    function BuildPath(const APath: string): string;
    function AddRoute(const AMethod, APath: string;
      AHandler: TNativeHandler;
      AHandlerFunc: TNativeHandlerFunc): TNativeGroup;
  public
    constructor Create(ARouter: TNativeRouter; const APrefix: string);
    destructor Destroy; override;

    function Use(AMiddleware: TNativeMiddleware): TNativeGroup; overload;
    function Use(AMiddleware: TNativeMiddlewareFunc): TNativeGroup; overload;

    function Get(const APath: string; AHandler: TNativeHandler): TNativeGroup; overload;
    function Get(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup; overload;
    function Post(const APath: string; AHandler: TNativeHandler): TNativeGroup; overload;
    function Post(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup; overload;
    function Put(const APath: string; AHandler: TNativeHandler): TNativeGroup; overload;
    function Put(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup; overload;
    function Delete(const APath: string; AHandler: TNativeHandler): TNativeGroup; overload;
    function Delete(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup; overload;
    function Patch(const APath: string; AHandler: TNativeHandler): TNativeGroup; overload;
    function Patch(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup; overload;
    function Head(const APath: string; AHandler: TNativeHandler): TNativeGroup; overload;
    function Head(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup; overload;

    property Prefix: string read FPrefix;
  end;

  TNativeGroupBlock = reference to procedure(G: TNativeGroup);

implementation

constructor TNativeGroup.Create(ARouter: TNativeRouter; const APrefix: string);
begin
  inherited Create;
  FRouter := ARouter;
  FPrefix := '/' + APrefix.Trim(['/']);
  FPendingMiddlewares := TList<TNativeMiddlewareEntry>.Create;
end;

destructor TNativeGroup.Destroy;
begin
  FPendingMiddlewares.Free;
  inherited;
end;

function TNativeGroup.TrimPath(const APath: string): string;
begin
  Result := '/' + APath.Trim(['/']);
end;

function TNativeGroup.BuildPath(const APath: string): string;
begin
  if APath = '/' then
    Result := FPrefix
  else
    Result := FPrefix + TrimPath(APath);
end;

function TNativeGroup.AddRoute(const AMethod, APath: string;
  AHandler: TNativeHandler; AHandlerFunc: TNativeHandlerFunc): TNativeGroup;
var
  LEntry: TNativeRouteEntry;
  LFull: string;
  I: Integer;
begin
  LFull := BuildPath(APath);
  LEntry.Handler := AHandler;
  LEntry.HandlerFunc := AHandlerFunc;
  LEntry.ParamNames := nil;

  SetLength(LEntry.Middlewares, FPendingMiddlewares.Count);
  for I := 0 to FPendingMiddlewares.Count - 1 do
    LEntry.Middlewares[I] := FPendingMiddlewares[I];

  FRouter.AddRoute(AMethod, LFull, LEntry);
  Result := Self;
end;

function TNativeGroup.Use(AMiddleware: TNativeMiddleware): TNativeGroup;
var
  LEntry: TNativeMiddlewareEntry;
begin
  LEntry.MethodPtr := AMiddleware;
  LEntry.FuncPtr := nil;
  LEntry.IsFunc := False;
  FPendingMiddlewares.Add(LEntry);
  Result := Self;
end;

function TNativeGroup.Use(AMiddleware: TNativeMiddlewareFunc): TNativeGroup;
var
  LEntry: TNativeMiddlewareEntry;
begin
  LEntry.MethodPtr := nil;
  LEntry.FuncPtr := AMiddleware;
  LEntry.IsFunc := True;
  FPendingMiddlewares.Add(LEntry);
  Result := Self;
end;

function TNativeGroup.Get(const APath: string; AHandler: TNativeHandler): TNativeGroup;
begin Result := AddRoute('GET', APath, AHandler, nil); end;

function TNativeGroup.Get(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup;
begin Result := AddRoute('GET', APath, nil, AHandler); end;

function TNativeGroup.Post(const APath: string; AHandler: TNativeHandler): TNativeGroup;
begin Result := AddRoute('POST', APath, AHandler, nil); end;

function TNativeGroup.Post(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup;
begin Result := AddRoute('POST', APath, nil, AHandler); end;

function TNativeGroup.Put(const APath: string; AHandler: TNativeHandler): TNativeGroup;
begin Result := AddRoute('PUT', APath, AHandler, nil); end;

function TNativeGroup.Put(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup;
begin Result := AddRoute('PUT', APath, nil, AHandler); end;

function TNativeGroup.Delete(const APath: string; AHandler: TNativeHandler): TNativeGroup;
begin Result := AddRoute('DELETE', APath, AHandler, nil); end;

function TNativeGroup.Delete(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup;
begin Result := AddRoute('DELETE', APath, nil, AHandler); end;

function TNativeGroup.Patch(const APath: string; AHandler: TNativeHandler): TNativeGroup;
begin Result := AddRoute('PATCH', APath, AHandler, nil); end;

function TNativeGroup.Patch(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup;
begin Result := AddRoute('PATCH', APath, nil, AHandler); end;

function TNativeGroup.Head(const APath: string; AHandler: TNativeHandler): TNativeGroup;
begin Result := AddRoute('HEAD', APath, AHandler, nil); end;

function TNativeGroup.Head(const APath: string; AHandler: TNativeHandlerFunc): TNativeGroup;
begin Result := AddRoute('HEAD', APath, nil, AHandler); end;

end.
