unit Poseidon.Net.HttpServer;

// Native HTTP/1.1 server.
// Windows: IOCP — WSARecv + single WSASend per response.
// Linux:   epoll(7) level-triggered + EPOLLONESHOT.
//
// Critical optimization (both platforms):
//   _BuildResponse concatenates HTTP headers + body into ONE TBytes, sent with
//   ONE syscall. CrossSocket issues two writes; Nagle/delayed-ACK on loopback
//   produces multi-second stalls.
//
// _TryParseRequest, _BuildResponse, and _ProcessRecv are platform-agnostic.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  syncobjs,
  Math,
  DateUtils,
  Generics.Collections,
  Poseidon.Compat,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Math,
  System.DateUtils,
  System.ZLib,
  System.Generics.Collections,
  {$ENDIF}
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.Connection.Manager,
  Poseidon.Net.IdleSweep,
  Poseidon.Net.SSL.Manager,
  Poseidon.Net.WebSocket.Manager,
  Poseidon.Net.HTTP2.Manager,
  Poseidon.Net.Dispatcher,
  Poseidon.Net.WebSocket,
  Poseidon.Net.HTTP2,
  Poseidon.Net.ProxyProtocol,
  Poseidon.Net.IO,
  Poseidon.Net.Interfaces,
  Poseidon.Net.Pool.Workers;

type
  // R-5: TPoseidonNativeServer implements IDispatchCallbacks (non-ref-counted).
  // Types TPoseidonNativeRequest, TOnNativeRequest, TLogLevel, TOnPoseidonLog,
  // TPoseidonRequestLogEvent, TOnPoseidonRequestLog live in Poseidon.Net.Types
  // and are accessible via the transitive uses chain.

  TPoseidonNativeServer = class
  private
    FOnRequest: TOnNativeRequest;
    FActive: Boolean;
    FConnManager: TConnectionManager;
    FInFlightCount: Int64;
    FPadInflight: array[0..6] of Int64; // Cache-line padding — isolate FInFlightCount
    FIdleTimeoutMs: Integer;
    FIdleSweep: TIdleSweepManager;
    FSSLManager: TSSLManager;
    FWSManager: TWebSocketManager;
    FH2Manager: THTTP2Manager;
    FWorkerCount: Integer;
    FMinWorkerCount: Integer;
    FRequestPool: TElasticWorkerPool;
    FOnLog: TOnPoseidonLog;
    FOnRequestLog: TOnPoseidonRequestLog;
    FMinTLSVersion: Integer;
    FMaxRequestSize: Integer;
    FMaxHeaderSize: Integer;
    FDrainEvent: TEvent;
    FDrainTimeoutMs: Integer;
    FMaxQueueDepth: Integer;
    FSecureHeadersEnabled: Boolean;
    FServerBanner: string;
    FTCPFastOpen: Boolean;
    FPerCoreAccept: Boolean;
    FSyncDispatch: Boolean;
    FFastPath: Boolean;
    FProxyProtocol: TProxyProtocolMode;
    FTrustedProxies: TArray<string>;
    FIOBackend: IIOBackend;
    FDispatcher: TProtocolDispatcher;
    FBufferPool: IBufferPool;
    FSSLProvider: ISSLProvider;

    procedure SetSyncDispatch(AValue: Boolean);
    procedure SetFastPath(AValue: Boolean);
    function  GetMaxConnections: Integer;
    procedure SetMaxConnections(AValue: Integer);
    function  GetMaxConnectionsPerIP: Integer;
    procedure SetMaxConnectionsPerIP(AValue: Integer);
    function  GetSSLEnabled: Boolean;
    function  GetH2Enabled: Boolean;
    procedure SetH2Enabled(AValue: Boolean);
    function  GetMinTLSVersion: Integer;
    procedure SetMinTLSVersion(AValue: Integer);
    function  GetMaxWSFrameSize: Int64;
    procedure SetMaxWSFrameSize(AValue: Int64);
    function  GetH2MaxConcurrentStreams: Cardinal;
    procedure SetH2MaxConcurrentStreams(AValue: Cardinal);
    function  GetH2InitialWindowSize: Cardinal;
    procedure SetH2InitialWindowSize(AValue: Cardinal);
    function  GetOnH2Push: TOnH2Push;
    procedure SetOnH2Push(AValue: TOnH2Push);
    procedure _OnNewSocket(ASocket: NativeUInt; const ARemoteAddr: string);
    procedure _PostRecv(AConn: Pointer);
    procedure _PostSend(AConn: Pointer; const AResponse: TBytes;
      AActualLen: Integer = 0);
    procedure _CloseConn(AConn: Pointer);
    procedure _ProcessRecv(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);
    procedure _ProcessRecvSSL(AConn: Pointer; const ABuf: PByte; ALen: Cardinal;
      out AAborted: Boolean);
    procedure _ProcessRecvPlain(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);

    procedure _DispatchAccumBuf(AConn: Pointer);  // thin shim — builds TDispatchConfig + calls FDispatcher
    function  _BuildResponse(AStatus: Integer; const AContentType: string;
      const ABody: TBytes; AKeepAlive: Boolean;
      const AExtra: TArray<TPair<string,string>>): TBytes;
    procedure _EncryptAndSend(AConn: Pointer; const AAppData: TBytes;
      AActualLen: Integer = 0);
    // Vectored send (headers + body, no concatenation on the plain path; SSL
    // concatenates then encrypts). Shared by the dispatch pipeline and by
    // deferred responders. Must be called with LConn.Lock held.
    procedure _SendResponseV(AConn: Pointer;
      const AHeaders: TBytes; AHdrLen: Integer;
      const ABody: TBytes; ABodyLen: Integer);
    procedure _SSLFlushWriteBio(AConn: Pointer);


    // WS/H2 methods moved to managers — thin shims for adapter
    procedure _UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure _UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function  _DispatchWSFrames(AConn: Pointer): Boolean;
    procedure _Log(ALevel: TLogLevel; const AMessage: string);
  public
    // ABufferPool, ASSLProvider: nil selects the built-in default
    // (backward-compatible — existing code that calls Create without args unchanged).
    constructor Create(
      ABufferPool:  IBufferPool  = nil;
      ASSLProvider: ISSLProvider = nil); overload;
    destructor  Destroy; override;
    procedure ConfigureSSL(const ACertFile, AKeyFile: string);
    procedure AddSSLCert(const AHostName, ACertFile, AKeyFile: string);
    // S-5: enable mTLS — require client certificates signed by ACAFile (PEM CA bundle).
    // Must be called after ConfigureSSL and before Listen().
    procedure ConfigureMTLS(const ACAFile: string);
    procedure Listen(const AHost: string; APort: Integer;
      AOnRequest: TOnNativeRequest; AOnListen: TProc = nil);
    procedure Stop;
    property Active:        Boolean read FActive;
    property InFlightCount: Int64   read FInFlightCount;
    property SSLEnabled:    Boolean read GetSSLEnabled;
    // Idle-timeout per connection in milliseconds.
    // Connections with no _ProcessRecv activity for IdleTimeoutMs are shut down.
    // Default 10000 (10s). Set to 0 to disable. Applies during SSL handshake too.
    property IdleTimeoutMs: Integer read FIdleTimeoutMs write FIdleTimeoutMs;
    // Connection limits delegated to TConnectionManager
    property MaxConnections: Integer read GetMaxConnections write SetMaxConnections;
    property MaxConnectionsPerIP: Integer read GetMaxConnectionsPerIP write SetMaxConnectionsPerIP;
    // HTTP/2 via ALPN: when True and SSL is configured, the server negotiates "h2"
    // and handles HTTP/2 connections. Must be set before Listen(). Default False.
    property HTTP2Enabled: Boolean read GetH2Enabled write SetH2Enabled;
    // Maximum concurrent request-handler threads (elastic pool ceiling).
    // 0 = auto (default 200). For blocking workloads (DB, ACBr) set explicitly.
    // The pool STARTS with MinWorkerCount threads and grows here under load,
    // so startup is always fast regardless of this value.
    property WorkerCount:    Integer read FWorkerCount    write FWorkerCount;
    // Minimum concurrent request-handler threads kept alive at all times.
    // 0 = auto (same as IO workers: max(4, ProcessorCount*2) capped at 16).
    // Use MinWorkerCount to pre-warm the pool without setting a high max.
    property MinWorkerCount: Integer read FMinWorkerCount write FMinWorkerCount;
    // Optional log callback. When assigned, all internal errors are routed here.
    // When nil (default), errors are written to ErrOutput.
    property OnLog: TOnPoseidonLog read FOnLog write FOnLog;
    // Optional access-log callback. Fired after every HTTP/1.1 request is
    // dispatched. Receives method, path, status, duration (ms), remote addr,
    // and byte counts. nil (default) = no access logging.
    property OnRequestLog: TOnPoseidonRequestLog
      read FOnRequestLog write FOnRequestLog;
    // S-6: Minimum TLS protocol version. Applied at ConfigureSSL time.
    // Use Poseidon.Net.SSL constants: TLS1_2_VERSION ($0303), TLS1_3_VERSION ($0304).
    // Default TLS1_2_VERSION ($0303). Set to 0 to use the OpenSSL library default.
    property MinTLSVersion: Integer read GetMinTLSVersion write SetMinTLSVersion;
    // R-4: Maximum accumulated request body+headers size. Default 8MB (8388608).
    property MaxRequestSize: Integer read FMaxRequestSize write FMaxRequestSize;
    // R-4: Maximum header section size. Default 65536 (64 KB).
    property MaxHeaderSize:  Integer read FMaxHeaderSize  write FMaxHeaderSize;
    // R-1: Maximum milliseconds to wait for in-flight requests to complete during
    // Stop(). Default 30000 (30 s). Stop() blocks for at most this long.
    property DrainTimeoutMs: Integer read FDrainTimeoutMs write FDrainTimeoutMs;
    // R-5: Maximum concurrent in-flight requests. 0 = unlimited (default).
    // When the limit is reached, new requests receive 503.
    property MaxQueueDepth:  Integer read FMaxQueueDepth  write FMaxQueueDepth;
    // R-3: Maximum WebSocket frame payload size in bytes. 0 = unlimited (default).
    // Frames exceeding this limit close the connection with code 1009.
    property MaxWSFrameSize: Int64   read GetMaxWSFrameSize  write SetMaxWSFrameSize;
    property H2MaxConcurrentStreams: Cardinal read GetH2MaxConcurrentStreams write SetH2MaxConcurrentStreams;
    property H2InitialWindowSize: Cardinal read GetH2InitialWindowSize write SetH2InitialWindowSize;
    // A-1: When True, responses include X-Content-Type-Options, X-Frame-Options,
    // and Referrer-Policy headers. Default False (opt-in).
    property SecureHeadersEnabled: Boolean
      read FSecureHeadersEnabled write FSecureHeadersEnabled;
    // A-2: Value of the Server: response header. Default 'Poseidon/1.0'.
    // Set to '' to suppress the Server: header entirely.
    property ServerBanner: string read FServerBanner write FServerBanner;
    // TCP_FASTOPEN (RFC 7413): allows clients to send data with the SYN packet on
    // reconnections, saving one RTT. Default False (opt-in).
    // Requires Windows 10 1607+ or Linux kernel 3.7+ with tcp_fastopen enabled.
    // Silently ignored when the OS does not support it.
    property TCPFastOpen: Boolean read FTCPFastOpen write FTCPFastOpen;
    // Per-core accept (#58): creates one listen socket per CPU core with
    // SO_REUSEPORT (Linux). The kernel distributes incoming connections
    // across sockets via source IP/port hash. Default False (single accept).
    // On Windows: ignored (IOCP handles distribution internally).
    property PerCoreAccept: Boolean read FPerCoreAccept write FPerCoreAccept;
    // SyncDispatch: execute request handlers directly on the IO/completion thread
    // instead of posting to the elastic worker pool. Eliminates the
    // completion<->pool hand-off (~2x throughput on the multi-ring io_uring
    // backend) but BLOCKS that thread during handler execution — enable ONLY when
    // handlers are non-blocking (no DB, no file I/O, no Sleep). Default False
    // (async worker pool; safe for blocking handlers).
    // Orthogonal to FastPath: SyncDispatch chooses WHERE the pipeline runs
    // (inline vs pool); FastPath chooses WHICH pipeline (full vs lightweight).
    // With FastPath=False (default) the FULL pipeline runs, so WebSocket / h2c
    // upgrades, access logging and security headers all work under SyncDispatch.
    property SyncDispatch: Boolean read FSyncDispatch write SetSyncDispatch;
    // FastPath: use the lightweight dispatch pipeline (minimal parse, no header
    // materialization, no logging/security headers, NO WebSocket/h2c upgrade
    // detection). Squeezes out the last ~10-20% for pure HTTP/1.1
    // request-response workloads that never upgrade. Default False (full
    // pipeline). Must be set before Listen(). Combine with SyncDispatch for the
    // maximum-throughput plain-HTTP path.
    property FastPath: Boolean read FFastPath write SetFastPath;
    // Proxy Protocol: ppDisabled (default) disables PP processing.
    // ppV1/ppV2: enforce a specific version. ppAuto: detect by signature.
    // Enable only when the server receives connections exclusively from a
    // trusted load-balancer; accepting PP from untrusted sources allows
    // IP spoofing. Must be set before Listen().
    property ProxyProtocol: TProxyProtocolMode
      read FProxyProtocol write FProxyProtocol;
    // CIDRs (IPv4) allowed to inject a PROXY header. Empty = fail-close: no
    // PROXY header is honored (feature effectively off). Must include the
    // load-balancer's IP for ProxyProtocol to take effect. Set before Listen().
    property TrustedProxies: TArray<string>
      read FTrustedProxies write FTrustedProxies;
    procedure RegisterWSHandler(const APath: string; AHandler: TWSMessageCallback);
    property OnH2Push: TOnH2Push read GetOnH2Push write SetOnH2Push;
  end;

implementation

// R-1: platform-specific IO backend (IOCP on Windows, epoll/io_uring on Linux).
// This is the only {$IFDEF} remaining in HttpServer — used solely to select the backend.
{$IFDEF MSWINDOWS}
uses
  Poseidon.Net.IO.RIO,
  Poseidon.Net.IO.IOCP,
  Poseidon.Net.SSL,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.Security,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.HTTP1.Parser,
  Poseidon.Native.Types;
{$ELSE}
uses
  Poseidon.Net.IO.IOUring,
  Poseidon.Net.IO.Epoll,
  Poseidon.Net.SSL,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.Security,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.HTTP1.Parser,
  Poseidon.Native.Types;
{$ENDIF}

// ===========================================================================
// Shared constants
// ===========================================================================

const
  CMaxRequestSize = 8 * 1024 * 1024;
  CRecvBufSize = 32768;
  CAccumInitial = 8192;
  CWorkerCountMin = 4;
  // W15: cap auto-computed IO workers — ProcessorCount*2 on high-core machines
  // (e.g. 100 logical → 200 threads) wasted stack with no throughput gain.
  // IO workers only handle I/O events (recv/send); request handlers run in
  // the elastic TElasticWorkerPool, so this cap can stay low.
  CWorkerCountMax = 16;
  // Default ceiling for the elastic request-worker pool. Pools start at
  // min workers (4–16) and grow here only when all workers are busy.
  // 200 × 8MB stack = 1.6GB — well within safe limits.
  CDefaultMaxWorkers = 200;
  // Workers above MinWorkerCount self-terminate after this many ms idle.
  CWorkerIdleTimeoutMs = 30000;
  CDefaultIdleTimeoutMs = 10000;
  CDefaultMaxHeaderSize = 65536;
  CDefaultDrainTimeoutMs = 30000;
  CShutdownTimeoutMs = 1000;

// ===========================================================================
// Shared: SSL helpers — encrypt-and-send + handshake write-BIO flush
// ===========================================================================

procedure TPoseidonNativeServer._EncryptAndSend(AConn: Pointer;
  const AAppData: TBytes; AActualLen: Integer = 0);
var
  LConn:    TNativeConn absolute AConn;
  LPending: Integer;
  LEnc:     TBytes;
  LN:       Integer;
  LSendLen: Integer;
  LTmp:     TBytes;
begin
  // P-4: AActualLen > 0 means AAppData is a pool buffer; use only first AActualLen bytes.
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AAppData);

  if LConn.SSLHandle = nil then
  begin
    _PostSend(AConn, AAppData, AActualLen);
    Exit;
  end;

  if LSendLen > 0 then
  begin
    if FSSLProvider.SSLWrite(LConn.SSLHandle, @AAppData[0], LSendLen) <= 0 then
    begin
      // P-4: release pool buffer before closing connection
      if AActualLen > 0 then
      begin
        LTmp := AAppData;
        FBufferPool.Release(LTmp);
      end;
      _CloseConn(AConn);
      Exit;
    end;
    // P-4: pool buffer fully consumed by SSL_Write — release it before BIO_Read
    if AActualLen > 0 then
    begin
      LTmp := AAppData;
      FBufferPool.Release(LTmp);
    end;
  end;

  LPending := FSSLProvider.BIOPending(LConn.SSLWriteBio);
  if LPending <= 0 then
  begin
    _PostSend(AConn, nil);
    Exit;
  end;

  SetLength(LEnc, LPending);
  LN := FSSLProvider.BIORead(LConn.SSLWriteBio, @LEnc[0], LPending);
  if LN <= 0 then
  begin
    _CloseConn(AConn);
    Exit;
  end;
  if LN < LPending then SetLength(LEnc, LN);
  _PostSend(AConn, LEnc);
end;

// Vectored send shared by the dispatch pipeline (via TServerDispatchAdapter)
// and by deferred responders (TPoseidonResponder). Plain path sends headers +
// body without concatenation; SSL path concatenates then encrypts. Caller holds
// LConn.Lock.
procedure TPoseidonNativeServer._SendResponseV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
var
  LConn:   TNativeConn absolute AConn;
  LConcat: TBytes;
  LHLen:   Integer;
  LBLen:   Integer;
  LTmp:    TBytes;
begin
  LHLen := AHdrLen;
  if LHLen = 0 then LHLen := Length(AHeaders);
  LBLen := ABodyLen;
  if LBLen = 0 then LBLen := Length(ABody);

  if LConn.SSLHandle <> nil then
  begin
    // SSL requires contiguous data — concatenate and encrypt
    LConcat := FBufferPool.Acquire(LHLen + LBLen);
    if LHLen > 0 then Move(AHeaders[0], LConcat[0], LHLen);
    if LBLen > 0 then Move(ABody[0], LConcat[LHLen], LBLen);
    LTmp := AHeaders;
    FBufferPool.Release(LTmp);
    LTmp := ABody;
    FBufferPool.Release(LTmp);
    _EncryptAndSend(AConn, LConcat, LHLen + LBLen);
  end
  else
    FIOBackend.PostSendV(AConn, AHeaders, LHLen, ABody, LBLen);
end;

// ===========================================================================
// Deferred responses — TPoseidonResponder + Ctx.Defer hook
// ===========================================================================

// Per-thread deferral context. Set by TServerDispatchAdapter.InvokeRequest
// around the handler call so Ctx.Defer (via GPoseidonDeferHook -> _DeferHook)
// can mint a responder bound to the connection dispatched ON THIS THREAD.
// Saved/restored for reentrancy; restored to nil after the top-level dispatch
// returns, so an HTTP/2 request (which never sets this) sees GDeferConn=nil and
// Ctx.Defer raises instead of binding to a stale connection.
threadvar
  GDeferConn:      Pointer;   // TNativeConn being dispatched
  GDeferServer:    Pointer;   // TPoseidonNativeServer
  GDeferKeepAlive: Boolean;
  GDeferSecure:    Boolean;
  GDeferBanner:    string;
  GDeferActive:    Boolean;   // set True by the hook when Defer() was called

// Merge middleware-added headers (captured at Defer time) with the headers the
// app passes to Respond. App values win on a case-insensitive key collision.
function _MergeExtra(const ABase, AOver: TArray<TPair<string,string>>):
  TArray<TPair<string,string>>;
var
  I, J, N: Integer;
  LFound:  Boolean;
begin
  if Length(AOver) = 0 then Exit(ABase);
  if Length(ABase) = 0 then Exit(AOver);
  Result := Copy(ABase);
  for I := 0 to High(AOver) do
  begin
    LFound := False;
    for J := 0 to High(Result) do
      if SameText(Result[J].Key, AOver[I].Key) then
      begin
        Result[J] := AOver[I];
        LFound := True;
        Break;
      end;
    if not LFound then
    begin
      N := Length(Result);
      SetLength(Result, N + 1);
      Result[N] := AOver[I];
    end;
  end;
end;

type
  // Completes a deferred HTTP/1.1 response. Bound to a connection at Defer time,
  // it keeps that connection alive (AddRef), exempt from the idle sweep
  // (InFlightPool) and counted for backpressure (FInFlightCount) until the app
  // responds — from ANY thread — or drops the handle (force-close fallback).
  TPoseidonResponder = class(TInterfacedObject, IPoseidonResponder)
  private
    FConn:      Pointer;
    FServer:    TPoseidonNativeServer;
    FKeepAlive: Boolean;
    FSecure:    Boolean;
    FBanner:    string;
    FBaseExtra: TArray<TPair<string,string>>;
    FDone:      Integer;  // 0=pending, 1=torn down (atomic, one-shot)
    procedure Teardown(ASend: Boolean; AStatus: Integer;
      const AContentType: string; const ABody: TBytes;
      const AExtra: TArray<TPair<string,string>>);
  public
    constructor Create(AConn: Pointer; AServer: TPoseidonNativeServer;
      AKeepAlive, ASecure: Boolean; const ABanner: string;
      const ABaseExtra: TArray<TPair<string,string>>);
    destructor Destroy; override;
    procedure Respond(AStatus: Integer; const AContentType: string;
      const ABody: TBytes; const AExtra: TArray<TPair<string,string>>);
    procedure RespondText(AStatus: Integer; const AContentType, ABody: string);
    procedure Fail(AStatus: Integer; const AMessage: string);
  end;

constructor TPoseidonResponder.Create(AConn: Pointer;
  AServer: TPoseidonNativeServer; AKeepAlive, ASecure: Boolean;
  const ABanner: string; const ABaseExtra: TArray<TPair<string,string>>);
begin
  inherited Create;
  FConn      := AConn;
  FServer    := AServer;
  FKeepAlive := AKeepAlive;
  FSecure    := ASecure;
  FBanner    := ABanner;
  FBaseExtra := ABaseExtra;
  FDone      := 0;
  // Keep the connection object alive across the async gap, exempt it from the
  // idle sweep, and count it as in-flight so pre-queue backpressure sees the
  // pending deferred work.
  TNativeConn(FConn).AddRef;
  TInterlocked.Increment(TNativeConn(FConn).InFlightPool);
  TInterlocked.Increment(FServer.FInFlightCount);
end;

destructor TPoseidonResponder.Destroy;
begin
  // Handle dropped without a reply -> force-close so the connection is never
  // left hanging (recv unarmed, counters never released).
  Teardown(False, 0, '', nil, nil);
  inherited Destroy;
end;

procedure TPoseidonResponder.Teardown(ASend: Boolean; AStatus: Integer;
  const AContentType: string; const ABody: TBytes;
  const AExtra: TArray<TPair<string,string>>);
var
  LConn:       TNativeConn;
  LMerged:     TArray<TPair<string,string>>;
  LHdr:        TBytes;
  LHdrLen:     Integer;
  LDoShutdown: Boolean;
begin
  // Exactly one of {Respond/Fail, destructor} runs the teardown.
  if TInterlocked.CompareExchange(FDone, 1, 0) <> 0 then Exit;
  LConn := TNativeConn(FConn);
  LDoShutdown := False;
  try
    LConn.Lock.Enter;
    try
      // Socket already gone (client disconnected / idle-swept while we waited):
      // skip the send, just release. The object stayed alive via our AddRef.
      if TInterlocked.Add(LConn.Closed, 0) = 0 then
      begin
        if ASend then
        begin
          LConn.KeepAlive := FKeepAlive;
          LMerged := _MergeExtra(FBaseExtra, AExtra);
          LHdr := BuildHTTPResponseHeaders(AStatus, AContentType, Length(ABody),
            FKeepAlive, LMerged, FSecure, FBanner, LHdrLen);
          FServer._SendResponseV(FConn, LHdr, LHdrLen, ABody, Length(ABody));
        end
        else
          LDoShutdown := True;  // graceful close after we drop the lock
      end;
    finally
      LConn.Lock.Leave;
    end;
    if LDoShutdown then
      FServer.FIOBackend.ShutdownConn(FConn);
  finally
    TInterlocked.Decrement(LConn.InFlightPool);
    TInterlocked.Decrement(FServer.FInFlightCount);
    LConn.Release;
    FConn := nil;
  end;
end;

procedure TPoseidonResponder.Respond(AStatus: Integer;
  const AContentType: string; const ABody: TBytes;
  const AExtra: TArray<TPair<string,string>>);
begin
  Teardown(True, AStatus, AContentType, ABody, AExtra);
end;

procedure TPoseidonResponder.RespondText(AStatus: Integer;
  const AContentType, ABody: string);
begin
  Respond(AStatus, AContentType, TEncoding.UTF8.GetBytes(ABody), nil);
end;

procedure TPoseidonResponder.Fail(AStatus: Integer; const AMessage: string);
begin
  Respond(AStatus, 'text/plain', TEncoding.UTF8.GetBytes(AMessage), nil);
end;

// GPoseidonDeferHook target — mints a responder bound to the connection being
// dispatched on the calling thread. Reads the per-thread deferral context set
// by TServerDispatchAdapter.InvokeRequest.
function _DeferHook(const ABaseExtra: TArray<TPair<string,string>>):
  IPoseidonResponder;
begin
  if GDeferConn = nil then
    raise Exception.Create(
      'Ctx.Defer is only valid during an active HTTP/1.1 request dispatch ' +
      '(HTTP/2 deferred responses are not supported yet).');
  Result := TPoseidonResponder.Create(GDeferConn,
    TPoseidonNativeServer(GDeferServer), GDeferKeepAlive, GDeferSecure,
    GDeferBanner, ABaseExtra);
  GDeferActive := True;
end;

procedure TPoseidonNativeServer._SSLFlushWriteBio(AConn: Pointer);
var
  LConn:    TNativeConn absolute AConn;
  LPending: Integer;
  LEnc:     TBytes;
  LN:       Integer;
begin
  if LConn.SSLWriteBio = nil then Exit;
  LPending := FSSLProvider.BIOPending(LConn.SSLWriteBio);
  if LPending <= 0 then Exit;
  SetLength(LEnc, LPending);
  LN := FSSLProvider.BIORead(LConn.SSLWriteBio, @LEnc[0], LPending);
  if LN <= 0 then Exit;
  if LN < LPending then SetLength(LEnc, LN);
  _PostSend(AConn, LEnc);
end;

// ===========================================================================
// R-5: TServerDispatchAdapter — IDispatchCallbacks bridge from server to dispatcher
// ===========================================================================

type
  TServerDispatchAdapter = class(TInterfacedObject, IDispatchCallbacks)
  private
    FServer: TPoseidonNativeServer;
  public
    constructor Create(AServer: TPoseidonNativeServer);
    procedure PostRecv(AConn: Pointer);
    procedure CloseConn(AConn: Pointer);
    procedure SendResponse(AConn: Pointer; const AData: TBytes; AActualLen: Integer);
    procedure SendResponseV(AConn: Pointer;
      const AHeaders: TBytes; AHdrLen: Integer;
      const ABody: TBytes; ABodyLen: Integer);
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function  DispatchWSFrames(AConn: Pointer): Boolean;
    procedure InvokeRequest(AConn: Pointer; const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtra: TArray<TPair<string,string>>;
      out ADeferred: Boolean);
    procedure LogRequest(const AEvent: TPoseidonRequestLogEvent);
    procedure AdjustInflight(ADelta: Integer);
  end;

constructor TServerDispatchAdapter.Create(AServer: TPoseidonNativeServer);
begin
  inherited Create;
  FServer := AServer;
end;

procedure TServerDispatchAdapter.PostRecv(AConn: Pointer);
begin
  FServer._PostRecv(AConn);
end;

procedure TServerDispatchAdapter.CloseConn(AConn: Pointer);
begin
  FServer._CloseConn(AConn);
end;

procedure TServerDispatchAdapter.SendResponse(AConn: Pointer;
  const AData: TBytes; AActualLen: Integer);
begin
  FServer._EncryptAndSend(AConn, AData, AActualLen);
end;

// Vectored send — SSL falls back to concatenation, plain uses PostSendV
procedure TServerDispatchAdapter.SendResponseV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
begin
  FServer._SendResponseV(AConn, AHeaders, AHdrLen, ABody, ABodyLen);
end;

procedure TServerDispatchAdapter.UpgradeToWS(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
  FServer._UpgradeToWS(AConn, AReq);
end;

procedure TServerDispatchAdapter.UpgradeToH2C(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
  FServer._UpgradeToH2C(AConn, AReq);
end;

function TServerDispatchAdapter.DispatchWSFrames(AConn: Pointer): Boolean;
begin
  Result := FServer._DispatchWSFrames(AConn);
end;

procedure TServerDispatchAdapter.InvokeRequest(AConn: Pointer;
  const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtra: TArray<TPair<string,string>>;
  out ADeferred: Boolean);
var
  LSaveConn, LSaveServer: Pointer;
  LSaveKA, LSaveSec, LSaveActive: Boolean;
  LSaveBanner: string;
begin
  AStatus      := 500;
  AContentType := 'application/json';
  ABody        := DefaultErrorBody;
  SetLength(AExtra, 0);
  ADeferred    := False;

  // Publish the deferral context for this thread (save prior for reentrancy).
  LSaveConn   := GDeferConn;
  LSaveServer := GDeferServer;
  LSaveKA     := GDeferKeepAlive;
  LSaveSec    := GDeferSecure;
  LSaveBanner := GDeferBanner;
  LSaveActive := GDeferActive;

  GDeferConn      := AConn;
  GDeferServer    := FServer;
  GDeferKeepAlive := AReq.KeepAlive;
  GDeferSecure    := FServer.FSecureHeadersEnabled;
  GDeferBanner    := FServer.FServerBanner;
  GDeferActive    := False;
  try
    try
      FServer.FOnRequest(AReq, AStatus, AContentType, ABody, AExtra);
    except
      on E: Exception do
      begin
        AStatus      := 500;
        AContentType := 'application/problem+json';
        // Do not leak the raw exception message (info disclosure + it could break
        // the JSON). Unexpected errors get a generic detail.
        ABody        := TEncoding.UTF8.GetBytes(
          '{"type":"about:blank","title":"Internal Server Error",' +
          '"status":500,"detail":"An unexpected error occurred."}');
        SetLength(AExtra, 0);
      end;
    end;
    ADeferred := GDeferActive;
  finally
    GDeferConn      := LSaveConn;
    GDeferServer    := LSaveServer;
    GDeferKeepAlive := LSaveKA;
    GDeferSecure    := LSaveSec;
    GDeferBanner    := LSaveBanner;
    GDeferActive    := LSaveActive;
  end;
end;

procedure TServerDispatchAdapter.LogRequest(const AEvent: TPoseidonRequestLogEvent);
begin
  if Assigned(FServer.FOnRequestLog) then
    FServer.FOnRequestLog(AEvent);
end;

procedure TServerDispatchAdapter.AdjustInflight(ADelta: Integer);
begin
  if ADelta > 0 then
    TInterlocked.Increment(FServer.FInFlightCount)
  else
    TInterlocked.Decrement(FServer.FInFlightCount);
end;

// ===========================================================================
// R-1: TServerIOAdapter — IIOCallbacks bridge from IO backend to server
// ===========================================================================

type
  TServerIOAdapter = class(TInterfacedObject, IIOCallbacks)
  private
    FServer: TPoseidonNativeServer;
  public
    constructor Create(AServer: TPoseidonNativeServer);
    procedure OnNewConn(ASocket: NativeUInt; const AAddr: string);
    procedure OnRecv(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);
    procedure OnSendComplete(AConn: Pointer);
    procedure OnConnError(AConn: Pointer);
  end;

constructor TServerIOAdapter.Create(AServer: TPoseidonNativeServer);
begin
  inherited Create;
  FServer := AServer;
end;

procedure TServerIOAdapter.OnNewConn(ASocket: NativeUInt; const AAddr: string);
begin
  FServer._OnNewSocket(ASocket, AAddr);
end;

procedure TServerIOAdapter.OnRecv(AConn: Pointer; const ABuf: PByte;
  ALen: Cardinal);
begin
  FServer._ProcessRecv(AConn, ABuf, ALen);
end;


procedure TServerIOAdapter.OnSendComplete(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  // During TLS handshake: keep alive regardless of KeepAlive flag —
  // we need to re-arm recv for the next handshake message.
  if (LConn.SSLHandle <> nil) and not LConn.SSLHandshook then
    FServer._PostRecv(AConn)
  // #213: HTTP/2 drives its own read cycle — StepH2Branch re-arms recv once,
  // AFTER TH2Conn.ProcessData fully returns. On the epoll backend a response
  // send inside ProcessData completes inline and lands here synchronously while
  // the worker is still in ProcessData; re-arming recv now would let a second
  // recv run _ProcessRecvSSL (SSL_Read) concurrently with the worker's
  // _EncryptAndSend (SSL_Write) on the same SSL* / H2Conn. Skip — the dispatch
  // path owns the re-arm.
  else if LConn.H2Conn <> nil then
    // no-op: StepH2Branch.PostRecv handles it
  else if LConn.KeepAlive then
  begin
    if LConn.AccumLen > 0 then
      FServer._ProcessRecv(AConn, nil, 0)  // pipelined request in AccumBuf
    else
      FServer._PostRecv(AConn);
  end
  else
    FServer._CloseConn(AConn);
end;

procedure TServerIOAdapter.OnConnError(AConn: Pointer);
begin
  FServer._CloseConn(AConn);
end;

// ===========================================================================
// Shared: ConfigureSSL — call before Listen() to enable HTTPS
// ===========================================================================

// SSL config delegated to TSSLManager
procedure TPoseidonNativeServer.ConfigureSSL(const ACertFile, AKeyFile: string);
begin
  if FActive then
    raise Exception.Create('ConfigureSSL must be called before Listen()');
  FSSLManager.ConfigureSSL(ACertFile, AKeyFile, FH2Manager.H2Enabled, Self);
end;

procedure TPoseidonNativeServer.ConfigureMTLS(const ACAFile: string);
begin
  if FActive then
    raise Exception.Create('ConfigureMTLS must be called before Listen()');
  FSSLManager.ConfigureMTLS(ACAFile);
end;

procedure TPoseidonNativeServer.AddSSLCert(const AHostName, ACertFile, AKeyFile: string);
begin
  if FActive then
    raise Exception.Create('AddSSLCert must be called before Listen()');
  FSSLManager.AddSSLCert(AHostName, ACertFile, AKeyFile);
end;

// ===========================================================================
// Shared: _BuildResponse — delegates to Poseidon.Net.ResponseBuilder (R-3)
// ===========================================================================

function TPoseidonNativeServer._BuildResponse(AStatus: Integer;
  const AContentType: string; const ABody: TBytes; AKeepAlive: Boolean;
  const AExtra: TArray<TPair<string,string>>): TBytes;
begin
  Result := BuildHTTPResponse(AStatus, AContentType, ABody, AKeepAlive,
    AExtra, FSecureHeadersEnabled, FServerBanner);
end;

// ===========================================================================
// Shared: _ProcessRecv and helpers
// _ProcessRecv is the entry point called by the platform worker (IOCP/epoll).
// It delegates to three focused methods:
//   _ProcessRecvSSL  — feeds bytes into the OpenSSL BIO pair and drains plaintext
//   _ProcessRecvPlain — accumulates plain-HTTP bytes into AccumBuf
//   _DispatchAccumBuf — routes the accumulated buffer to H2/WS/HTTP1 handlers
// ===========================================================================

procedure TPoseidonNativeServer._ProcessRecvSSL(AConn: Pointer;
  const ABuf: PByte; ALen: Cardinal; out AAborted: Boolean);
var
  LConn:   TNativeConn absolute AConn;
  LDecBuf: array[0..CRecvBufSize - 1] of Byte;
  LDecN:   Integer;
  LErr:    Integer;
  LHsRet:  Integer;
  LNew:    TBytes;
begin
  AAborted := False;

  // Feed encrypted bytes into the ReadBio
  if (ALen > 0) and
     (FSSLProvider.BIOWrite(LConn.SSLReadBio, ABuf, ALen) <= 0) then
  begin
    AAborted := True;
    _CloseConn(AConn);
    Exit;
  end;

  if not LConn.SSLHandshook then
  begin
    LHsRet := FSSLProvider.DoHandshake(LConn.SSLHandle);
    if LHsRet = 1 then
    begin
      LConn.SSLHandshook := True;
      // ALPN: if client negotiated "h2", create TH2Conn for this connection.
      if FH2Manager.H2Enabled and (FSSLProvider.GetSelectedProtocol(LConn.SSLHandle) = 'h2') then
      begin
        LConn.H2Conn := TH2Conn.Create(AConn, FH2Manager.H2Send, FH2Manager.H2Close, FH2Manager.H2OnRequest,
          FH2Manager.H2MaxConcurrentStreams, FH2Manager.H2InitialWindowSize);
        LConn.H2Conn.SendInitialSettings;
        LConn.KeepAlive := True;  // HTTP/2 connections are always persistent
      end;
    end
    else
    begin
      LErr := FSSLProvider.GetError(LConn.SSLHandle, LHsRet);
      if LErr = SSL_ERROR_WANT_READ then
      begin
        _SSLFlushWriteBio(AConn);
        if FSSLProvider.BIOPending(LConn.SSLWriteBio) <= 0 then
          _PostRecv(AConn);
        AAborted := True;
        Exit;
      end;
      AAborted := True;
      _CloseConn(AConn);
      Exit;
    end;
    _SSLFlushWriteBio(AConn);
    if FSSLProvider.BIOPending(LConn.SSLWriteBio) > 0 then
    begin
      // Handshake response is being sent; wait for next recv to continue.
      AAborted := True;
      Exit;
    end;
  end;

  // Drain decrypted application data into AccumBuf
  repeat
    LDecN := FSSLProvider.SSLRead(LConn.SSLHandle, @LDecBuf[0], CRecvBufSize);
    if LDecN > 0 then
    begin
      if LConn.AccumLen + LDecN > Length(LConn.AccumBuf) then
      begin
        // P-2: grow via pool tier instead of raw SetLength
        LNew := FBufferPool.Acquire(
          Max(LConn.AccumLen + LDecN, Length(LConn.AccumBuf) * 2));
        Move(LConn.AccumBuf[0], LNew[0], LConn.AccumLen);
        FBufferPool.Release(LConn.AccumBuf);
        LConn.AccumBuf := LNew;
      end;
      Move(LDecBuf[0], LConn.AccumBuf[LConn.AccumLen], LDecN);
      Inc(LConn.AccumLen, LDecN);
    end
    else
    begin
      LErr := FSSLProvider.GetError(LConn.SSLHandle, LDecN);
      if LErr = SSL_ERROR_WANT_READ then Break;
      AAborted := True;
      _CloseConn(AConn);
      Exit;
    end;
  until False;
end;

procedure TPoseidonNativeServer._ProcessRecvPlain(AConn: Pointer;
  const ABuf: PByte; ALen: Cardinal);
var
  LConn: TNativeConn absolute AConn;
  LNew:  TBytes;
begin
  if LConn.AccumLen + Integer(ALen) > Length(LConn.AccumBuf) then
  begin
    // P-2: grow via pool tier instead of raw SetLength
    LNew := FBufferPool.Acquire(
      Max(LConn.AccumLen + Integer(ALen), Length(LConn.AccumBuf) * 2));
    Move(LConn.AccumBuf[0], LNew[0], LConn.AccumLen);
    FBufferPool.Release(LConn.AccumBuf);
    LConn.AccumBuf := LNew;
  end;
  Move(ABuf^, LConn.AccumBuf[LConn.AccumLen], ALen);
  Inc(LConn.AccumLen, ALen);
end;

{$IFDEF FPC}
// FPC async dispatch job. The Delphi build posts a capturing anonymous method
// to the worker pool; FPC 3.3.1 (trunk) AVs when that closure is constructed on
// an IOCP worker thread (a compiler codegen bug). This heap job carries the
// same state in explicit fields and is posted as a plain method reference —
// no capture — sidestepping the bug. It frees itself when the work completes.
type
  TFPCDispatchJob = class
  public
    Server: TPoseidonNativeServer;
    Conn:   Pointer;
    Cfg:    TDispatchConfig;
    procedure Execute;
  end;

procedure TFPCDispatchJob.Execute;
begin
  try
    TNativeConn(Conn).LastActivityTick := TThread.GetTickCount64;
    TNativeConn(Conn).Lock.Enter;
    try
      Server.FDispatcher.Dispatch(Conn, Cfg);
    finally
      TNativeConn(Conn).Lock.Leave;
    end;
  finally
    TInterlocked.Decrement(Server.FInFlightCount);
    TInterlocked.Decrement(TNativeConn(Conn).InFlightPool);
    TNativeConn(Conn).Release;
    Free;
  end;
end;
{$ENDIF}

procedure TPoseidonNativeServer._DispatchAccumBuf(AConn: Pointer);
// Builds a TDispatchConfig snapshot and posts request handling to the elastic
// worker pool. IO workers return immediately to process more I/O events.
// TNativeConn.AddRef/Release guards the connection lifetime across the async
// boundary: the connection stays alive until the pool worker's finally runs.
//
// R-5 backpressure: FInFlightCount is incremented HERE (queue time) and
// decremented in the pool worker's finally — so it counts queued + executing
// tasks, not just executing ones.  This prevents the elastic pool's task queue
// from growing unboundedly when all workers are blocked on DB acquisition.
var
  LCfg:  TDispatchConfig;
  LResp: TBytes;
{$IFDEF FPC}
  LJob:  TFPCDispatchJob;
{$ENDIF}
begin
  // R-5: pre-queue backpressure — reject with 503 before queuing when the
  // number of in-flight (queued + executing) tasks reaches MaxQueueDepth.
  // Force-close the connection (KeepAlive := False) so the client does not
  // immediately retry on the same socket and worsen the overload.
  if (FMaxQueueDepth > 0) and
     (TInterlocked.Read(FInFlightCount) >= Int64(FMaxQueueDepth)) then
  begin
    TNativeConn(AConn).KeepAlive := False;
    LResp := BuildHTTPResponse(503, 'text/plain',
      TEncoding.ASCII.GetBytes('Service Unavailable'),
      False, [], FSecureHeadersEnabled, FServerBanner);
    _EncryptAndSend(AConn, LResp);
    Exit;
  end;

  LCfg.ProxyProtocol        := FProxyProtocol;
  LCfg.TrustedProxies       := FTrustedProxies;
  LCfg.MaxRequestSize       := FMaxRequestSize;
  LCfg.MaxHeaderSize        := FMaxHeaderSize;
  LCfg.H2Enabled            := FH2Manager.H2Enabled;
  LCfg.SecureHeadersEnabled := FSecureHeadersEnabled;
  LCfg.ServerBanner         := FServerBanner;
  LCfg.MaxQueueDepth        := 0;           // consumed here; Dispatcher needs no copy
  LCfg.InFlightCount        := nil;         // ditto

  // v2-perf: SyncDispatch — execute directly on IO thread, skip worker pool.
  // Eliminates thread transition overhead (~50-100us per request).
  if FSyncDispatch then
  begin
    TNativeConn(AConn).LastActivityTick := TThread.GetTickCount64;
    FDispatcher.Dispatch(AConn, LCfg);
    Exit;
  end;

  // Count this task as in-flight from queue time.  The finally in the pool
  // worker decrements it after Dispatch returns, ensuring the counter always
  // reflects queued + executing work — making the pre-queue check above
  // accurate across all concurrent _DispatchAccumBuf callers.
  TInterlocked.Increment(FInFlightCount);

  // AddRef before posting: pool worker holds this ref until Dispatch returns.
  // InFlightPool is an atomic counter (not a bool): pipelining can result in
  // lambda N+1 being posted while lambda N is still in its finally block.
  // Using a counter ensures the idle-sweep skips the connection as long as ANY
  // pool lambda is live.  LastActivity is refreshed when the worker actually
  // starts — prevents queue-wait time from counting toward the idle timeout.
  TInterlocked.Increment(TNativeConn(AConn).InFlightPool);
  TNativeConn(AConn).AddRef;
{$IFDEF FPC}
  // FPC: post a non-capturing method (heap job) — see TFPCDispatchJob. The job
  // owns the same teardown (Decrement FInFlightCount/InFlightPool, Release) and
  // frees itself. AddRef above keeps LConn alive until the job's Release.
  LJob := TFPCDispatchJob.Create;
  LJob.Server := Self;
  LJob.Conn   := AConn;
  LJob.Cfg    := LCfg;
  FRequestPool.Post(LJob.Execute);
{$ELSE}
  FRequestPool.Post(
    procedure
    begin
      try
        TNativeConn(AConn).LastActivityTick := TThread.GetTickCount64;  // reset idle-clock at dequeue time
        // #213: serialize the whole dispatch (reads AccumBuf, mutates H2Conn,
        // calls SSL_Write) against the IO thread's _ProcessRecvSSL on this conn.
        // The AddRef taken before Post keeps LConn (and its Lock) alive until
        // the Release below, even if the handler triggers _CloseConn.
        TNativeConn(AConn).Lock.Enter;
        try
          FDispatcher.Dispatch(AConn, LCfg);
        finally
          TNativeConn(AConn).Lock.Leave;
        end;
      finally
        TInterlocked.Decrement(FInFlightCount);
        TInterlocked.Decrement(TNativeConn(AConn).InFlightPool);
        TNativeConn(AConn).Release;
      end;
    end);
{$ENDIF}
end;

procedure TPoseidonNativeServer._ProcessRecv(AConn: Pointer;
  const ABuf: PByte; ALen: Cardinal);
var
  LConn:    TNativeConn absolute AConn;
  LAborted: Boolean;
begin
  // #213: hold a ref across the whole call — a nested _CloseConn (SSL/parse
  // error paths) can drop the last (server) ref and Destroy the connection
  // (the epoll backend keeps no per-recv ref), which would free LConn.Lock out
  // from under the finally below.
  LConn.AddRef;
  try
    // #213: serialize the entire recv/decrypt/dispatch against the request
    // worker pool, which reads AccumBuf and calls SSL_Write on this same conn.
    LConn.Lock.Enter;
    try
      try
        LConn.LastActivityTick := TThread.GetTickCount64;  // vDSO on Linux — no syscall
        LAborted := False;
        if LConn.SSLHandle <> nil then
          _ProcessRecvSSL(AConn, ABuf, ALen, LAborted)
        else if ALen > 0 then
          _ProcessRecvPlain(AConn, ABuf, ALen);
        if not LAborted then
          _DispatchAccumBuf(AConn);
      except
        on E: Exception do
        begin
          _Log(llError, '[recv] ' + LConn.RemoteAddr + ' EX [' + E.ClassName +
            ']: ' + E.Message);
          try _CloseConn(AConn); except on E: Exception do; end;
        end;
      end;
    finally
      LConn.Lock.Leave;
    end;
  finally
    LConn.Release;
  end;
end;

// ===========================================================================
// Shared: connection-limit admission
// ===========================================================================

// Connection limit getters/setters delegate to FConnManager
function TPoseidonNativeServer.GetMaxConnections: Integer;
begin
  Result := FConnManager.MaxConnections;
end;

procedure TPoseidonNativeServer.SetMaxConnections(AValue: Integer);
begin
  FConnManager.MaxConnections := AValue;
end;

function TPoseidonNativeServer.GetMaxConnectionsPerIP: Integer;
begin
  Result := FConnManager.MaxConnectionsPerIP;
end;

procedure TPoseidonNativeServer.SetMaxConnectionsPerIP(AValue: Integer);
begin
  FConnManager.MaxConnectionsPerIP := AValue;
end;

function TPoseidonNativeServer.GetSSLEnabled: Boolean;
begin Result := FSSLManager.SSLEnabled; end;

function TPoseidonNativeServer.GetH2Enabled: Boolean;
begin Result := FH2Manager.H2Enabled; end;

procedure TPoseidonNativeServer.SetH2Enabled(AValue: Boolean);
begin FH2Manager.H2Enabled := AValue; end;

function TPoseidonNativeServer.GetMinTLSVersion: Integer;
begin Result := FSSLManager.MinTLSVersion; end;

procedure TPoseidonNativeServer.SetMinTLSVersion(AValue: Integer);
begin FSSLManager.MinTLSVersion := AValue; end;

function TPoseidonNativeServer.GetMaxWSFrameSize: Int64;
begin Result := FWSManager.MaxWSFrameSize; end;

procedure TPoseidonNativeServer.SetMaxWSFrameSize(AValue: Int64);
begin FWSManager.MaxWSFrameSize := AValue; end;

function TPoseidonNativeServer.GetH2MaxConcurrentStreams: Cardinal;
begin Result := FH2Manager.H2MaxConcurrentStreams; end;

procedure TPoseidonNativeServer.SetH2MaxConcurrentStreams(AValue: Cardinal);
begin FH2Manager.H2MaxConcurrentStreams := AValue; end;

function TPoseidonNativeServer.GetH2InitialWindowSize: Cardinal;
begin Result := FH2Manager.H2InitialWindowSize; end;

procedure TPoseidonNativeServer.SetH2InitialWindowSize(AValue: Cardinal);
begin FH2Manager.H2InitialWindowSize := AValue; end;

function TPoseidonNativeServer.GetOnH2Push: TOnH2Push;
begin Result := FH2Manager.OnH2Push; end;

procedure TPoseidonNativeServer.SetOnH2Push(AValue: TOnH2Push);
begin FH2Manager.OnH2Push := AValue; end;

// ===========================================================================
// Shared: lifecycle (constructor/destructor) — must precede any Listen path
// ===========================================================================

procedure TPoseidonNativeServer.SetSyncDispatch(AValue: Boolean);
begin
  if FSyncDispatch = AValue then
    Exit;
  // SyncDispatch only chooses inline vs pool at dispatch time; it does not change
  // the pipeline object, so no rebuild is needed. Still deny the change under
  // traffic — a request may be mid-dispatch on the old routing.
  if FActive then
    raise Exception.Create(
      'TPoseidonNativeServer: SyncDispatch cannot be changed while active');
  FSyncDispatch := AValue;
end;

procedure TPoseidonNativeServer.SetFastPath(AValue: Boolean);
begin
  if FFastPath = AValue then
    Exit;
  // FastPath selects the pipeline (lightweight vs full), baked into the step
  // array at construction — rebuild the dispatcher. Swapping FDispatcher under
  // traffic is a UAF (a worker may still deref the old one), so deny while active.
  if FActive then
    raise Exception.Create(
      'TPoseidonNativeServer: FastPath cannot be changed while active');
  FFastPath := AValue;
  if FDispatcher <> nil then
  begin
    FreeAndNil(FDispatcher);
    FDispatcher := TProtocolDispatcher.Create(
      TServerDispatchAdapter.Create(Self), FFastPath);
  end;
end;

constructor TPoseidonNativeServer.Create(
  ABufferPool:  IBufferPool;
  ASSLProvider: ISSLProvider);
begin
  inherited Create;
  if ABufferPool <> nil then FBufferPool := ABufferPool
  else FBufferPool := DefaultBufferPool;
  if ASSLProvider <> nil then FSSLProvider := ASSLProvider
  else FSSLProvider := DefaultSSLProvider;
  FConnManager := TConnectionManager.Create;
  FSSLManager := TSSLManager.Create(FSSLProvider);
  FIdleTimeoutMs := CDefaultIdleTimeoutMs;
  FMaxRequestSize := CMaxRequestSize;
  FMaxHeaderSize := CDefaultMaxHeaderSize;
  FDrainTimeoutMs := CDefaultDrainTimeoutMs;
  FDrainEvent := TEvent.Create(nil, True, False, '');
  FMaxQueueDepth := 0;
  FSecureHeadersEnabled := False;
  FServerBanner := 'Poseidon/1.0';
  FTCPFastOpen := False;
  FPerCoreAccept := False;
  // FPC defaults to SyncDispatch (inline dispatch on the IO thread). The async
  // worker-pool path relies on FPC 3.3.1 (trunk) function-reference/anonymous-
  // method machinery whose closure codegen and thread-startup ordering are
  // buggy under FPC; SyncDispatch — the v2 high-performance mode — uses neither
  // and runs clean. Delphi keeps async by default. FPC callers can still opt
  // into async via SyncDispatch := False (best-effort under current FPC).
  {$IFDEF FPC}
  FSyncDispatch := True;
  {$ELSE}
  FSyncDispatch := False;
  {$ENDIF}
  FFastPath := False;  // full pipeline by default (upgrades/logging/security)
  FProxyProtocol := ppDisabled;
  FWSManager := TWebSocketManager.Create(
    procedure(AConn: Pointer; const AData: TBytes) begin _EncryptAndSend(AConn, AData); end,
    procedure(AConn: Pointer) begin _CloseConn(AConn); end,
    procedure(AConn: Pointer) begin _PostRecv(AConn); end,
    function(AStatus: Integer; const AContentType: string; const ABody: TBytes;
      AKeepAlive: Boolean; const AExtra: TArray<TPair<string,string>>): TBytes
    begin Result := _BuildResponse(AStatus, AContentType, ABody, AKeepAlive, AExtra); end);
  FH2Manager := THTTP2Manager.Create(
    procedure(AConn: Pointer; const AData: TBytes) begin _EncryptAndSend(AConn, AData); end,
    procedure(AConn: Pointer) begin _CloseConn(AConn); end,
    procedure(AConn: Pointer) begin _PostRecv(AConn); end);
  FDispatcher := TProtocolDispatcher.Create(TServerDispatchAdapter.Create(Self), FFastPath);
  // Create platform IO backend — ONLY {$IFDEF} remaining in HttpServer.
  // Windows: IOCP by default (AcceptEx + SO_UPDATE_ACCEPT_CONTEXT + WSARecv;
  //   loads AcceptEx via WSAIoctl with a static mswsock fallback, so it works
  //   even where a Winsock LSP rejects SIO_GET_EXTENSION_FUNCTION_POINTER). RIO
  //   is opt-in via -DFORCE_RIO: it currently accepts with plain accept(), whose
  //   sockets are NOT RIO-capable, so RIOCreateRequestQueue fails per connection
  //   and every connection is dropped before dispatch (#214/#203). Do not enable
  //   RIO until its accept path is reworked onto AcceptEx + WSA_FLAG_REGISTERED_IO.
  // Linux: try io_uring (kernel 5.1+) first; fall back to epoll silently.
  // Define FORCE_EPOLL to skip the modern backend.
{$IFDEF MSWINDOWS}
  {$IFDEF FORCE_RIO}
  try
    FIOBackend := TRIOBackend.Create;
  except
    on ENotSupportedException do
      FIOBackend := TIOCPBackend.Create;
  end;
  {$ELSE}
  FIOBackend := TIOCPBackend.Create;
  {$ENDIF}
{$ELSE}
  {$IFDEF FORCE_EPOLL}
  FIOBackend := TEpollBackend.Create;
  {$ELSE}
  try
    FIOBackend := TIOUringBackend.Create;
  except
    on ENotSupportedException do
      FIOBackend := TEpollBackend.Create;
  end;
  {$ENDIF}
{$ENDIF}
end;

destructor TPoseidonNativeServer.Destroy;
var
  LPair: TPair<string, Pointer>;
begin
  if FActive then
    try Stop except on E: Exception do; end;
  // Guard: if Stop was skipped (e.g. never called Listen), pool may still exist.
  if Assigned(FRequestPool) then
  begin
    FRequestPool.Shutdown(CShutdownTimeoutMs);
    FreeAndNil(FRequestPool);
  end;
  FreeAndNil(FIdleSweep);
  FreeAndNil(FH2Manager);
  FreeAndNil(FWSManager);
  FreeAndNil(FSSLManager);
  FreeAndNil(FConnManager);
  FreeAndNil(FDrainEvent);
  FreeAndNil(FDispatcher);
  inherited Destroy;
end;

// ===========================================================================
// Shared: WebSocket — upgrade, frame dispatch, handler registration
// ===========================================================================

// Thin shims — delegate to managers
procedure TPoseidonNativeServer._UpgradeToWS(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
  FWSManager.UpgradeToWS(AConn, AReq);
end;

procedure TPoseidonNativeServer._UpgradeToH2C(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
  FH2Manager.UpgradeToH2C(AConn, AReq);
end;

function TPoseidonNativeServer._DispatchWSFrames(AConn: Pointer): Boolean;
begin
  Result := FWSManager.DispatchFrames(AConn);
end;

procedure TPoseidonNativeServer._Log(ALevel: TLogLevel; const AMessage: string);
const
  LEVEL_LABEL: array[TLogLevel] of string = ('DEBUG', 'INFO', 'WARN', 'ERROR');
begin
  if Assigned(FOnLog) then
    FOnLog(ALevel, AMessage)
  else
    Writeln(ErrOutput, '[poseidon][', LEVEL_LABEL[ALevel], '] ', AMessage);
end;

procedure TPoseidonNativeServer.RegisterWSHandler(const APath: string;
  AHandler: TWSMessageCallback);
begin
  FWSManager.RegisterHandler(APath, AHandler);
end;

// ===========================================================================
// Shared: _IdleSweepLoop
// Runs every 1s. For each connection idle longer than FIdleTimeoutMs, calls
// shutdown() on the socket — pending recv/send completes with error and the
// normal worker path tears the connection down via _CloseConn.
// ===========================================================================

// _IdleSweepLoop moved to TIdleSweepManager

// ===========================================================================
// R-1: Platform-agnostic Listen / Stop / _OnNewSocket / _PostRecv / _PostSend
//      / _CloseConn — all IO operations delegated to FIOBackend.
// ===========================================================================

procedure TPoseidonNativeServer.Listen(const AHost: string; APort: Integer;
  AOnRequest: TOnNativeRequest; AOnListen: TProc);
var
  LIOWorkers:  Integer;
  LMinReq:     Integer;
  LMaxReq:     Integer;
  LAcceptN:    Integer;
begin
  if FActive then
    raise Exception.Create('TPoseidonNativeServer: already listening');

  FOnRequest := AOnRequest;
  FActive    := True;
  // Wire H2 manager with request handler and inflight counter
  FH2Manager.OnRequest    := FOnRequest;
  FH2Manager.InFlightCount := @FInFlightCount;
  // Wire WS manager log
  FWSManager.OnLog := FOnLog;

  // IO tier: small fixed pool — handles kernel I/O events only (recv/send).
  // W14: ProcessorCount×2 wins ~50% at c=100; cap at 16 to avoid stack waste.
  // IO workers no longer run blocking handlers, so the cap stays low safely.
  LIOWorkers := Min(Max(CWorkerCountMin, TThread.ProcessorCount * 2),
                    CWorkerCountMax);
  // Per-core accept — one listen socket + accept thread per CPU core
  if FPerCoreAccept then
    LAcceptN := TThread.ProcessorCount
  else
    LAcceptN := 1;
  // Inline dispatch (SyncDispatch) lets the io_uring backend batch SQE submits.
  FIOBackend.SetInlineDispatch(FSyncDispatch);
  FIOBackend.StartListening(AHost, APort, LIOWorkers, FTCPFastOpen,
    TServerIOAdapter.Create(Self), LAcceptN);

  // Request tier: elastic pool — runs blocking handlers (DB, ACBr, etc.).
  // Starts with LMinReq threads (fast debugger startup), grows to LMaxReq.
  LMinReq := FMinWorkerCount;
  if LMinReq <= 0 then LMinReq := LIOWorkers;   // default: same as IO workers
  LMaxReq := FWorkerCount;
  if LMaxReq <= 0 then LMaxReq := CDefaultMaxWorkers;  // default: 200
  FRequestPool := TElasticWorkerPool.Create(LMinReq, LMaxReq,
                    CWorkerIdleTimeoutMs);

  // AOnListen fires here — server is functional (workers + accept running).
  // Sweep is intentionally started after: if AOnListen blocks (e.g. Readln),
  // sweep still starts when Listen() resumes instead of never starting.
  if Assigned(AOnListen) then
    AOnListen();

  // Idle sweep delegated to TIdleSweepManager
  FIdleSweep := TIdleSweepManager.Create(FConnManager, FIOBackend, @FActive);
  FIdleSweep.IdleTimeoutMs := FIdleTimeoutMs;
  FIdleSweep.OnLog := FOnLog;
  FIdleSweep.OnForceClose := _CloseConn;  // #224 mitigation — see IdleSweep.pas
  FIdleSweep.Start;
end;

procedure TPoseidonNativeServer.Stop;
const
  CDrainPollMs = 50;
var
  I:         Integer;
  LConn:     TNativeConn;
  LSnap:     TArray<Pointer>;
  LDeadline: UInt64;
  LNowTick:  UInt64;
  LRemain:   Cardinal;
  LDrained:  Boolean;
begin
  if not FActive then Exit;
  FActive := False;

  // Stop idle sweep
  if Assigned(FIdleSweep) then
    FIdleSweep.Stop;

  // 1) Stop accept + close listen socket.
  FIOBackend.StopAccept;

  // 2) Signal every client socket — pending recv/send complete with error,
  // workers call _CloseConn and remove the conn from FConnList.
  // ResetEvent BEFORE we shutdown any conn so we don't miss the last
  // SetEvent from _CloseConn racing with our reset.
  FDrainEvent.ResetEvent;
  LSnap := FConnManager.Snapshot;
  for I := 0 to High(LSnap) do
  begin
    FIOBackend.ShutdownConn(LSnap[I]);
    TNativeConn(LSnap[I]).Release;  // drop snapshot ref
  end;

  // 3) Drain worker pool — wait for BOTH FInFlightCount and connection count
  // to reach 0. Manual-reset event is signaled by every _CloseConn; we
  // re-check the condition on each wake because a single signal doesn't
  // mean fully drained (single-fire trap: late worker would find a
  // half-destroyed server otherwise).
  LDeadline := TThread.GetTickCount64 + UInt64(FDrainTimeoutMs);
  while (TInterlocked.Read(FInFlightCount) > 0) or (FConnManager.Count > 0) do
  begin
    LNowTick := TThread.GetTickCount64;
    if LNowTick >= LDeadline then Break;
    LRemain := Cardinal(LDeadline - LNowTick);
    if LRemain > CDrainPollMs then LRemain := CDrainPollMs;
    FDrainEvent.WaitFor(LRemain);
    FDrainEvent.ResetEvent;
  end;

  // 4) Drain request pool — pool workers may still be in blocking handlers
  // (including slow TLS handshake). They MUST finish before we free any
  // SSL handle, otherwise a worker mid-handshake dereferences a freed SSL*.
  LDrained := True;
  if Assigned(FRequestPool) then
  begin
    LDrained := FRequestPool.Shutdown(FDrainTimeoutMs);
    if not LDrained then
      _Log(llWarning, '[shutdown] request pool did not drain within ' +
        IntToStr(FDrainTimeoutMs) + 'ms; a slow handler is still running. ' +
        'Leaking straggler SSL handles to avoid use-after-free.');
    FreeAndNil(FRequestPool);
  end;

  FIOBackend.SignalWorkers;
  FIOBackend.JoinWorkers;

  // 5) Only after the pool is fully drained is it safe to release SSL
  // handles on straggler connections (workers stuck in syscall). Freeing
  // SSL before drain = UAF on the SSL context from a lingering handshake.
  FConnManager.Lock.Enter;
  try
    while FConnManager.ConnList.Count > 0 do
    begin
      LConn := TNativeConn(FConnManager.ConnList[0]);
      // #M9: go through Remove (not ConnList.Delete) so the per-IP counter is
      // decremented — otherwise a Stop() with stragglers orphans those IP counts
      // and, after a Stop->Listen, MaxConnectionsPerIP eventually rejects real
      // clients. Lock is recursive so re-entering it here is safe.
      FConnManager.Remove(LConn);
      // #177: only free the SSL handle when the pool fully drained. If a
      // straggler worker is still running, it may dereference SSLHandle in
      // _EncryptAndSend after SSL_free — freeing here would be a UAF. On the
      // timeout path we leak the handle (process is exiting) instead.
      if LDrained and (LConn.SSLHandle <> nil) then
      begin
        FSSLManager.FreeSSL(LConn.SSLHandle);
        LConn.SSLHandle   := nil;
        LConn.SSLReadBio  := nil;
        LConn.SSLWriteBio := nil;
      end;
      FIOBackend.SocketClose(LConn);
      LConn.Release;
    end;
  finally
    FConnManager.Lock.Leave;
  end;

  FreeAndNil(FIdleSweep);
end;

procedure TPoseidonNativeServer._OnNewSocket(ASocket: NativeUInt;
  const ARemoteAddr: string);
// Called by TServerIOAdapter.OnNewConn (which is invoked by the IO backend's
// accept thread). At this point TCP_NODELAY + SO_KEEPALIVE are already set.
var
  LConn: TNativeConn;
begin
  LConn := TNativeConn.Create(ASocket, ARemoteAddr);
  if FSSLManager.SSLEnabled then
  begin
    try
      LConn.SSLHandle := FSSLManager.NewSSL;
      FSSLManager.SetupServerBIOs(LConn.SSLHandle,
        LConn.SSLReadBio, LConn.SSLWriteBio);
    except
      FIOBackend.SocketClose(LConn);  // epoll DEL silently fails (ENOENT) — harmless
      LConn.Release;  // Never registered — drop server ref directly
      Exit;
    end;
  end;
  // Connection limit + per-IP enforcement via TConnectionManager
  if not FConnManager.Admit(LConn) then
  begin
    if LConn.SSLHandle <> nil then FSSLManager.FreeSSL(LConn.SSLHandle);
    FIOBackend.SocketClose(LConn);
    LConn.Release;  // Never registered — drop server ref directly
    Exit;
  end;
  try
    FIOBackend.RegisterConn(LConn);
    FIOBackend.PostRecv(LConn);
  except
    // RegisterConn/PostRecv failure — undo admission and close.
    // Closing the socket is mandatory: skipping it leaks the fd and under
    // DoS exhausts the process fd table.
    FConnManager.Remove(LConn);
    if LConn.SSLHandle <> nil then FSSLManager.FreeSSL(LConn.SSLHandle);
    FIOBackend.SocketClose(LConn);
    LConn.Release;
  end;
end;

procedure TPoseidonNativeServer._PostRecv(AConn: Pointer);
begin
  FIOBackend.PostRecv(AConn);
end;

procedure TPoseidonNativeServer._PostSend(AConn: Pointer; const AResponse: TBytes;
  AActualLen: Integer = 0);
begin
  FIOBackend.PostSend(AConn, AResponse, AActualLen);
end;

procedure TPoseidonNativeServer._CloseConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LIdx:  Integer;
begin
  // Remove from TConnectionManager (handles per-IP unregister). Kept OUTSIDE
  // LConn.Lock so ConnManager.Lock is never nested inside LConn.Lock (no
  // lock-order inversion). Remove also guarantees exactly one caller proceeds.
  LIdx := FConnManager.Remove(AConn);
  if LIdx < 0 then Exit;  // already closed by Stop()
  // #213: serialize teardown (frees SSL* + both BIOs and H2Conn) against a
  // worker still touching them under LConn.Lock. The server ref is still held
  // (Released only below), so the object and its Lock stay alive here.
  LConn.Lock.Enter;
  try
    // Mark closed under the lock so a deferred responder completing from another
    // thread sees it and skips the send instead of writing to a dead socket.
    TInterlocked.Exchange(LConn.Closed, 1);
    if LConn.WSMode = CCMWebSocket then
    begin
      if LConn.WSConn <> nil then
        (LConn.WSConn as TPoseidonWSConn).Invalidate;
      LConn.WSConn := nil;
      // #178: free per-connection fragmentation state so FFragStates does not
      // leak (and no stale entry lingers to collide with a reused pointer).
      if FWSManager <> nil then
        FWSManager.DropConnection(AConn);
    end;
    // #213: do NOT free H2Conn here. _CloseConn can be reached from within the
    // H2 dispatch on the same worker thread (a failed response send calls
    // _EncryptAndSend -> _CloseConn), so freeing TH2Conn now would pull the
    // object out from under _DispatchStream / ProcessData still on the stack,
    // and its finally (FStreams.Remove) would fault on the freed dictionary.
    // TNativeConn.Destroy frees H2Conn instead — it runs only at refcount 0,
    // after the in-flight worker's Release, so no H2Conn method is live.
    if LConn.SSLHandle <> nil then
    begin
      FSSLManager.FreeSSL(LConn.SSLHandle);  // also frees both BIOs
      LConn.SSLHandle   := nil;
      LConn.SSLReadBio  := nil;
      LConn.SSLWriteBio := nil;
    end;
    FIOBackend.SocketClose(LConn);  // platform-specific: epoll DEL + shutdown + close
  finally
    LConn.Lock.Leave;
  end;
  LConn.Release;  // Drop server ref; object lives until all IOCP ops complete
  // R-1: wake the drain event so Stop() can proceed without polling
  if Assigned(FDrainEvent) then FDrainEvent.SetEvent;
end;

initialization
  // Wire Ctx.Defer to the native server's connection machinery. Set once at
  // load; the per-thread deferral context selects the right connection.
  GPoseidonDeferHook := _DeferHook;

finalization
  GPoseidonDeferHook := nil;

end.
