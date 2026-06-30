unit Horse.Provider.Poseidon;

// Horse provider backed by Poseidon Native HTTP server (IOCP/Windows, epoll/Linux).
//
// Problem solved:
//   The default Horse/Indy provider creates ONE OS thread per HTTP connection.
//   Under 700-800 concurrent connections, 800 threads × 8MB stack = 6.4GB of
//   virtual memory, corrupting the glibc heap → double free → process crash.
//
// Solution:
//   Poseidon manages all connections via IOCP/epoll (a few kernel file descriptors).
//   An ELASTIC worker pool handles blocking route handlers (ACBr, DB, etc.).
//   The pool starts with a small number of threads (same as IO workers, 4–16)
//   and grows up to MaxWorkerCount (default 200) under load, then shrinks back.
//   Thread count is bounded; startup is always fast regardless of MaxWorkerCount.
//
// Usage (project defines):
//   Add {$DEFINE HORSE_Poseidon} in project options (Delphi Compiler > Conditional defines).
//   Horse.pas picks this provider automatically when HORSE_Poseidon is set.
//
// Optional tuning (before Listen):
//   THorse.WorkerCount := 200;   // max request-handler threads (default 200)
//   THorse.MinWorkerCount := 8;  // min threads kept warm (default: auto 4–16)
//   THorse.MaxConnections := 0;  // 0 = unlimited at TCP level

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  Horse.Provider.Abstract,
  Horse.Core,
  Horse.Request,
  Horse.Response,
  Horse.Exception.Interrupted,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer,
  Poseidon.Net.WebAdapters.Native,
  Poseidon.Net.Pool.Native;

type
  THorseProviderPoseidonNative = class(THorseProviderAbstract)
  private const
    DEFAULT_HOST            = '0.0.0.0';
    DEFAULT_PORT            = 9000;
    // 0 = auto (request pool max defaults to 200; min matches IO workers 4–16).
    // The elastic pool starts at min threads regardless of WorkerCount — startup
    // is fast even when WorkerCount = 200. Set WorkerCount for prod blocking
    // workloads (DB, ACBr); keep 0 or set explicitly via MinWorkerCount to
    // control the startup thread count.
    DEFAULT_WORKER_COUNT    = 0;
    DEFAULT_MIN_WORKER_COUNT = 0;
  private
    class var FPort:            Integer;
    class var FHost:            string;
    class var FRunning:         Boolean;
    class var FEvent:           TEvent;
    class var FServer:          TPoseidonNativeServer;
    class var FWorkerCount:     Integer;
    class var FMinWorkerCount:  Integer;
    class var FMaxConns:        Integer;
    class var FMaxQueueDepth:   Integer;
    class var FKeepAlive:       Boolean;
    class var FListenQueue:     Integer;
    class var FSSLEnabled:      Boolean;

    class function  GetDefaultEvent: TEvent; static;
    class function  GetDefaultServer: TPoseidonNativeServer; static;
    class procedure HandleRequest(
      const AReq:          TPoseidonNativeRequest;
      out   AStatus:       Integer;
      out   AContentType:  string;
      out   ABody:         TBytes;
      out   AExtraHeaders: TArray<TPair<string,string>>); static;
  public
    // Standard Horse provider properties (compatible with Console provider API)
    class property Port:                Integer read FPort        write FPort;
    class property Host:                string  read FHost        write FHost;
    class property MaxConnections:      Integer read FMaxConns       write FMaxConns;
    // R-5 backpressure: max queued+executing tasks before 503. 0 = unlimited.
    class property MaxQueueDepth:       Integer read FMaxQueueDepth  write FMaxQueueDepth;
    class property ListenQueue:         Integer read FListenQueue write FListenQueue;
    class property KeepConnectionAlive: Boolean read FKeepAlive   write FKeepAlive;
    // Poseidon-specific: max request-handler threads (elastic pool ceiling).
    // Pool STARTS at MinWorkerCount and grows here under load — startup is
    // always fast regardless of this value. 0 = auto (default 200).
    class property WorkerCount:    Integer read FWorkerCount    write FWorkerCount;
    // Minimum request-handler threads kept alive at all times (pool floor).
    // 0 = auto (same as IO workers: max(4, ProcessorCount*2) capped at 16).
    class property MinWorkerCount: Integer read FMinWorkerCount write FMinWorkerCount;
    class property IsRunning:   Boolean read FRunning;
    // Set to True when Poseidon is behind HTTPS/TLS so Swagger UI shows https first.
    // Default False (plain HTTP). Must be set before Listen.
    class property SSLEnabled:  Boolean read FSSLEnabled write FSSLEnabled;

    class procedure Listen; overload; override;
    class procedure Listen(const APort: Integer; const AHost: string;
      const ACallbackListen, ACallbackStopListen: TProc); reintroduce; overload; static;
    class procedure Listen(const APort: Integer;
      const ACallbackListen, ACallbackStopListen: TProc); reintroduce; overload; static;
    class procedure Listen(const ACallbackListen,
      ACallbackStopListen: TProc); reintroduce; overload; static;
    class procedure Listen(const APort: Integer); reintroduce; overload; static;
    class procedure StopListen; override;

    class destructor UnInitialize;
  end;

implementation

uses
  Horse.Core.RouterTree,
  Web.HTTPApp,
  System.RegularExpressions;

{ THorseProviderPoseidonNative }

class function THorseProviderPoseidonNative.GetDefaultEvent: TEvent;
begin
  if FEvent = nil then
    FEvent := TEvent.Create(nil, True, False, '');
  Result := FEvent;
end;

class function THorseProviderPoseidonNative.GetDefaultServer: TPoseidonNativeServer;
begin
  if FServer = nil then
    FServer := TPoseidonNativeServer.Create;
  Result := FServer;
end;

class procedure THorseProviderPoseidonNative.HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
var
  LWebReq:          TNativeWebRequest;
  LWebRes:          TNativeWebResponse;
  LReq:             THorseRequest;
  LRes:             THorseResponse;
  LStatus:          Integer;
  LCT:              string;
  LBody:            TBytes;
  LEHdrs:           TArray<TPair<string,string>>;
  LFlushed:         Boolean;
  LJson:            string;
  LForwardedProto:  string;
  LClientIsHTTPS:   Boolean;
  LIdx:             Integer;
begin
  LStatus  := 500;
  LCT      := 'application/json';
  LBody    := nil;   // defer allocation — handler overwrites in 99.9% of cases
  LEHdrs   := nil;
  LFlushed := False;

  // Acquire pooled TWebRequest/TWebResponse adapters backed by the Poseidon native request
  TNativeContextPool.Acquire(
    AReq,
    procedure(S: Integer; const CT: string; const B: TBytes;
      const EH: TArray<TPair<string,string>>)
    begin
      LStatus  := S;
      LCT      := CT;
      LBody    := B;
      LEHdrs   := EH;
      LFlushed := True;
    end,
    LWebReq, LWebRes);

  // Wrap in Horse request/response
  LReq := THorseRequest.Create(LWebReq);
  LRes := THorseResponse.Create(LWebRes);
  try
    try
      // Execute the Horse middleware + route chain
      THorseCore.Routes.Execute(LReq, LRes);
    except
      on E: EHorseCallbackInterrupted do
        ; // Normal: middleware called Interrupt/Next chain ended — response already set
      on E: Exception do
      begin
        LWebRes.StatusCode  := 500;
        LWebRes.ContentType := 'application/json';
        LWebRes.Content     := '{"error":"' + E.Message.Replace('"', '\"') + '"}';
      end;
    end;

    if not LFlushed then
      LWebRes.CommitResponse;  // Flush → closure fills LStatus/LCT/LBody/LEHdrs
  finally
    // Avoid double-free: Horse sets response content to the same object as request body
    if LReq.Body<TObject> = LRes.Content then
      LRes.Content(nil);
    LReq.Free;
    LRes.Free;
    TNativeContextPool.Release(LWebReq, LWebRes);
  end;

  AStatus       := LStatus;
  AContentType  := LCT;
  ABody         := LBody;
  AExtraHeaders := LEHdrs;

  // Swagger UI picks the first scheme from the spec 'schemes' array.
  // Detect the client-facing scheme automatically:
  //   - FSSLEnabled = True  → Poseidon terminates TLS directly → HTTPS
  //   - X-Forwarded-Proto: https → sitting behind an HTTPS reverse proxy → HTTPS
  //   - otherwise → plain HTTP
  // When HTTP, put http first so Swagger UI defaults to the correct scheme with
  // no manual configuration. GBSwagger serialises via TJSONValue.Format
  // (pretty-printed), so the array may span lines — regex handles any whitespace.
  if SameText(AContentType, 'application/json') and
     AReq.Path.EndsWith('swagger/doc/json') then
  begin
    LForwardedProto := '';
    for LIdx := 0 to High(AReq.Headers) do
      if SameText(AReq.Headers[LIdx].Key, 'X-Forwarded-Proto') then
      begin
        LForwardedProto := AReq.Headers[LIdx].Value;
        Break;
      end;
    LClientIsHTTPS := FSSLEnabled or SameText(LForwardedProto, 'https');
    if not LClientIsHTTPS then
    begin
      LJson := TEncoding.UTF8.GetString(ABody);
      LJson := TRegEx.Replace(LJson,
        '"schemes"\s*:\s*\[\s*"https"\s*,\s*"http"\s*\]',
        '"schemes":["http","https"]');
      ABody := TEncoding.UTF8.GetBytes(LJson);
    end;
  end;
end;

class procedure THorseProviderPoseidonNative.Listen;
var
  LServer: TPoseidonNativeServer;
begin
  inherited;  // Calls THorseProviderAbstract.Listen (does nothing but satisfies abstract)

  if FPort <= 0 then FPort := DEFAULT_PORT;
  if FHost.IsEmpty then FHost := DEFAULT_HOST;

  LServer := GetDefaultServer;

  // WorkerCount: elastic pool ceiling (0 = auto → default 200).
  // The pool STARTS at MinWorkerCount (default: auto 4–16) and grows under load.
  // Startup is always fast regardless of WorkerCount.
  LServer.WorkerCount    := FWorkerCount;
  LServer.MinWorkerCount := FMinWorkerCount;

  // MaxConnections at TCP level — 0 means unlimited (Poseidon backpressure via worker pool)
  if FMaxConns > 0 then
    LServer.MaxConnections := FMaxConns;

  // R-5 backpressure: limit queued+executing tasks; 0 = unlimited
  if FMaxQueueDepth > 0 then
    LServer.MaxQueueDepth := FMaxQueueDepth;

  // Idle keep-alive timeout: 30s matches nginx default
  LServer.IdleTimeoutMs := 30000;

  FRunning := True;

  LServer.Listen(FHost, FPort,
    procedure(const AReq: TPoseidonNativeRequest;
              out   AStatus: Integer;
              out   AContentType: string;
              out   ABody: TBytes;
              out   AExtraHeaders: TArray<TPair<string,string>>)
    begin
      HandleRequest(AReq, AStatus, AContentType, ABody, AExtraHeaders);
    end,
    procedure
    begin
      DoOnListen;  // Fires the user callback (prints port, etc.)
    end);

  // Block console apps until StopListen is called
  if IsConsole then
    while FRunning do
      GetDefaultEvent.WaitFor(500);
end;

class procedure THorseProviderPoseidonNative.Listen(const APort: Integer;
  const AHost: string; const ACallbackListen, ACallbackStopListen: TProc);
begin
  FPort        := APort;
  FHost        := AHost;
  OnListen     := ACallbackListen;
  OnStopListen := ACallbackStopListen;
  Listen;
end;

class procedure THorseProviderPoseidonNative.Listen(const APort: Integer;
  const ACallbackListen, ACallbackStopListen: TProc);
begin
  Listen(APort, DEFAULT_HOST, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderPoseidonNative.Listen(const ACallbackListen,
  ACallbackStopListen: TProc);
begin
  Listen(FPort, FHost, ACallbackListen, ACallbackStopListen);
end;

class procedure THorseProviderPoseidonNative.Listen(const APort: Integer);
begin
  Listen(APort, DEFAULT_HOST, nil, nil);
end;

class procedure THorseProviderPoseidonNative.StopListen;
begin
  if FServer = nil then
    raise Exception.Create('THorseProviderPoseidonNative is not listening');

  FRunning := False;
  FServer.Stop;
  DoOnStopListen;
  GetDefaultEvent.SetEvent;
end;

class destructor THorseProviderPoseidonNative.UnInitialize;
begin
  if FServer <> nil then
  begin
    try FServer.Stop; except end;
    FreeAndNil(FServer);
  end;
  FreeAndNil(FEvent);
end;

initialization
  THorseProviderPoseidonNative.FPort           := 0;
  THorseProviderPoseidonNative.FHost           := '';
  THorseProviderPoseidonNative.FWorkerCount    := THorseProviderPoseidonNative.DEFAULT_WORKER_COUNT;
  THorseProviderPoseidonNative.FMinWorkerCount := THorseProviderPoseidonNative.DEFAULT_MIN_WORKER_COUNT;
  THorseProviderPoseidonNative.FMaxConns       := 0;
  THorseProviderPoseidonNative.FMaxQueueDepth  := 0;
  THorseProviderPoseidonNative.FKeepAlive      := True;
  THorseProviderPoseidonNative.FListenQueue    := 0;
  THorseProviderPoseidonNative.FRunning        := False;
  THorseProviderPoseidonNative.FServer         := nil;
  THorseProviderPoseidonNative.FEvent          := nil;
  THorseProviderPoseidonNative.FSSLEnabled     := False;

end.
