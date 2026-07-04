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
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Math,
  System.DateUtils,
  System.ZLib,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
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
    FOnRequest:       TOnNativeRequest;
    FActive:          Boolean;
    FConnLock:        TCriticalSection;
    FConnList:        TList;
    FInFlightCount:   Int64;
    FIdleTimeoutMs:   Integer;     // 0 = disabled; default 10_000
    FIdleSweepThread: TThread;
    FMaxConnections:      Integer; // 0 = unlimited; default 0
    FMaxConnectionsPerIP: Integer; // 0 = unlimited; default 0
    FPerIPCount:          TDictionary<string, Integer>;
    FSSLEnabled:      Boolean;
    FSSLCtx:          Pointer;     // SSL_CTX* (nil when SSL disabled)
    FCertCtxByHost:   TDictionary<string, Pointer>;  // SNI: hostname → SSL_CTX*
    FWSHandlers:      TDictionary<string, TWSMessageCallback>;
    FWSLock:          TCriticalSection;
    FH2Enabled:       Boolean;         // HTTP/2 via ALPN; requires SSL. Default False.
    FWorkerCount:     Integer;         // 0 = auto max (DEFAULT_MAX_WORKERS = 200)
    FMinWorkerCount:  Integer;         // 0 = auto min (same as IO workers, 4–16)
    FRequestPool:     TElasticWorkerPool; // elastic request-handler pool
    FOnLog:           TOnPoseidonLog;
    FOnRequestLog:    TOnPoseidonRequestLog;  // access log callback; nil = silent
    FMinTLSVersion:   Integer;         // S-6: 0 = library default; $0303 = TLS 1.2
    FMaxRequestSize:  Integer;         // R-4: max accumulated request bytes (default 8MB)
    FMaxHeaderSize:   Integer;         // R-4: max header section bytes (default 64KB)
    FDrainEvent:      TEvent;          // R-1: signaled on each connection close
    FSweepStopEvent:  TEvent;          // signals _IdleSweepLoop to exit immediately
    FDrainTimeoutMs:  Integer;         // R-1: max ms to wait for drain (default 30000)
    FMaxQueueDepth:   Integer;         // R-5: max concurrent in-flight; 0=unlimited
    FMaxWSFrameSize:  Int64;           // R-3: max WS frame payload bytes; 0=unlimited
    FH2MaxConcurrentStreams: Cardinal; // P-1: SETTINGS_MAX_CONCURRENT_STREAMS
    FH2InitialWindowSize:    Cardinal; // P-1: SETTINGS_INITIAL_WINDOW_SIZE
    FSecureHeadersEnabled:   Boolean;  // A-1: inject X-Content-Type-Options etc.
    FServerBanner:    string;          // A-2: Server: header value; '' = omit
    FTCPFastOpen:     Boolean;         // feat: TCP_FASTOPEN — opt-in; graceful no-op on unsupported OS
    FPerCoreAccept:   Boolean;         // #58: per-core accept threads with SO_REUSEPORT
    FSyncDispatch:    Boolean;         // v2-perf: dispatch on IO thread (skip worker pool)
    FProxyProtocol:     TProxyProtocolMode; // PP v1/v2/auto; default ppDisabled
    FOnH2Push:          TOnH2Push; // HTTP/2 server push callback; nil = no push
    // R-1: platform IO backend — holds IOCP/epoll fd, listen socket, workers.
    FIOBackend:       IIOBackend;
    // R-5: protocol dispatcher
    FDispatcher:      TProtocolDispatcher;
    // R-6: injected dependencies (DIP) — nil = use DefaultXxx singleton
    FBufferPool:      IBufferPool;
    FSSLProvider:     ISSLProvider;
    FCompression:     ICompressionProvider;

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
    procedure _SSLFlushWriteBio(AConn: Pointer);
    procedure _IdleSweepLoop;
    function  _AdmitAndRegister(AConn: Pointer): Boolean;
    procedure _UnregisterIP(const ARemoteAddr: string);
    procedure _UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure _UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function  _DispatchWSFrames(AConn: Pointer): Boolean;
    // HTTP/2 helpers — called from _ProcessRecv and used as TH2Conn callbacks
    procedure _H2Send(AConn: Pointer; const AData: TBytes);
    procedure _H2Close(AConn: Pointer);
    procedure _H2OnRequest(const AReq: TH2RequestData;
      var AStatus: Integer; var AContentType: string; var ABody: TBytes;
      var AExtra: TArray<TPair<string,string>>;
      var APushResources: TArray<TPoseidonPushResource>);
    procedure _Log(ALevel: TLogLevel; const AMessage: string);
  public
    // ABufferPool, ASSLProvider, ACompression: nil selects the built-in default
    // (backward-compatible — existing code that calls Create without args unchanged).
    constructor Create(
      ABufferPool:  IBufferPool          = nil;
      ASSLProvider: ISSLProvider         = nil;
      ACompression: ICompressionProvider = nil); overload;
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
    property SSLEnabled:    Boolean read FSSLEnabled;
    // Idle-timeout per connection in milliseconds.
    // Connections with no _ProcessRecv activity for IdleTimeoutMs are shut down.
    // Default 10000 (10s). Set to 0 to disable. Applies during SSL handshake too.
    property IdleTimeoutMs: Integer read FIdleTimeoutMs write FIdleTimeoutMs;
    // Maximum concurrent connections. 0 = unlimited. Defends against DoS
    // by sheer connection flood (each conn reserves 8KB AccumBuf). When
    // reached, _OnNewSocket closes the incoming socket immediately.
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    // Maximum concurrent connections from a single remote IP. 0 = unlimited.
    // Same enforcement as MaxConnections but scoped per-IP.
    property MaxConnectionsPerIP: Integer read FMaxConnectionsPerIP write FMaxConnectionsPerIP;
    // HTTP/2 via ALPN: when True and SSL is configured, the server negotiates "h2"
    // and handles HTTP/2 connections. Must be set before Listen(). Default False.
    property HTTP2Enabled: Boolean read FH2Enabled write FH2Enabled;
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
    property MinTLSVersion: Integer read FMinTLSVersion write FMinTLSVersion;
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
    property MaxWSFrameSize: Int64   read FMaxWSFrameSize  write FMaxWSFrameSize;
    // P-1: HTTP/2 SETTINGS_MAX_CONCURRENT_STREAMS. Default 100.
    property H2MaxConcurrentStreams: Cardinal
      read FH2MaxConcurrentStreams write FH2MaxConcurrentStreams;
    // P-1: HTTP/2 SETTINGS_INITIAL_WINDOW_SIZE. Default 65535.
    property H2InitialWindowSize: Cardinal
      read FH2InitialWindowSize write FH2InitialWindowSize;
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
    // SyncDispatch: execute request handlers directly on IO threads instead of
    // posting to the elastic worker pool. Eliminates thread-transition overhead
    // (~50-100us per request) but BLOCKS the IO thread during handler execution.
    // Only enable when handlers are non-blocking (no DB, no file I/O, no Sleep).
    // Default False (async worker pool).
    property SyncDispatch: Boolean read FSyncDispatch write FSyncDispatch;
    // Proxy Protocol: ppDisabled (default) disables PP processing.
    // ppV1/ppV2: enforce a specific version. ppAuto: detect by signature.
    // Enable only when the server receives connections exclusively from a
    // trusted load-balancer; accepting PP from untrusted sources allows
    // IP spoofing. Must be set before Listen().
    property ProxyProtocol: TProxyProtocolMode
      read FProxyProtocol write FProxyProtocol;
    procedure RegisterWSHandler(const APath: string; AHandler: TWSMessageCallback);
    // HTTP/2 server push callback (RFC 7540 §8.2). When assigned, called before
    // each HTTP/2 response. Populate APushResources to proactively push assets.
    // Only used when HTTP2Enabled = True. nil (default) = no push.
    property OnH2Push: TOnH2Push read FOnH2Push write FOnH2Push;
  end;

implementation

// R-1: platform-specific IO backend (IOCP on Windows, epoll/io_uring on Linux).
// This is the only {$IFDEF} remaining in HttpServer — used solely to select the backend.
{$IFDEF MSWINDOWS}
uses
  Poseidon.Net.IO.IOCP,
  Poseidon.Net.SSL,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.Security,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.HTTP1.Parser;
{$ELSE}
uses
  Poseidon.Net.IO.IOUring,
  Poseidon.Net.IO.Epoll,
  Poseidon.Net.SSL,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.Security,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.HTTP1.Parser;
{$ENDIF}

// ===========================================================================
// Shared constants
// ===========================================================================

const
  MAX_REQUEST_SIZE = 8 * 1024 * 1024;
  RECV_BUF_SIZE    = 32768;  // was 8192 — match CrossSocket; reduz recv() syscalls em payloads maiores
  ACCUM_INITIAL    = 8192;
  WORKER_COUNT_MIN = 4;
  // W15: cap auto-computed IO workers — ProcessorCount*2 on high-core machines
  // (e.g. 100 logical → 200 threads) wasted stack with no throughput gain.
  // IO workers only handle I/O events (recv/send); request handlers run in
  // the elastic TElasticWorkerPool, so this cap can stay low.
  WORKER_COUNT_MAX      = 16;
  // Default ceiling for the elastic request-worker pool. Pools start at
  // min workers (4–16) and grow here only when all workers are busy.
  // 200 × 8MB stack = 1.6GB — well within safe limits.
  DEFAULT_MAX_WORKERS   = 200;
  // Workers above MinWorkerCount self-terminate after this many ms idle.
  WORKER_IDLE_TIMEOUT_MS = 30000;

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
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function  DispatchWSFrames(AConn: Pointer): Boolean;
    procedure InvokeRequest(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtra: TArray<TPair<string,string>>);
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

procedure TServerDispatchAdapter.InvokeRequest(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtra: TArray<TPair<string,string>>);
begin
  AStatus      := 500;
  AContentType := 'application/json';
  ABody        := DefaultErrorBody;
  SetLength(AExtra, 0);
  try
    FServer.FOnRequest(AReq, AStatus, AContentType, ABody, AExtra);
  except
    on E: Exception do
    begin
      AStatus      := 500;
      AContentType := 'application/problem+json';
      ABody        := TEncoding.UTF8.GetBytes(
        '{"type":"about:blank","title":"Internal Server Error",' +
        '"status":500,"detail":"' + E.Message + '"}');
      SetLength(AExtra, 0);
    end;
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

// SNI callback — invoked during TLS handshake when client sends Server Name.
// Looks up the hostname in FCertCtxByHost and switches the SSL_CTX so the
// matching certificate is presented. AArg carries the TPoseidonNativeServer.
function PoseidonSNIServernameCallback(ASSL: Pointer; AD: PInteger; AArg: Pointer): Integer; cdecl;
var
  LServer: TPoseidonNativeServer;
  LHost:   string;
  LCtx:    Pointer;
begin
  Result := SSL_TLSEXT_ERR_NOACK;
  if AArg = nil then Exit;
  LServer := TPoseidonNativeServer(AArg);
  if LServer.FCertCtxByHost = nil then Exit;
  LHost := LowerCase(LServer.FSSLProvider.GetServername(ASSL));
  if LHost = '' then Exit;
  if LServer.FCertCtxByHost.TryGetValue(LHost, LCtx) and (LCtx <> nil) then
  begin
    LServer.FSSLProvider.SetCTXOnSSL(ASSL, LCtx);
    Result := SSL_TLSEXT_ERR_OK;
  end;
end;

procedure TPoseidonNativeServer.ConfigureSSL(const ACertFile, AKeyFile: string);
begin
  if FActive then
    raise Exception.Create('ConfigureSSL must be called before Listen()');
  if FSSLCtx <> nil then
  begin
    FSSLProvider.FreeContext(FSSLCtx);
    FSSLCtx := nil;
  end;
  FSSLProvider.EnsureLoaded;
  FSSLCtx := FSSLProvider.NewContext;
  FSSLProvider.LoadCert(FSSLCtx, ACertFile);
  FSSLProvider.LoadKey(FSSLCtx, AKeyFile);
  FSSLProvider.VerifyKey(FSSLCtx);
  // S-6: enforce minimum TLS version (default TLS 1.2; set MinTLSVersion := 0 to disable)
  FSSLProvider.SetMinVersion(FSSLCtx, FMinTLSVersion);
  // A-4: enable session cache to reduce handshake cost on reconnections
  FSSLProvider.EnableSessionCache(FSSLCtx);
  // Register SNI callback so hostnames registered via AddSSLCert can switch CTX.
  FSSLProvider.SetSNICallback(FSSLCtx, @PoseidonSNIServernameCallback, Self);
  // Register ALPN callback to negotiate "h2" when HTTP2Enabled is True.
  if FH2Enabled then
    FSSLProvider.SetALPN(FSSLCtx, Self);
  FSSLEnabled := True;
end;

procedure TPoseidonNativeServer.ConfigureMTLS(const ACAFile: string);
begin
  if FActive then
    raise Exception.Create('ConfigureMTLS must be called before Listen()');
  if FSSLCtx = nil then
    raise Exception.Create('Call ConfigureSSL before ConfigureMTLS');
  FSSLProvider.ConfigureMTLS(FSSLCtx, ACAFile);
end;

procedure TPoseidonNativeServer.AddSSLCert(const AHostName, ACertFile, AKeyFile: string);
var
  LCtx: Pointer;
begin
  if FActive then
    raise Exception.Create('AddSSLCert must be called before Listen()');
  if FSSLCtx = nil then
    raise Exception.Create('Call ConfigureSSL first to set the default certificate');
  if FCertCtxByHost = nil then
    FCertCtxByHost := TDictionary<string, Pointer>.Create;

  FSSLProvider.EnsureLoaded;
  LCtx := FSSLProvider.NewContext;
  try
    FSSLProvider.LoadCert(LCtx, ACertFile);
    FSSLProvider.LoadKey(LCtx, AKeyFile);
    FSSLProvider.VerifyKey(LCtx);
  except
    FSSLProvider.FreeContext(LCtx);
    raise;
  end;

  // If hostname already had a CTX, free the old one.
  if FCertCtxByHost.ContainsKey(LowerCase(AHostName)) then
    FSSLProvider.FreeContext(FCertCtxByHost[LowerCase(AHostName)]);
  FCertCtxByHost.AddOrSetValue(LowerCase(AHostName), LCtx);
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
  LDecBuf: array[0..RECV_BUF_SIZE - 1] of Byte;
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
      if FH2Enabled and (FSSLProvider.GetSelectedProtocol(LConn.SSLHandle) = 'h2') then
      begin
        LConn.H2Conn := TH2Conn.Create(AConn, _H2Send, _H2Close, _H2OnRequest,
          FH2MaxConcurrentStreams, FH2InitialWindowSize);
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
    LDecN := FSSLProvider.SSLRead(LConn.SSLHandle, @LDecBuf[0], RECV_BUF_SIZE);
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
begin
  // R-5: pre-queue backpressure — reject with 503 before queuing when the
  // number of in-flight (queued + executing) tasks reaches MaxQueueDepth.
  // Force-close the connection (KeepAlive := False) so the client does not
  // immediately retry on the same socket and worsen the overload.
  if (FMaxQueueDepth > 0) and
     (TInterlocked.Read(FInFlightCount) >= Int64(FMaxQueueDepth)) then
  begin
    LResp := BuildHTTPResponse(503, 'text/plain',
      TEncoding.ASCII.GetBytes('Service Unavailable'),
      TNativeConn(AConn).KeepAlive, [],
      FSecureHeadersEnabled, FServerBanner);
    _EncryptAndSend(AConn, LResp);
    // OnSendComplete re-arma recv (keep-alive) ou fecha — não forçar close aqui
    Exit;
  end;

  LCfg.ProxyProtocol        := FProxyProtocol;
  LCfg.MaxRequestSize       := FMaxRequestSize;
  LCfg.MaxHeaderSize        := FMaxHeaderSize;
  LCfg.H2Enabled            := FH2Enabled;
  LCfg.SecureHeadersEnabled := FSecureHeadersEnabled;
  LCfg.ServerBanner         := FServerBanner;
  LCfg.MaxQueueDepth        := 0;           // consumed here; Dispatcher needs no copy
  LCfg.InFlightCount        := nil;         // ditto
  LCfg.Lightweight          := FSyncDispatch;  // v2: lightweight pipeline with sync dispatch

  // v2-perf: SyncDispatch — execute directly on IO thread, skip worker pool.
  // Eliminates thread transition overhead (~50-100us per request).
  if FSyncDispatch then
  begin
    TNativeConn(AConn).LastActivity := Now;
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
  FRequestPool.Post(
    procedure
    begin
      try
        TNativeConn(AConn).LastActivity := Now;  // reset idle-clock at dequeue time
        FDispatcher.Dispatch(AConn, LCfg);
      finally
        TInterlocked.Decrement(FInFlightCount);
        TInterlocked.Decrement(TNativeConn(AConn).InFlightPool);
        TNativeConn(AConn).Release;
      end;
    end);
end;

procedure TPoseidonNativeServer._ProcessRecv(AConn: Pointer;
  const ABuf: PByte; ALen: Cardinal);
var
  LConn:    TNativeConn absolute AConn;
  LAborted: Boolean;
begin
  try
    LConn.LastActivity := Now;   // touched on any inbound bytes — gates idle-sweep
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
      try _CloseConn(AConn); except end;
    end;
  end;
end;

// ===========================================================================
// Shared: connection-limit admission
// ===========================================================================

function ExtractIP(const ARemoteAddr: string): string;
var
  LColonPos: Integer;
begin
  // RemoteAddr format is "IP:Port". For IPv6 it would be "[::1]:Port".
  // Find LAST colon to handle IPv6 too.
  LColonPos := ARemoteAddr.LastDelimiter(':');
  if LColonPos > 0 then
    Result := Copy(ARemoteAddr, 1, LColonPos)
  else
    Result := ARemoteAddr;
end;

function TPoseidonNativeServer._AdmitAndRegister(AConn: Pointer): Boolean;
var
  LConn:  TNativeConn absolute AConn;
  LIP:    string;
  LCount: Integer;
begin
  Result := False;
  LIP := ExtractIP(LConn.RemoteAddr);
  FConnLock.Enter;
  try
    if (FMaxConnections > 0) and (FConnList.Count >= FMaxConnections) then Exit;
    if FMaxConnectionsPerIP > 0 then
    begin
      if FPerIPCount.TryGetValue(LIP, LCount) and
         (LCount >= FMaxConnectionsPerIP) then Exit;
      if not FPerIPCount.TryGetValue(LIP, LCount) then LCount := 0;
      FPerIPCount.AddOrSetValue(LIP, LCount + 1);
    end;
    FConnList.Add(AConn);
    Result := True;
  finally
    FConnLock.Leave;
  end;
end;

procedure TPoseidonNativeServer._UnregisterIP(const ARemoteAddr: string);
var
  LIP:    string;
  LCount: Integer;
begin
  if FMaxConnectionsPerIP <= 0 then Exit;  // not tracking
  LIP := ExtractIP(ARemoteAddr);
  // Caller already holds FConnLock — this method must be invoked under it.
  if FPerIPCount.TryGetValue(LIP, LCount) then
  begin
    if LCount <= 1 then FPerIPCount.Remove(LIP)
    else FPerIPCount.AddOrSetValue(LIP, LCount - 1);
  end;
end;

// ===========================================================================
// Shared: lifecycle (constructor/destructor) — must precede any Listen path
// ===========================================================================

constructor TPoseidonNativeServer.Create(
  ABufferPool:  IBufferPool;
  ASSLProvider: ISSLProvider;
  ACompression: ICompressionProvider);
begin
  inherited Create;
  // R-6: wire injected dependencies; nil = built-in defaults
  if ABufferPool  <> nil then FBufferPool  := ABufferPool
                          else FBufferPool  := DefaultBufferPool;
  if ASSLProvider <> nil then FSSLProvider := ASSLProvider
                          else FSSLProvider := DefaultSSLProvider;
  if ACompression <> nil then FCompression := ACompression
                          else FCompression := DefaultCompressionProvider;
  FIdleTimeoutMs           := 10000;
  FMaxConnections          := 0;
  FMaxConnectionsPerIP     := 0;
  FMinTLSVersion           := TLS1_2_VERSION;
  FMaxRequestSize          := MAX_REQUEST_SIZE;    // R-4: 8MB
  FMaxHeaderSize           := 65536;               // R-4: 64KB
  FDrainTimeoutMs          := 30000;               // R-1: 30s
  FDrainEvent              := TEvent.Create(nil, True, False, '');
  FSweepStopEvent          := TEvent.Create(nil, True, False, '');
  FMaxQueueDepth           := 0;                   // R-5: unlimited
  FMaxWSFrameSize          := 16 * 1024 * 1024;    // R-3: 16MB
  FH2MaxConcurrentStreams  := 100;                 // P-1
  FH2InitialWindowSize     := 65535;               // P-1
  FSecureHeadersEnabled    := False;               // A-1: opt-in
  FServerBanner            := 'Poseidon/1.0';      // A-2
  FTCPFastOpen             := False;               // TCP_FASTOPEN: opt-in
  FPerCoreAccept           := False;               // #58: per-core accept: opt-in
  FSyncDispatch            := False;               // v2-perf: sync dispatch: opt-in
  FProxyProtocol           := ppDisabled;
  FPerIPCount              := TDictionary<string, Integer>.Create;
  FWSHandlers              := TDictionary<string, TWSMessageCallback>.Create;
  FWSLock                  := TCriticalSection.Create;
  // R-5: create the protocol dispatcher with a server-backed adapter
  FDispatcher              := TProtocolDispatcher.Create(TServerDispatchAdapter.Create(Self));
  // R-1: create platform IO backend — ONLY {$IFDEF} remaining in HttpServer.
  // On Linux: try io_uring (kernel 5.1+) first; fall back to epoll silently.
  // Define FORCE_EPOLL to skip io_uring (useful when io_uring is virtualized/slow).
{$IFDEF MSWINDOWS}
  FIOBackend               := TIOCPBackend.Create;
{$ELSE}
  {$IFDEF FORCE_EPOLL}
  FIOBackend               := TEpollBackend.Create;
  {$ELSE}
  try
    FIOBackend             := TIOUringBackend.Create;
  except
    on ENotSupportedException do
      FIOBackend           := TEpollBackend.Create;
  end;
  {$ENDIF}
{$ENDIF}
end;

destructor TPoseidonNativeServer.Destroy;
var
  LPair: TPair<string, Pointer>;
begin
  if FActive then
    try Stop except end;
  // Guard: if Stop was skipped (e.g. never called Listen), pool may still exist.
  if Assigned(FRequestPool) then
  begin
    FRequestPool.Shutdown(1000);
    FreeAndNil(FRequestPool);
  end;
  if FCertCtxByHost <> nil then
  begin
    for LPair in FCertCtxByHost do
      if LPair.Value <> nil then FSSLProvider.FreeContext(LPair.Value);
    FreeAndNil(FCertCtxByHost);
  end;
  if FSSLCtx <> nil then
  begin
    FSSLProvider.FreeContext(FSSLCtx);
    FSSLCtx := nil;
  end;
  FreeAndNil(FPerIPCount);
  FreeAndNil(FWSHandlers);
  FreeAndNil(FWSLock);
  FreeAndNil(FDrainEvent);
  FreeAndNil(FSweepStopEvent);
  FreeAndNil(FDispatcher);  // R-5: releases adapter interface ref
  inherited Destroy;
end;

// ===========================================================================
// Shared: WebSocket — upgrade, frame dispatch, handler registration
// ===========================================================================

procedure TPoseidonNativeServer._UpgradeToWS(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
var
  LConn:    TNativeConn absolute AConn;
  LKey:     string;
  LResp:    TBytes;
  I:        Integer;
  LDeflate: Boolean;
begin
  LKey     := '';
  LDeflate := False;
  for I := 0 to High(AReq.Headers) do
  begin
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Key') then
      LKey := AReq.Headers[I].Value;
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Extensions') and
       (Pos('permessage-deflate', LowerCase(AReq.Headers[I].Value)) > 0) then
      LDeflate := True;
  end;
  if LKey = '' then
  begin
    LResp := _BuildResponse(400, 'text/plain',
      TEncoding.ASCII.GetBytes('Missing Sec-WebSocket-Key'), False, []);
    _EncryptAndSend(AConn, LResp);
    Exit;
  end;

  LResp           := TWebSocketUtils.BuildHandshakeResponse(LKey, LDeflate);
  LConn.WSMode    := CM_WEBSOCKET;
  LConn.WSPath    := AReq.Path;
  LConn.WSDeflate := LDeflate;
  LConn.KeepAlive := True;  // WebSocket connections are always persistent
  LConn.AccumLen  := 0;

  LConn.WSConn := TPoseidonWSConn.Create(
    LConn.RemoteAddr,
    procedure(const AData: TBytes)
    begin
      _EncryptAndSend(AConn, AData);
    end,
    procedure
    begin
      _CloseConn(AConn);
    end,
    LDeflate
  );

  _EncryptAndSend(AConn, LResp);
  _PostRecv(AConn);
end;

// ===========================================================================
// A-5: h2c cleartext upgrade (RFC 7540 §3.2)
// ===========================================================================

procedure TPoseidonNativeServer._UpgradeToH2C(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
// Sends "101 Switching Protocols" and transitions the connection to HTTP/2.
// The initial request (stream 1) is dispatched via the new TH2Conn.
var
  LConn:     TNativeConn absolute AConn;
  LResp:     TBytes;
  LH2Req:    TH2RequestData;   // reused only for Host / ContentType extraction
  I:         Integer;
begin
  // Build 101 Switching Protocols response
  LResp := TEncoding.ASCII.GetBytes(
    'HTTP/1.1 101 Switching Protocols'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Upgrade: h2c'#13#10#13#10);

  // Transition connection to HTTP/2 cleartext
  LConn.H2Conn := TH2Conn.Create(AConn, _H2Send, _H2Close, _H2OnRequest,
    FH2MaxConcurrentStreams, FH2InitialWindowSize);
  LConn.KeepAlive := True;  // HTTP/2 connections are always persistent
  LConn.AccumLen  := 0;

  // Send 101 then server SETTINGS (RFC 7540 §3.2 — SETTINGS must be first frame)
  _EncryptAndSend(AConn, LResp);
  LConn.H2Conn.SendInitialSettings;

  // Dispatch the initial request (stream 1) through the new TH2Conn
  // RFC 7540 §3.2: The initial request on stream 1 is semantically equivalent
  // to the upgrade request; treat it as a completed stream 1 dispatch.
  LH2Req.Host        := '';
  LH2Req.ContentType := '';
  for I := 0 to High(AReq.Headers) do
  begin
    if SameText(AReq.Headers[I].Key, ':authority') or
       SameText(AReq.Headers[I].Key, 'host') then
      LH2Req.Host := AReq.Headers[I].Value;
    if SameText(AReq.Headers[I].Key, 'content-type') then
      LH2Req.ContentType := AReq.Headers[I].Value;
  end;

  // Dispatch the initial upgrade request as h2c stream 1 via TH2Conn
  LConn.H2Conn.DispatchH2CInitialRequest(
    AReq.Method, AReq.Path, AReq.QueryString,
    LConn.RemoteAddr, LH2Req.Host, LH2Req.ContentType,
    AReq.Headers, AReq.RawBody);

  _PostRecv(AConn);
end;

function TPoseidonNativeServer._DispatchWSFrames(AConn: Pointer): Boolean;
var
  LConn:       TNativeConn absolute AConn;
  LFrame:      TWebSocketFrame;
  LConsumed:   Integer;
  LTotal:      Integer;
  LOut:        TBytes;
  LHandler:    TWSMessageCallback;
  LHasHandler: Boolean;
begin
  Result := True;
  LTotal := 0;
  while TWebSocketUtils.ParseFrame(@LConn.AccumBuf[LTotal],
                                    LConn.AccumLen - LTotal,
                                    LFrame, LConsumed) do
  begin
    Inc(LTotal, LConsumed);
    // permessage-deflate: decompress payload when RSV1 is set (RFC 7692 §7.2.2)
    if LConn.WSDeflate then
      TWebSocketUtils.ApplyRXDeflate(LFrame);
    // R-3: reject frames that exceed MaxWSFrameSize (RFC 6455 — protect server memory)
    if (FMaxWSFrameSize > 0) and (Int64(Length(LFrame.Payload)) > FMaxWSFrameSize) then
    begin
      LOut := TWebSocketUtils.CloseFrame(1009);  // 1009 = Message Too Big
      _EncryptAndSend(AConn, LOut);
      _CloseConn(AConn);
      Result := False;
      Exit;
    end;
    case LFrame.Opcode of
      OPCODE_PING:
      begin
        LOut := TWebSocketUtils.PongFrame(LFrame.Payload);
        _EncryptAndSend(AConn, LOut);
      end;
      OPCODE_CLOSE:
      begin
        LOut := TWebSocketUtils.CloseFrame(1000);
        _EncryptAndSend(AConn, LOut);
        if LTotal < LConn.AccumLen then
          Move(LConn.AccumBuf[LTotal], LConn.AccumBuf[0], LConn.AccumLen - LTotal);
        Dec(LConn.AccumLen, LTotal);
        _CloseConn(AConn);
        Result := False;
        Exit;
      end;
      OPCODE_TEXT, OPCODE_BINARY:
      begin
        FWSLock.Enter;
        LHasHandler := FWSHandlers.TryGetValue(LConn.WSPath, LHandler);
        FWSLock.Leave;
        if LHasHandler then
        try
          LHandler(LConn.WSConn, LFrame);
        except
          on E: Exception do
            _Log(llError, '[ws] ' + LConn.RemoteAddr + ' EX: ' + E.Message);
        end;
      end;
    end;
  end;
  if LTotal > 0 then
  begin
    if LTotal < LConn.AccumLen then
      Move(LConn.AccumBuf[LTotal], LConn.AccumBuf[0], LConn.AccumLen - LTotal);
    Dec(LConn.AccumLen, LTotal);
  end;
end;

// ===========================================================================
// HTTP/2 helpers
// ===========================================================================

procedure TPoseidonNativeServer._H2Send(AConn: Pointer; const AData: TBytes);
begin
  _EncryptAndSend(AConn, AData);
end;

procedure TPoseidonNativeServer._H2Close(AConn: Pointer);
begin
  _CloseConn(AConn);
end;

procedure TPoseidonNativeServer._H2OnRequest(const AReq: TH2RequestData;
  var AStatus: Integer; var AContentType: string; var ABody: TBytes;
  var AExtra: TArray<TPair<string,string>>;
  var APushResources: TArray<TPoseidonPushResource>);
var
  LNativeReq: TPoseidonNativeRequest;
  LQPos:      Integer;
  LStatus:    Integer;
  LCT:        string;
  LBody:      TBytes;
  LExtra:     TArray<TPair<string,string>>;
begin
  LQPos := Pos('?', AReq.Path);
  if LQPos > 0 then
  begin
    LNativeReq.Path        := Copy(AReq.Path, 1, LQPos - 1);
    LNativeReq.QueryString := Copy(AReq.Path, LQPos + 1, MaxInt);
  end else
  begin
    LNativeReq.Path        := AReq.Path;
    LNativeReq.QueryString := AReq.QueryString;
  end;
  LNativeReq.Method     := AReq.Method;
  LNativeReq.RawBody    := AReq.Body;
  LNativeReq.RemoteAddr := AReq.RemoteAddr;
  LNativeReq.KeepAlive  := True;
  LNativeReq.Headers    := AReq.Headers;

  LStatus := 500;
  LCT     := 'application/json';
  LBody   := DefaultErrorBody;
  SetLength(LExtra, 0);
  TInterlocked.Increment(FInFlightCount);
  try
    try
      FOnRequest(LNativeReq, LStatus, LCT, LBody, LExtra);
    except
      on E: Exception do
      begin
        LStatus := 500;
        LCT     := 'application/problem+json';
        LBody   := TEncoding.UTF8.GetBytes(
          '{"type":"about:blank","title":"Internal Server Error",' +
          '"status":500,"detail":"' + E.Message + '"}');
        SetLength(LExtra, 0);
      end;
    end;
  finally
    TInterlocked.Decrement(FInFlightCount);
  end;

  AStatus      := LStatus;
  AContentType := LCT;
  ABody        := LBody;
  AExtra       := LExtra;

  // HTTP/2 server push: let the application declare push resources
  if Assigned(FOnH2Push) then
    FOnH2Push(LNativeReq, APushResources);
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
  FWSLock.Enter;
  try
    FWSHandlers.AddOrSetValue(APath, AHandler);
  finally
    FWSLock.Leave;
  end;
end;

// ===========================================================================
// Shared: _IdleSweepLoop
// Runs every 1s. For each connection idle longer than FIdleTimeoutMs, calls
// shutdown() on the socket — pending recv/send completes with error and the
// normal worker path tears the connection down via _CloseConn.
// ===========================================================================

procedure TPoseidonNativeServer._IdleSweepLoop;
const
  SWEEP_INTERVAL_MS = 1000;
var
  LSnap:  TArray<Pointer>;
  I:      Integer;
  LConn:  TNativeConn;
  LNow:   TDateTime;
  LIdle:  Int64;
begin
  while FActive do
  begin
    // FSweepStopEvent is signaled by Stop() — exits immediately instead of
    // waiting up to SWEEP_INTERVAL_MS before seeing FActive = False.
    FSweepStopEvent.WaitFor(SWEEP_INTERVAL_MS);
    if not FActive then Break;
    if FIdleTimeoutMs <= 0 then Continue;

    FConnLock.Enter;
    try
      SetLength(LSnap, FConnList.Count);
      for I := 0 to FConnList.Count - 1 do
      begin
        LSnap[I] := FConnList[I];
        TNativeConn(LSnap[I]).AddRef;  // hold ref so conn cannot be destroyed
      end;                             // between snapshot and processing below
    finally
      FConnLock.Leave;
    end;

    LNow := Now;
    for I := 0 to High(LSnap) do
    begin
      LConn := TNativeConn(LSnap[I]);
      try
        // Skip connections currently being handled by the elastic pool — their
        // LastActivity reflects when the request arrived, not when processing
        // started.  Closing a socket while a pool worker holds a blocking DB
        // call would cause the subsequent WSASend to fail and lose the response.
        if TInterlocked.Add(LConn.InFlightPool, 0) > 0 then Continue;
        LIdle := MilliSecondsBetween(LNow, LConn.LastActivity);
        if LIdle > FIdleTimeoutMs then
        begin
          _Log(llError, '[sweep] idle close: ' + LConn.RemoteAddr +
            ' idle=' + IntToStr(LIdle) + 'ms');
          FIOBackend.ShutdownConn(LSnap[I]);
        end;
      finally
        LConn.Release;  // drop sweep ref acquired in snapshot loop
      end;
    end;
  end;
end;

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
  FConnLock  := TCriticalSection.Create;
  FConnList  := TList.Create;

  // IO tier: small fixed pool — handles kernel I/O events only (recv/send).
  // W14: ProcessorCount×2 wins ~50% at c=100; cap at 16 to avoid stack waste.
  // IO workers no longer run blocking handlers, so the cap stays low safely.
  LIOWorkers := Min(Max(WORKER_COUNT_MIN, TThread.ProcessorCount * 2),
                    WORKER_COUNT_MAX);
  // #58: per-core accept — one listen socket + accept thread per CPU core
  if FPerCoreAccept then
    LAcceptN := TThread.ProcessorCount
  else
    LAcceptN := 1;
  FIOBackend.StartListening(AHost, APort, LIOWorkers, FTCPFastOpen,
    TServerIOAdapter.Create(Self), LAcceptN);

  // Request tier: elastic pool — runs blocking handlers (DB, ACBr, etc.).
  // Starts with LMinReq threads (fast debugger startup), grows to LMaxReq.
  LMinReq := FMinWorkerCount;
  if LMinReq <= 0 then LMinReq := LIOWorkers;   // default: same as IO workers
  LMaxReq := FWorkerCount;
  if LMaxReq <= 0 then LMaxReq := DEFAULT_MAX_WORKERS;  // default: 200
  FRequestPool := TElasticWorkerPool.Create(LMinReq, LMaxReq,
                    WORKER_IDLE_TIMEOUT_MS);

  // AOnListen fires here — server is functional (workers + accept running).
  // Sweep is intentionally started after: if AOnListen blocks (e.g. Readln),
  // sweep still starts when Listen() resumes instead of never starting.
  if Assigned(AOnListen) then
    AOnListen();

  FIdleSweepThread := TThread.CreateAnonymousThread(procedure begin _IdleSweepLoop; end);
  FIdleSweepThread.FreeOnTerminate := False;
  FIdleSweepThread.Start;
end;

procedure TPoseidonNativeServer.Stop;
var
  I:     Integer;
  LConn: TNativeConn;
  LSnap: TArray<Pointer>;
begin
  if not FActive then Exit;
  FActive := False;

  // Wake the idle-sweep thread immediately so WaitFor returns without
  // blocking for up to SWEEP_INTERVAL_MS (1s).
  if Assigned(FSweepStopEvent) then
    FSweepStopEvent.SetEvent;

  FIOBackend.StopAccept;

  if FIdleSweepThread <> nil then
  begin
    FIdleSweepThread.WaitFor;
    FreeAndNil(FIdleSweepThread);
  end;

  // Force every client socket into error state — pending recv/send will
  // complete with an error; workers call _CloseConn naturally and remove
  // the conn from FConnList. Drain then waits for that to happen.
  FConnLock.Enter;
  try
    SetLength(LSnap, FConnList.Count);
    for I := 0 to FConnList.Count - 1 do LSnap[I] := FConnList[I];
  finally
    FConnLock.Leave;
  end;
  for I := 0 to High(LSnap) do
    FIOBackend.ShutdownConn(LSnap[I]);

  // R-1: event-driven drain — no polling; FDrainEvent fires from each _CloseConn
  FDrainEvent.ResetEvent;
  if (TInterlocked.Read(FInFlightCount) > 0) or (FConnList.Count > 0) then
    FDrainEvent.WaitFor(FDrainTimeoutMs);

  // Final cleanup under lock — any stragglers (worker stuck in syscall).
  FConnLock.Enter;
  try
    while FConnList.Count > 0 do
    begin
      LConn := TNativeConn(FConnList[0]);
      FConnList.Delete(0);
      if LConn.SSLHandle <> nil then
      begin
        FSSLProvider.FreeSSL(LConn.SSLHandle);
        LConn.SSLHandle   := nil;
        LConn.SSLReadBio  := nil;
        LConn.SSLWriteBio := nil;
      end;
      FIOBackend.SocketClose(LConn);
      LConn.Release;  // #43: drop server ref; IOCP-op refs drop when workers drain
    end;
  finally
    FConnLock.Leave;
  end;

  // Drain request pool — pool workers may still be in blocking handlers.
  // They will finish, call SendResponse (which may fail on closed sockets),
  // and then exit. IO workers process any resulting send completions while
  // still alive; we join them only after pool workers are done.
  if Assigned(FRequestPool) then
  begin
    FRequestPool.Shutdown(FDrainTimeoutMs);
    FreeAndNil(FRequestPool);
  end;

  FIOBackend.SignalWorkers;
  FIOBackend.JoinWorkers;

  FreeAndNil(FConnList);
  FreeAndNil(FConnLock);
end;

procedure TPoseidonNativeServer._OnNewSocket(ASocket: NativeUInt;
  const ARemoteAddr: string);
// Called by TServerIOAdapter.OnNewConn (which is invoked by the IO backend's
// accept thread). At this point TCP_NODELAY + SO_KEEPALIVE are already set.
var
  LConn: TNativeConn;
begin
  LConn := TNativeConn.Create(ASocket, ARemoteAddr);
  if FSSLEnabled then
  begin
    try
      LConn.SSLHandle := FSSLProvider.NewSSL(FSSLCtx);
      FSSLProvider.SetupServerBIOs(LConn.SSLHandle,
        LConn.SSLReadBio, LConn.SSLWriteBio);
    except
      FIOBackend.SocketClose(LConn);  // epoll DEL silently fails (ENOENT) — harmless
      LConn.Release;  // #43: never registered — drop server ref directly
      Exit;
    end;
  end;
  // Connection limit + per-IP enforcement (atomic under FConnLock)
  if not _AdmitAndRegister(LConn) then
  begin
    if LConn.SSLHandle <> nil then FSSLProvider.FreeSSL(LConn.SSLHandle);
    FIOBackend.SocketClose(LConn);
    LConn.Release;  // #43: never registered — drop server ref directly
    Exit;
  end;
  try
    FIOBackend.RegisterConn(LConn);
    FIOBackend.PostRecv(LConn);  // arm the first recv (io_uring/epoll need this here;
                                 // IOCP no longer calls PostRecv inside RegisterConn)
  except
    // RegisterConn/PostRecv failure — undo admission and close
    FConnLock.Enter;
    try
      FConnList.Remove(LConn);
      _UnregisterIP(LConn.RemoteAddr);
    finally
      FConnLock.Leave;
    end;
    if LConn.SSLHandle <> nil then FSSLProvider.FreeSSL(LConn.SSLHandle);
    LConn.Release;  // #43: associate/PostRecv failed — drop server ref
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
  FConnLock.Enter;
  try
    LIdx := FConnList.IndexOf(AConn);
    if LIdx >= 0 then
    begin
      FConnList.Delete(LIdx);
      _UnregisterIP(LConn.RemoteAddr);
    end;
  finally
    FConnLock.Leave;
  end;
  if LIdx < 0 then Exit;  // already closed by Stop()
  if LConn.WSMode = CM_WEBSOCKET then
  begin
    if LConn.WSConn <> nil then
      (LConn.WSConn as TPoseidonWSConn).Invalidate;
    LConn.WSConn := nil;
  end;
  FreeAndNil(LConn.H2Conn);
  if LConn.SSLHandle <> nil then
  begin
    FSSLProvider.FreeSSL(LConn.SSLHandle);  // also frees both BIOs
    LConn.SSLHandle   := nil;
    LConn.SSLReadBio  := nil;
    LConn.SSLWriteBio := nil;
  end;
  FIOBackend.SocketClose(LConn);  // platform-specific: epoll DEL + shutdown + close
  LConn.Release;  // #43: drop server ref; object lives until all IOCP ops complete
  // R-1: wake the drain event so Stop() can proceed without polling
  if Assigned(FDrainEvent) then FDrainEvent.SetEvent;
end;



end.
