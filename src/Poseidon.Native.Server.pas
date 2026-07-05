unit Poseidon.Native.Server;

// #94: TPoseidonServer — instance-based native API.
//
// Zero-copy hot path: TNativeRequestContext is stack-allocated,
// no WebBroker objects, no pool round-trips, no per-request closures.
//
// Usage:
//   Server := TPoseidonServer.Create;
//   Server.Get('/ping', MyController.HandlePing);
//   Server.Listen(9000);

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Poseidon.Native.Types,
  Poseidon.Native.Router,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer;

type
  TPoseidonServer = class
  private
    FServer: TPoseidonNativeServer;
    FRouter: TNativeRouter;
    FRunning: Boolean;
    FShutdownEvent: TEvent;

    procedure HandleRequest(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtraHeaders: TArray<TPair<string,string>>);

    procedure ExecuteChain(var ACtx: TNativeRequestContext;
      const AMiddlewares: TArray<TNativeMiddlewareEntry>;
      const AGlobalMiddlewares: TArray<TNativeMiddlewareEntry>;
      ARoute: PNativeRouteEntry);

    function AddRoute(const AMethod, APath: string;
      AHandler: TNativeHandler; AHandlerFunc: TNativeHandlerFunc): TPoseidonServer;
  public
    constructor Create;
    destructor Destroy; override;

    // --- Route registration (fluent API) ---
    function Get(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;
    function Get(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;
    function Post(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;
    function Post(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;
    function Put(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;
    function Put(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;
    function Delete(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;
    function Delete(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;
    function Patch(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;
    function Patch(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;

    // --- Global middleware ---
    function Use(AMiddleware: TNativeMiddleware): TPoseidonServer; overload;
    function Use(AMiddleware: TNativeMiddlewareFunc): TPoseidonServer; overload;

    // --- Lifecycle ---
    procedure Listen(APort: Integer; const AHost: string = '0.0.0.0';
      AOnListen: TProc = nil);
    procedure Stop;

    // --- Config (delegates to TPoseidonNativeServer) ---
    procedure EnableSyncDispatch;
    procedure ConfigureSSL(const ACertFile, AKeyFile: string);

    property Server: TPoseidonNativeServer read FServer;
    property Running: Boolean read FRunning;
  end;

implementation

var
  GNotFoundBody: TBytes;

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TPoseidonServer.Create;
begin
  inherited Create;
  FServer := TPoseidonNativeServer.Create;
  FRouter := TNativeRouter.Create;
  FRunning := False;
  FShutdownEvent := TEvent.Create(nil, True, False, '');
end;

destructor TPoseidonServer.Destroy;
begin
  if FRunning then
    try Stop except end;
  FreeAndNil(FShutdownEvent);
  FreeAndNil(FRouter);
  FreeAndNil(FServer);
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Route registration
// ---------------------------------------------------------------------------

function TPoseidonServer.AddRoute(const AMethod, APath: string;
  AHandler: TNativeHandler; AHandlerFunc: TNativeHandlerFunc): TPoseidonServer;
var
  LEntry: TNativeRouteEntry;
begin
  LEntry.Handler := AHandler;
  LEntry.HandlerFunc := AHandlerFunc;
  LEntry.Middlewares := nil;
  LEntry.ParamNames := nil;
  FRouter.AddRoute(AMethod, APath, LEntry);
  Result := Self;
end;

function TPoseidonServer.Get(const APath: string; AHandler: TNativeHandler): TPoseidonServer;
begin Result := AddRoute('GET', APath, AHandler, nil); end;

function TPoseidonServer.Get(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer;
begin Result := AddRoute('GET', APath, nil, AHandler); end;

function TPoseidonServer.Post(const APath: string; AHandler: TNativeHandler): TPoseidonServer;
begin Result := AddRoute('POST', APath, AHandler, nil); end;

function TPoseidonServer.Post(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer;
begin Result := AddRoute('POST', APath, nil, AHandler); end;

function TPoseidonServer.Put(const APath: string; AHandler: TNativeHandler): TPoseidonServer;
begin Result := AddRoute('PUT', APath, AHandler, nil); end;

function TPoseidonServer.Put(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer;
begin Result := AddRoute('PUT', APath, nil, AHandler); end;

function TPoseidonServer.Delete(const APath: string; AHandler: TNativeHandler): TPoseidonServer;
begin Result := AddRoute('DELETE', APath, AHandler, nil); end;

function TPoseidonServer.Delete(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer;
begin Result := AddRoute('DELETE', APath, nil, AHandler); end;

function TPoseidonServer.Patch(const APath: string; AHandler: TNativeHandler): TPoseidonServer;
begin Result := AddRoute('PATCH', APath, AHandler, nil); end;

function TPoseidonServer.Patch(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer;
begin Result := AddRoute('PATCH', APath, nil, AHandler); end;

// ---------------------------------------------------------------------------
// Global middleware
// ---------------------------------------------------------------------------

function TPoseidonServer.Use(AMiddleware: TNativeMiddleware): TPoseidonServer;
var
  LEntry: TNativeMiddlewareEntry;
begin
  LEntry.MethodPtr := AMiddleware;
  LEntry.FuncPtr := nil;
  LEntry.IsFunc := False;
  FRouter.AddGlobalMiddleware(LEntry);
  Result := Self;
end;

function TPoseidonServer.Use(AMiddleware: TNativeMiddlewareFunc): TPoseidonServer;
var
  LEntry: TNativeMiddlewareEntry;
begin
  LEntry.MethodPtr := nil;
  LEntry.FuncPtr := AMiddleware;
  LEntry.IsFunc := True;
  FRouter.AddGlobalMiddleware(LEntry);
  Result := Self;
end;

// ---------------------------------------------------------------------------
// Request handling — zero-copy hot path
// ---------------------------------------------------------------------------

procedure TPoseidonServer.HandleRequest(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TArray<TPair<string,string>>);
var
  LCtx: TNativeRequestContext;
  LRoute: PNativeRouteEntry;
begin
  LCtx.Method := AReq.Method;
  LCtx.Path := AReq.Path;
  LCtx.QueryString := AReq.QueryString;
  LCtx.RemoteAddr := AReq.RemoteAddr;
  LCtx.RawBody := AReq.RawBody;
  LCtx.KeepAlive := AReq.KeepAlive;
  LCtx.Headers := AReq.Headers;
  LCtx.Params := nil;
  LCtx.Status := 200;
  LCtx.ContentType := '';
  LCtx.Body := nil;
  LCtx.ExtraHeaders := nil;
  LCtx.Handled := False;

  LRoute := FRouter.Lookup(AReq.Method, AReq.Path, LCtx);
  if LRoute = nil then
  begin
    AStatus := 404;
    AContentType := 'application/json';
    ABody := GNotFoundBody;
    AExtraHeaders := nil;
    Exit;
  end;

  ExecuteChain(LCtx, LRoute^.Middlewares, FRouter.GlobalMiddlewares, LRoute);

  AStatus := LCtx.Status;
  AContentType := LCtx.ContentType;
  ABody := LCtx.Body;
  AExtraHeaders := LCtx.ExtraHeaders;
end;

// ---------------------------------------------------------------------------
// Middleware chain executor with Next() support
// ---------------------------------------------------------------------------

threadvar
  GChainCtx: Pointer;
  GChainRoute: Pointer;
  GChainGlobal: Pointer;
  GChainLocal: Pointer;
  GChainIdx: Integer;
  GChainGlobalN: Integer;
  GChainLocalN: Integer;

procedure _ChainNext; forward;

procedure _ChainStep;
var
  LIdx: Integer;
  LGlobal: TArray<TNativeMiddlewareEntry>;
  LLocal: TArray<TNativeMiddlewareEntry>;
  LRoute: PNativeRouteEntry;
  LCtx: PNativeRequestContext;
  LEntry: TNativeMiddlewareEntry;
begin
  LIdx := GChainIdx;
  LCtx := PNativeRequestContext(GChainCtx);
  LRoute := PNativeRouteEntry(GChainRoute);

  if LCtx^.Handled then Exit;

  if LIdx < GChainGlobalN then
  begin
    LGlobal := TArray<TNativeMiddlewareEntry>(GChainGlobal);
    LEntry  := LGlobal[LIdx];
    Inc(GChainIdx);
    if LEntry.IsFunc then
      LEntry.FuncPtr(LCtx^, _ChainNext)
    else
      LEntry.MethodPtr(LCtx^, _ChainNext);
  end
  else if LIdx < GChainGlobalN + GChainLocalN then
  begin
    LLocal := TArray<TNativeMiddlewareEntry>(GChainLocal);
    LEntry := LLocal[LIdx - GChainGlobalN];
    Inc(GChainIdx);
    if LEntry.IsFunc then
      LEntry.FuncPtr(LCtx^, _ChainNext)
    else
      LEntry.MethodPtr(LCtx^, _ChainNext);
  end
  else
  begin
    if Assigned(LRoute^.Handler) then
      LRoute^.Handler(LCtx^)
    else if Assigned(LRoute^.HandlerFunc) then
      LRoute^.HandlerFunc(LCtx^);
  end;
end;

procedure _ChainNext;
begin
  _ChainStep;
end;

procedure TPoseidonServer.ExecuteChain(var ACtx: TNativeRequestContext;
  const AMiddlewares: TArray<TNativeMiddlewareEntry>;
  const AGlobalMiddlewares: TArray<TNativeMiddlewareEntry>;
  ARoute: PNativeRouteEntry);
var
  LSaveCtx, LSaveRoute, LSaveGlobal, LSaveLocal: Pointer;
  LSaveIdx, LSaveGN, LSaveLN: Integer;
begin
  // Save threadvar state — reentrant for nested dispatches
  LSaveCtx := GChainCtx;
  LSaveRoute := GChainRoute;
  LSaveGlobal := GChainGlobal;
  LSaveLocal := GChainLocal;
  LSaveIdx := GChainIdx;
  LSaveGN := GChainGlobalN;
  LSaveLN := GChainLocalN;

  GChainCtx := @ACtx;
  GChainRoute := ARoute;
  GChainGlobal := Pointer(AGlobalMiddlewares);
  GChainLocal := Pointer(AMiddlewares);
  GChainIdx := 0;
  GChainGlobalN := Length(AGlobalMiddlewares);
  GChainLocalN := Length(AMiddlewares);

  try
    _ChainStep;
  finally
    GChainCtx := LSaveCtx;
    GChainRoute := LSaveRoute;
    GChainGlobal := LSaveGlobal;
    GChainLocal := LSaveLocal;
    GChainIdx := LSaveIdx;
    GChainGlobalN := LSaveGN;
    GChainLocalN := LSaveLN;
  end;
end;

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

procedure TPoseidonServer.Listen(APort: Integer; const AHost: string;
  AOnListen: TProc);
begin
  if FRunning then
    raise Exception.Create('TPoseidonServer: already listening');

  FRunning := True;
  FShutdownEvent.ResetEvent;

  FServer.Listen(AHost, APort,
    procedure(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtraHeaders: TArray<TPair<string,string>>)
    begin
      HandleRequest(AReq, AStatus, AContentType, ABody, AExtraHeaders);
    end,
    procedure
    begin
      if Assigned(AOnListen) then
        AOnListen();
    end);

  if IsConsole then
    FShutdownEvent.WaitFor;
end;

procedure TPoseidonServer.Stop;
begin
  if not FRunning then Exit;
  FRunning := False;
  FServer.Stop;
  FShutdownEvent.SetEvent;
end;

// ---------------------------------------------------------------------------
// Config delegates
// ---------------------------------------------------------------------------

procedure TPoseidonServer.EnableSyncDispatch;
begin
  FServer.SyncDispatch := True;
end;

procedure TPoseidonServer.ConfigureSSL(const ACertFile, AKeyFile: string);
begin
  FServer.ConfigureSSL(ACertFile, AKeyFile);
end;

initialization
  GNotFoundBody := TEncoding.UTF8.GetBytes(
    '{"type":"about:blank","title":"Not Found","status":404}');

end.
