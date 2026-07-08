unit Poseidon.Native.Server;

// TPoseidonServer — instance-based native API.
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
  Poseidon.Native.Group,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer,
  Poseidon.Net.WebSocket;

type
  TPoseidonServer = class
  private
    FServer: TPoseidonNativeServer;
    FRouter: TNativeRouter;
    FGroups: TObjectList<TNativeGroup>;
    FRunning: Boolean;
    FShutdownEvent: TEvent;
    FPIDFile: string;

    procedure HandleRequest(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtraHeaders: TArray<TPair<string,string>>);

    procedure ExecuteChain(var ACtx: TNativeRequestContext;
      const AMiddlewares: TArray<TNativeMiddlewareEntry>;
      const AGlobalMiddlewares: TArray<TNativeMiddlewareEntry>;
      ARoute: PNativeRouteEntry);

    function AddRoute(const AMethod, APath: string;
      AHandler: TNativeHandler; AHandlerFunc: TNativeHandlerFunc): TPoseidonServer;

    function GetMaxConnections: Integer;
    procedure SetMaxConnections(AValue: Integer);
    function GetMaxConnectionsPerIP: Integer;
    procedure SetMaxConnectionsPerIP(AValue: Integer);
    function GetOnLog: TOnPoseidonLog;
    procedure SetOnLog(AValue: TOnPoseidonLog);
    function GetOnRequestLog: TOnPoseidonRequestLog;
    procedure SetOnRequestLog(AValue: TOnPoseidonRequestLog);
    function GetWorkerCount: Integer;
    procedure SetWorkerCount(AValue: Integer);
    function GetMinWorkerCount: Integer;
    procedure SetMinWorkerCount(AValue: Integer);
    function GetIdleTimeoutMs: Integer;
    procedure SetIdleTimeoutMs(AValue: Integer);
    function GetMaxRequestSize: Integer;
    procedure SetMaxRequestSize(AValue: Integer);
    function GetMaxHeaderSize: Integer;
    procedure SetMaxHeaderSize(AValue: Integer);
    function GetDrainTimeoutMs: Integer;
    procedure SetDrainTimeoutMs(AValue: Integer);
    function GetMaxQueueDepth: Integer;
    procedure SetMaxQueueDepth(AValue: Integer);
    function GetSecureHeadersEnabled: Boolean;
    procedure SetSecureHeadersEnabled(AValue: Boolean);
    function GetServerBanner: string;
    procedure SetServerBanner(const AValue: string);
    function GetTCPFastOpen: Boolean;
    procedure SetTCPFastOpen(AValue: Boolean);
    function GetPerCoreAccept: Boolean;
    procedure SetPerCoreAccept(AValue: Boolean);
    function GetSyncDispatch: Boolean;
    procedure SetSyncDispatch(AValue: Boolean);
    function GetOnH2Push: TOnH2Push;
    procedure SetOnH2Push(AValue: TOnH2Push);
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
    function Head(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;
    function Head(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;
    function All(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;
    function All(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;

    // --- Global middleware ---
    function Use(AMiddleware: TNativeMiddleware): TPoseidonServer; overload;
    function Use(AMiddleware: TNativeMiddlewareFunc): TPoseidonServer; overload;

    // --- Route groups ---
    function Group(const APrefix: string): TNativeGroup;
    procedure GroupBlock(const APrefix: string; ABlock: TNativeGroupBlock);

    // --- WebSocket ---
    procedure WebSocket(const APath: string; AHandler: TWSMessageCallback);

    // --- Lifecycle ---
    procedure Listen(APort: Integer; const AHost: string = '0.0.0.0';
      AOnListen: TProc = nil);
    procedure Stop;

    // --- Config (delegates to TPoseidonNativeServer) ---
    procedure ConfigureSSL(const ACertFile, AKeyFile: string);
    procedure AddSSLCert(const AHostName, ACertFile, AKeyFile: string);
    procedure ConfigureMTLS(const ACAFile: string);
    procedure EnableHTTP2(AEnabled: Boolean = True);

    // --- Properties ---
    property Server: TPoseidonNativeServer read FServer;
    property Running: Boolean read FRunning;
    property MaxConnections: Integer read GetMaxConnections write SetMaxConnections;
    property MaxConnectionsPerIP: Integer read GetMaxConnectionsPerIP write SetMaxConnectionsPerIP;
    property WorkerCount: Integer read GetWorkerCount write SetWorkerCount;
    property MinWorkerCount: Integer read GetMinWorkerCount write SetMinWorkerCount;
    property IdleTimeoutMs: Integer read GetIdleTimeoutMs write SetIdleTimeoutMs;
    property MaxRequestSize: Integer read GetMaxRequestSize write SetMaxRequestSize;
    property MaxHeaderSize: Integer read GetMaxHeaderSize write SetMaxHeaderSize;
    property DrainTimeoutMs: Integer read GetDrainTimeoutMs write SetDrainTimeoutMs;
    property MaxQueueDepth: Integer read GetMaxQueueDepth write SetMaxQueueDepth;
    property SecureHeadersEnabled: Boolean read GetSecureHeadersEnabled write SetSecureHeadersEnabled;
    property ServerBanner: string read GetServerBanner write SetServerBanner;
    property TCPFastOpen: Boolean read GetTCPFastOpen write SetTCPFastOpen;
    property PerCoreAccept: Boolean read GetPerCoreAccept write SetPerCoreAccept;
    property SyncDispatch: Boolean read GetSyncDispatch write SetSyncDispatch;
    property OnH2Push: TOnH2Push read GetOnH2Push write SetOnH2Push;
    property PIDFile: string read FPIDFile write FPIDFile;
    property OnLog: TOnPoseidonLog read GetOnLog write SetOnLog;
    property OnRequestLog: TOnPoseidonRequestLog read GetOnRequestLog write SetOnRequestLog;
  end;

implementation

uses
  System.JSON,
  Poseidon.Problem,
  Poseidon.Exception,
  Poseidon.GracefulReload;

const
  CAllMethods: array[0..6] of string = (
    'GET', 'POST', 'PUT', 'DELETE', 'PATCH', 'HEAD', 'OPTIONS');

var
  GNotFoundBody: TBytes;
  GInternalErrorBody: TBytes;

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TPoseidonServer.Create;
begin
  inherited Create;
  FServer := TPoseidonNativeServer.Create;
  FRouter := TNativeRouter.Create;
  FGroups := TObjectList<TNativeGroup>.Create(True);
  FRunning := False;
  FShutdownEvent := TEvent.Create(nil, True, False, '');
end;

destructor TPoseidonServer.Destroy;
begin
  if FRunning then
    try Stop except on E: Exception do; end;
  FreeAndNil(FShutdownEvent);
  FreeAndNil(FGroups);
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

function TPoseidonServer.Head(const APath: string; AHandler: TNativeHandler): TPoseidonServer;
begin Result := AddRoute('HEAD', APath, AHandler, nil); end;

function TPoseidonServer.Head(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer;
begin Result := AddRoute('HEAD', APath, nil, AHandler); end;

function TPoseidonServer.All(const APath: string; AHandler: TNativeHandler): TPoseidonServer;
var
  I: Integer;
begin
  for I := Low(CAllMethods) to High(CAllMethods) do
    AddRoute(CAllMethods[I], APath, AHandler, nil);
  Result := Self;
end;

function TPoseidonServer.All(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer;
var
  I: Integer;
begin
  for I := Low(CAllMethods) to High(CAllMethods) do
    AddRoute(CAllMethods[I], APath, nil, AHandler);
  Result := Self;
end;

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
// Route groups
// ---------------------------------------------------------------------------

function TPoseidonServer.Group(const APrefix: string): TNativeGroup;
begin
  Result := TNativeGroup.Create(FRouter, APrefix);
  FGroups.Add(Result);
end;

procedure TPoseidonServer.GroupBlock(const APrefix: string; ABlock: TNativeGroupBlock);
var
  LGroup: TNativeGroup;
begin
  LGroup := Group(APrefix);
  ABlock(LGroup);
end;

// ---------------------------------------------------------------------------
// WebSocket
// ---------------------------------------------------------------------------

procedure TPoseidonServer.WebSocket(const APath: string; AHandler: TWSMessageCallback);
begin
  FServer.RegisterWSHandler(APath, AHandler);
end;

// ---------------------------------------------------------------------------
// Request handling — zero-copy hot path with RFC 7807 error handling
// ---------------------------------------------------------------------------

procedure TPoseidonServer.HandleRequest(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TArray<TPair<string,string>>);
var
  LCtx: TNativeRequestContext;
  LRoute: PNativeRouteEntry;
  LProblem: TProblemDetail;
  LJson: TJSONObject;
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
    AContentType := 'application/problem+json';
    ABody := GNotFoundBody;
    AExtraHeaders := nil;
    Exit;
  end;

  try
    ExecuteChain(LCtx, LRoute^.Middlewares, FRouter.GlobalMiddlewares, LRoute);
  except
    on E: EPoseidonException do
    begin
      LProblem := TProblemDetail.FromException(E, AReq.Path);
      LJson := LProblem.ToJSON;
      try
        AStatus := LProblem.Status;
        AContentType := 'application/problem+json';
        ABody := TEncoding.UTF8.GetBytes(LJson.ToString);
        AExtraHeaders := nil;
      finally
        LJson.Free;
      end;
      Exit;
    end;
    on E: Exception do
    begin
      AStatus := 500;
      AContentType := 'application/problem+json';
      ABody := GInternalErrorBody;
      AExtraHeaders := nil;
      Exit;
    end;
  end;

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

  try
    FServer.Listen(AHost, APort,
    procedure(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtraHeaders: TArray<TPair<string,string>>)
    begin
      HandleRequest(AReq, AStatus, AContentType, ABody, AExtraHeaders);
    end,
    procedure
    begin
      WritePIDFile(FPIDFile);
      if Assigned(AOnListen) then
        AOnListen();
    end);
  except
    FRunning := False;
    raise;
  end;

  if IsConsole then
  begin
    {$IFNDEF MSWINDOWS}
    // Poll for signal flag since signal handler only sets an atomic flag
    while FShutdownEvent.WaitFor(500) = wrTimeout do
      CheckShutdownSignal;
    {$ELSE}
    FShutdownEvent.WaitFor;
    {$ENDIF}
  end;
end;

procedure TPoseidonServer.Stop;
begin
  if not FRunning then Exit;
  FRunning := False;
  FServer.Stop;
  RemovePIDFile(FPIDFile);
  FShutdownEvent.SetEvent;
end;

// ---------------------------------------------------------------------------
// Config delegates
// ---------------------------------------------------------------------------

procedure TPoseidonServer.ConfigureSSL(const ACertFile, AKeyFile: string);
begin
  FServer.ConfigureSSL(ACertFile, AKeyFile);
end;

procedure TPoseidonServer.AddSSLCert(const AHostName, ACertFile, AKeyFile: string);
begin
  FServer.AddSSLCert(AHostName, ACertFile, AKeyFile);
end;

procedure TPoseidonServer.ConfigureMTLS(const ACAFile: string);
begin
  FServer.ConfigureMTLS(ACAFile);
end;

procedure TPoseidonServer.EnableHTTP2(AEnabled: Boolean);
begin
  FServer.HTTP2Enabled := AEnabled;
end;

// ---------------------------------------------------------------------------
// Property delegates
// ---------------------------------------------------------------------------

function TPoseidonServer.GetMaxConnections: Integer;
begin Result := FServer.MaxConnections; end;

procedure TPoseidonServer.SetMaxConnections(AValue: Integer);
begin FServer.MaxConnections := AValue; end;

function TPoseidonServer.GetMaxConnectionsPerIP: Integer;
begin Result := FServer.MaxConnectionsPerIP; end;

procedure TPoseidonServer.SetMaxConnectionsPerIP(AValue: Integer);
begin FServer.MaxConnectionsPerIP := AValue; end;

function TPoseidonServer.GetOnLog: TOnPoseidonLog;
begin Result := FServer.OnLog; end;

procedure TPoseidonServer.SetOnLog(AValue: TOnPoseidonLog);
begin FServer.OnLog := AValue; end;

function TPoseidonServer.GetOnRequestLog: TOnPoseidonRequestLog;
begin Result := FServer.OnRequestLog; end;

procedure TPoseidonServer.SetOnRequestLog(AValue: TOnPoseidonRequestLog);
begin FServer.OnRequestLog := AValue; end;

function TPoseidonServer.GetWorkerCount: Integer;
begin Result := FServer.WorkerCount; end;

procedure TPoseidonServer.SetWorkerCount(AValue: Integer);
begin FServer.WorkerCount := AValue; end;

function TPoseidonServer.GetMinWorkerCount: Integer;
begin Result := FServer.MinWorkerCount; end;

procedure TPoseidonServer.SetMinWorkerCount(AValue: Integer);
begin FServer.MinWorkerCount := AValue; end;

function TPoseidonServer.GetIdleTimeoutMs: Integer;
begin Result := FServer.IdleTimeoutMs; end;

procedure TPoseidonServer.SetIdleTimeoutMs(AValue: Integer);
begin FServer.IdleTimeoutMs := AValue; end;

function TPoseidonServer.GetMaxRequestSize: Integer;
begin Result := FServer.MaxRequestSize; end;

procedure TPoseidonServer.SetMaxRequestSize(AValue: Integer);
begin FServer.MaxRequestSize := AValue; end;

function TPoseidonServer.GetMaxHeaderSize: Integer;
begin Result := FServer.MaxHeaderSize; end;

procedure TPoseidonServer.SetMaxHeaderSize(AValue: Integer);
begin FServer.MaxHeaderSize := AValue; end;

function TPoseidonServer.GetDrainTimeoutMs: Integer;
begin Result := FServer.DrainTimeoutMs; end;

procedure TPoseidonServer.SetDrainTimeoutMs(AValue: Integer);
begin FServer.DrainTimeoutMs := AValue; end;

function TPoseidonServer.GetMaxQueueDepth: Integer;
begin Result := FServer.MaxQueueDepth; end;

procedure TPoseidonServer.SetMaxQueueDepth(AValue: Integer);
begin FServer.MaxQueueDepth := AValue; end;

function TPoseidonServer.GetSecureHeadersEnabled: Boolean;
begin Result := FServer.SecureHeadersEnabled; end;

procedure TPoseidonServer.SetSecureHeadersEnabled(AValue: Boolean);
begin FServer.SecureHeadersEnabled := AValue; end;

function TPoseidonServer.GetServerBanner: string;
begin Result := FServer.ServerBanner; end;

procedure TPoseidonServer.SetServerBanner(const AValue: string);
begin FServer.ServerBanner := AValue; end;

function TPoseidonServer.GetTCPFastOpen: Boolean;
begin Result := FServer.TCPFastOpen; end;

procedure TPoseidonServer.SetTCPFastOpen(AValue: Boolean);
begin FServer.TCPFastOpen := AValue; end;

function TPoseidonServer.GetPerCoreAccept: Boolean;
begin Result := FServer.PerCoreAccept; end;

procedure TPoseidonServer.SetPerCoreAccept(AValue: Boolean);
begin FServer.PerCoreAccept := AValue; end;

function TPoseidonServer.GetSyncDispatch: Boolean;
begin Result := FServer.SyncDispatch; end;

procedure TPoseidonServer.SetSyncDispatch(AValue: Boolean);
begin FServer.SyncDispatch := AValue; end;

function TPoseidonServer.GetOnH2Push: TOnH2Push;
begin Result := FServer.OnH2Push; end;

procedure TPoseidonServer.SetOnH2Push(AValue: TOnH2Push);
begin FServer.OnH2Push := AValue; end;

initialization
  GNotFoundBody := TEncoding.UTF8.GetBytes(
    '{"type":"about:blank","title":"Not Found","status":404}');
  GInternalErrorBody := TEncoding.UTF8.GetBytes(
    '{"type":"about:blank","title":"Internal Server Error","status":500}');

end.
