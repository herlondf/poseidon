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
  Poseidon.Net.Metrics,
  Poseidon.Net.ProxyProtocol;

type
  // R-5: TPoseidonNativeServer implements IDispatchCallbacks (non-ref-counted).
  // Types TPoseidonNativeRequest, TOnNativeRequest, TLogLevel, TOnPoseidonLog,
  // TPoseidonRequestLogEvent, TOnPoseidonRequestLog live in Poseidon.Net.Types
  // and are accessible via the transitive uses chain.

  TPoseidonNativeServer = class
  private
    FOnRequest:       TOnNativeRequest;
    FActive:          Boolean;
    FListenSocket:    NativeUInt;
    FAcceptThread:    TThread;
    FWorkers:         TArray<TThread>;
    FConnLock:        TCriticalSection;
    FConnList:        TList;
    FInFlightCount:   Int64;
    FIdleTimeoutMs:   Integer;     // 0 = disabled; default 10_000
    FIdleSweepThread: TThread;
    FCompressionEnabled: Boolean;  // inline gzip negotiation; default False
    FMaxConnections:      Integer; // 0 = unlimited; default 0
    FMaxConnectionsPerIP: Integer; // 0 = unlimited; default 0
    FPerIPCount:          TDictionary<string, Integer>;
    FSSLEnabled:      Boolean;
    FSSLCtx:          Pointer;     // SSL_CTX* (nil when SSL disabled)
    FCertCtxByHost:   TDictionary<string, Pointer>;  // SNI: hostname → SSL_CTX*
    FWSHandlers:      TDictionary<string, TWSMessageCallback>;
    FWSLock:          TCriticalSection;
    FH2Enabled:       Boolean;         // HTTP/2 via ALPN; requires SSL. Default False.
    FWorkerCount:     Integer;         // 0 = auto (ProcessorCount * 2, min 4)
    FOnLog:           TOnPoseidonLog;
    FOnRequestLog:    TOnPoseidonRequestLog;  // access log callback; nil = silent
    FAllowedMethods:  TArray<string>;  // S-1: empty = accept all (default)
    FMinTLSVersion:   Integer;         // S-6: 0 = library default; $0303 = TLS 1.2
    FMaxRequestSize:  Integer;         // R-4: max accumulated request bytes (default 8MB)
    FMaxHeaderSize:   Integer;         // R-4: max header section bytes (default 64KB)
    FDrainEvent:      TEvent;          // R-1: signaled on each connection close
    FDrainTimeoutMs:  Integer;         // R-1: max ms to wait for drain (default 30000)
    FMaxQueueDepth:   Integer;         // R-5: max concurrent in-flight; 0=unlimited
    FMaxWSFrameSize:  Int64;           // R-3: max WS frame payload bytes; 0=unlimited
    FH2MaxConcurrentStreams: Cardinal; // P-1: SETTINGS_MAX_CONCURRENT_STREAMS
    FH2InitialWindowSize:    Cardinal; // P-1: SETTINGS_INITIAL_WINDOW_SIZE
    FSecureHeadersEnabled:   Boolean;  // A-1: inject X-Content-Type-Options etc.
    FServerBanner:    string;          // A-2: Server: header value; '' = omit
    FTCPFastOpen:     Boolean;         // feat: TCP_FASTOPEN — opt-in; graceful no-op on unsupported OS
    FMetrics:         TPoseidonMetrics; // Prometheus metrics; nil when disabled
    FMetricsEnabled:  Boolean;
    FMetricsPath:     string;
    FMetricsAllowedCIDR: string;
    FProxyProtocol:     TProxyProtocolMode; // PP v1/v2/auto; default ppDisabled
    FRateLimitPerIP:    Integer;   // max req/s per IP; 0 = unlimited
    FRateLimitGlobal:   Integer;   // max req/s global; 0 = unlimited
    FRateLimitResponse: Integer;   // HTTP status on limit (default 429)
    FRateLock:          TCriticalSection;
    FRateBuckets:       TDictionary<string, Int64>; // IP → packed (count|window)
    FRateGlobalCount:   Int64;     // global req count in current window
    FRateGlobalWindow:  Int64;     // current global window (tick64 div 1000)
{$IFDEF MSWINDOWS}
    FIocp:          THandle;
{$ELSE}
    FEpollFd:       Integer;
    FShutdownPipe:  array[0..1] of Integer;
{$ENDIF}

    procedure _Accept;
    procedure _OnNewSocket(ASocket: NativeUInt; const ARemoteAddr: string);
    procedure _PostRecv(AConn: Pointer);
    procedure _PostSend(AConn: Pointer; const AResponse: TBytes;
      AActualLen: Integer = 0);
    procedure _CloseConn(AConn: Pointer);
    procedure _WorkerLoop;
    procedure _ProcessRecv(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);
    procedure _ProcessRecvSSL(AConn: Pointer; const ABuf: PByte; ALen: Cardinal;
      out AAborted: Boolean);
    procedure _ProcessRecvPlain(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);
    FDispatcher: TProtocolDispatcher;  // R-5: protocol dispatch strategy

    procedure _DispatchAccumBuf(AConn: Pointer);  // thin shim — builds TDispatchConfig + calls FDispatcher
    function  _TryParseRequest(AConn: Pointer;
      out AReq: TPoseidonNativeRequest; out ABadRequest: Boolean): Boolean;
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
      var AExtra: TArray<TPair<string,string>>);
    procedure _Log(ALevel: TLogLevel; const AMessage: string);
    // Returns True when the request should proceed; False = rate-limited.
    function  _CheckRateLimit(const ARemoteAddr: string): Boolean;
{$IFNDEF MSWINDOWS}
    procedure _DoRecv(AConn: Pointer);
    procedure _FlushSend(AConn: Pointer);
{$ENDIF}
  public
    constructor Create;
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
    // Inline gzip compression: when True, responses > 1KB with text-like
    // Content-Type are compressed if the client sent Accept-Encoding: gzip.
    // Default False (gzip is CPU-expensive — opt-in).
    property CompressionEnabled: Boolean read FCompressionEnabled write FCompressionEnabled;
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
    // Number of worker threads. 0 = auto (max(4, ProcessorCount*2)).
    // For blocking workloads (e.g. DB + ACBr calls), set to the maximum number
    // of concurrent requests you want to support (e.g. 200).
    property WorkerCount: Integer read FWorkerCount write FWorkerCount;
    // Optional log callback. When assigned, all internal errors are routed here.
    // When nil (default), errors are written to ErrOutput.
    property OnLog: TOnPoseidonLog read FOnLog write FOnLog;
    // Optional access-log callback. Fired after every HTTP/1.1 request is
    // dispatched. Receives method, path, status, duration (ms), remote addr,
    // and byte counts. nil (default) = no access logging.
    property OnRequestLog: TOnPoseidonRequestLog
      read FOnRequestLog write FOnRequestLog;
    // S-1: Allowed HTTP methods. When non-empty, any request with a method not in
    // this list is rejected with 405. Empty (default) accepts all methods.
    // Example: Server.AllowedMethods := ['GET', 'POST', 'HEAD'];
    property AllowedMethods: TArray<string> read FAllowedMethods write FAllowedMethods;
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
    // Prometheus metrics endpoint. When MetricsEnabled = True, GET MetricsPath
    // returns metrics in Prometheus exposition format 0.0.4.
    // MetricsEnabled must be set before Listen(). Default False.
    property MetricsEnabled:     Boolean read FMetricsEnabled  write FMetricsEnabled;
    // Path for the metrics endpoint. Default '/metrics'.
    property MetricsPath:        string  read FMetricsPath     write FMetricsPath;
    // Optional CIDR to restrict scraping (e.g. '10.0.0.0/8'). '' = no restriction.
    property MetricsAllowedCIDR: string  read FMetricsAllowedCIDR write FMetricsAllowedCIDR;
    // Read-only access to the metrics object (for custom instrumentation).
    property Metrics: TPoseidonMetrics read FMetrics;
    // Rate limiting (fixed-window counter, 1-second window).
    // RateLimitPerIP: maximum requests per second from a single IP. 0 = unlimited.
    // RateLimitGlobal: maximum requests per second across all clients. 0 = unlimited.
    // RateLimitResponse: HTTP status returned when the limit is exceeded. Default 429.
    property RateLimitPerIP:    Integer read FRateLimitPerIP    write FRateLimitPerIP;
    property RateLimitGlobal:   Integer read FRateLimitGlobal   write FRateLimitGlobal;
    property RateLimitResponse: Integer read FRateLimitResponse write FRateLimitResponse;
    // Proxy Protocol: ppDisabled (default) disables PP processing.
    // ppV1/ppV2: enforce a specific version. ppAuto: detect by signature.
    // Enable only when the server receives connections exclusively from a
    // trusted load-balancer; accepting PP from untrusted sources allows
    // IP spoofing. Must be set before Listen().
    property ProxyProtocol: TProxyProtocolMode
      read FProxyProtocol write FProxyProtocol;
    procedure RegisterWSHandler(const APath: string; AHandler: TWSMessageCallback);
  end;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows,
  Winapi.Winsock2,
  Poseidon.Net.Connection,
  Poseidon.Net.SSL,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.Security,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.HTTP1.Parser;
{$ELSE}
uses
  Posix.SysSocket,
  Posix.NetinetIn,
  Posix.NetinetTcp,
  Posix.ArpaInet,
  Posix.Unistd,
  Posix.Errno,
  Poseidon.Net.Connection,
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
  // W15: cap auto-computed workers — ProcessorCount*2 on high-core machines
  // (e.g. 100 logical → 200 threads) stalled the Delphi debugger at startup
  // and wasted stack memory with no throughput gain. IOCP saturates well below
  // that. Explicit FWorkerCount > 0 bypasses this cap.
  WORKER_COUNT_MAX = 16;

// ===========================================================================
// Shared: _TryParseRequest
// ===========================================================================

function TPoseidonNativeServer._TryParseRequest(AConn: Pointer;
  out AReq: TPoseidonNativeRequest; out ABadRequest: Boolean): Boolean;
// Delegates to Poseidon.Net.HTTP1.Parser.ParseHTTP1Request (R-2).
var
  LConn:    TNativeConn absolute AConn;
  LConsumed: Integer;
begin
  Result := ParseHTTP1Request(
    LConn.AccumBuf, LConn.AccumLen, FMaxHeaderSize, FMaxRequestSize,
    AReq.Method, AReq.Path, AReq.QueryString,
    AReq.Headers, AReq.RawBody, AReq.KeepAlive,
    LConsumed, ABadRequest);
  if Result then
  begin
    AReq.RemoteAddr := LConn.RemoteAddr;
    if LConn.AccumLen > LConsumed then
      Move(LConn.AccumBuf[LConsumed], LConn.AccumBuf[0],
        LConn.AccumLen - LConsumed);
    LConn.AccumLen := LConn.AccumLen - LConsumed;
  end;
end;

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
    if TPoseidonSSL.SSL_Write(LConn.SSLHandle, @AAppData[0], LSendLen) <= 0 then
    begin
      // P-4: release pool buffer before closing connection
      if AActualLen > 0 then
      begin
        LTmp := AAppData;
        TBufferPool.Release(LTmp);
      end;
      _CloseConn(AConn);
      Exit;
    end;
    // P-4: pool buffer fully consumed by SSL_Write — release it before BIO_Read
    if AActualLen > 0 then
    begin
      LTmp := AAppData;
      TBufferPool.Release(LTmp);
    end;
  end;

  LPending := TPoseidonSSL.BIO_Pending(LConn.SSLWriteBio);
  if LPending <= 0 then
  begin
    _PostSend(AConn, nil);
    Exit;
  end;

  SetLength(LEnc, LPending);
  LN := TPoseidonSSL.BIO_Read(LConn.SSLWriteBio, @LEnc[0], LPending);
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
  LPending := TPoseidonSSL.BIO_Pending(LConn.SSLWriteBio);
  if LPending <= 0 then Exit;
  SetLength(LEnc, LPending);
  LN := TPoseidonSSL.BIO_Read(LConn.SSLWriteBio, @LEnc[0], LPending);
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
    function  CheckRateLimit(const ARemoteAddr: string): Boolean;
    procedure InvokeRequest(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtra: TArray<TPair<string,string>>);
    function  GetMetricsBody(const APath, ARemoteAddr: string;
      out ABody: TBytes): Boolean;
    procedure LogRequest(const AEvent: TPoseidonRequestLogEvent);
    procedure AdjustInflight(ADelta: Integer);
    procedure RecordRequest(AStatus: Integer; ADurationMs, ARxBytes, ATxBytes: Int64);
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

function TServerDispatchAdapter.CheckRateLimit(const ARemoteAddr: string): Boolean;
begin
  Result := FServer._CheckRateLimit(ARemoteAddr);
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

function TServerDispatchAdapter.GetMetricsBody(const APath, ARemoteAddr: string;
  out ABody: TBytes): Boolean;
begin
  Result := False;
  if not Assigned(FServer.FMetrics) then Exit;
  ABody  := TEncoding.UTF8.GetBytes(FServer.FMetrics.Render);
  Result := True;
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
  if Assigned(FServer.FMetrics) then FServer.FMetrics.AdjustInflight(ADelta);
end;

procedure TServerDispatchAdapter.RecordRequest(AStatus: Integer;
  ADurationMs, ARxBytes, ATxBytes: Int64);
begin
  if Assigned(FServer.FMetrics) then
    FServer.FMetrics.RecordRequest(AStatus, ADurationMs, ARxBytes, ATxBytes);
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
  LHost := LowerCase(TPoseidonSSL.SSL_GetServername(ASSL));
  if LHost = '' then Exit;
  if LServer.FCertCtxByHost.TryGetValue(LHost, LCtx) and (LCtx <> nil) then
  begin
    TPoseidonSSL.SSL_SetCTX(ASSL, LCtx);
    Result := SSL_TLSEXT_ERR_OK;
  end;
end;

procedure TPoseidonNativeServer.ConfigureSSL(const ACertFile, AKeyFile: string);
begin
  if FActive then
    raise Exception.Create('ConfigureSSL must be called before Listen()');
  if FSSLCtx <> nil then
  begin
    TPoseidonSSL.CTX_Free(FSSLCtx);
    FSSLCtx := nil;
  end;
  TPoseidonSSL.EnsureLoaded;
  FSSLCtx := TPoseidonSSL.CTX_New;
  TPoseidonSSL.CTX_LoadCert(FSSLCtx, ACertFile);
  TPoseidonSSL.CTX_LoadKey(FSSLCtx, AKeyFile);
  TPoseidonSSL.CTX_VerifyKey(FSSLCtx);
  // S-6: enforce minimum TLS version (default TLS 1.2; set MinTLSVersion := 0 to disable)
  TPoseidonSSL.CTX_SetMinVersion(FSSLCtx, FMinTLSVersion);
  // A-4: enable session cache to reduce handshake cost on reconnections
  TPoseidonSSL.CTX_EnableSessionCache(FSSLCtx);
  // Register SNI callback so hostnames registered via AddSSLCert can switch CTX.
  TPoseidonSSL.CTX_SetSNICallback(FSSLCtx, @PoseidonSNIServernameCallback, Self);
  // Register ALPN callback to negotiate "h2" when HTTP2Enabled is True.
  if FH2Enabled then
    TPoseidonSSL.CTX_SetALPN(FSSLCtx, Self);
  FSSLEnabled := True;
end;

procedure TPoseidonNativeServer.ConfigureMTLS(const ACAFile: string);
begin
  if FActive then
    raise Exception.Create('ConfigureMTLS must be called before Listen()');
  if FSSLCtx = nil then
    raise Exception.Create('Call ConfigureSSL before ConfigureMTLS');
  TPoseidonSSL.CTX_ConfigureMTLS(FSSLCtx, ACAFile);
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

  TPoseidonSSL.EnsureLoaded;
  LCtx := TPoseidonSSL.CTX_New;
  try
    TPoseidonSSL.CTX_LoadCert(LCtx, ACertFile);
    TPoseidonSSL.CTX_LoadKey(LCtx, AKeyFile);
    TPoseidonSSL.CTX_VerifyKey(LCtx);
  except
    TPoseidonSSL.CTX_Free(LCtx);
    raise;
  end;

  // If hostname already had a CTX, free the old one.
  if FCertCtxByHost.ContainsKey(LowerCase(AHostName)) then
    TPoseidonSSL.CTX_Free(FCertCtxByHost[LowerCase(AHostName)]);
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
     (TPoseidonSSL.BIO_Write(LConn.SSLReadBio, ABuf, ALen) <= 0) then
  begin
    AAborted := True;
    _CloseConn(AConn);
    Exit;
  end;

  if not LConn.SSLHandshook then
  begin
    LHsRet := TPoseidonSSL.Do_Handshake(LConn.SSLHandle);
    if LHsRet = 1 then
    begin
      LConn.SSLHandshook := True;
      // ALPN: if client negotiated "h2", create TH2Conn for this connection.
      if FH2Enabled and (TPoseidonSSL.SSL_GetSelectedProtocol(LConn.SSLHandle) = 'h2') then
      begin
        LConn.H2Conn := TH2Conn.Create(AConn, _H2Send, _H2Close, _H2OnRequest,
          FH2MaxConcurrentStreams, FH2InitialWindowSize);
        LConn.H2Conn.SendInitialSettings;
        LConn.KeepAlive := True;  // HTTP/2 connections are always persistent
      end;
    end
    else
    begin
      LErr := TPoseidonSSL.Get_Error(LConn.SSLHandle, LHsRet);
      if LErr = SSL_ERROR_WANT_READ then
      begin
        _SSLFlushWriteBio(AConn);
        if TPoseidonSSL.BIO_Pending(LConn.SSLWriteBio) <= 0 then
          _PostRecv(AConn);
        AAborted := True;
        Exit;
      end;
      AAborted := True;
      _CloseConn(AConn);
      Exit;
    end;
    _SSLFlushWriteBio(AConn);
    if TPoseidonSSL.BIO_Pending(LConn.SSLWriteBio) > 0 then
    begin
      // Handshake response is being sent; wait for next recv to continue.
      AAborted := True;
      Exit;
    end;
  end;

  // Drain decrypted application data into AccumBuf
  repeat
    LDecN := TPoseidonSSL.SSL_Read(LConn.SSLHandle, @LDecBuf[0], RECV_BUF_SIZE);
    if LDecN > 0 then
    begin
      if LConn.AccumLen + LDecN > Length(LConn.AccumBuf) then
      begin
        // P-2: grow via pool tier instead of raw SetLength
        LNew := TBufferPool.Acquire(
          Max(LConn.AccumLen + LDecN, Length(LConn.AccumBuf) * 2));
        Move(LConn.AccumBuf[0], LNew[0], LConn.AccumLen);
        TBufferPool.Release(LConn.AccumBuf);
        LConn.AccumBuf := LNew;
      end;
      Move(LDecBuf[0], LConn.AccumBuf[LConn.AccumLen], LDecN);
      Inc(LConn.AccumLen, LDecN);
    end
    else
    begin
      LErr := TPoseidonSSL.Get_Error(LConn.SSLHandle, LDecN);
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
    LNew := TBufferPool.Acquire(
      Max(LConn.AccumLen + Integer(ALen), Length(LConn.AccumBuf) * 2));
    Move(LConn.AccumBuf[0], LNew[0], LConn.AccumLen);
    TBufferPool.Release(LConn.AccumBuf);
    LConn.AccumBuf := LNew;
  end;
  Move(ABuf^, LConn.AccumBuf[LConn.AccumLen], ALen);
  Inc(LConn.AccumLen, ALen);
end;

procedure TPoseidonNativeServer._DispatchAccumBuf(AConn: Pointer);
// R-5: thin shim — builds TDispatchConfig snapshot and delegates to FDispatcher.
var
  LCfg: TDispatchConfig;
begin
  LCfg.ProxyProtocol        := FProxyProtocol;
  LCfg.MaxRequestSize       := FMaxRequestSize;
  LCfg.MaxHeaderSize        := FMaxHeaderSize;
  LCfg.AllowedMethods       := FAllowedMethods;
  LCfg.H2Enabled            := FH2Enabled;
  LCfg.SecureHeadersEnabled := FSecureHeadersEnabled;
  LCfg.ServerBanner         := FServerBanner;
  LCfg.MaxQueueDepth        := FMaxQueueDepth;
  LCfg.InFlightCount        := @FInFlightCount;
  LCfg.RateLimitResponse    := FRateLimitResponse;
  LCfg.CompressionEnabled   := FCompressionEnabled;
  LCfg.MetricsEnabled       := FMetricsEnabled;
  LCfg.MetricsPath          := FMetricsPath;
  LCfg.MetricsAllowedCIDR   := FMetricsAllowedCIDR;
  FDispatcher.Dispatch(AConn, LCfg);
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
// Shared: rate limiting — fixed-window counter, 1-second window
// ===========================================================================

function TPoseidonNativeServer._CheckRateLimit(const ARemoteAddr: string): Boolean;
var
  LNow:    Int64;
  LIP:     string;
  LPacked: Int64;
  LWindow: Int64;
  LCount:  Integer;
begin
  Result := True;  // proceed by default
  if (FRateLimitPerIP <= 0) and (FRateLimitGlobal <= 0) then Exit;

  LNow := Int64(TThread.GetTickCount64) div 1000;  // current 1-second window
  LIP  := ExtractIP(ARemoteAddr);

  FRateLock.Enter;
  try
    // --- Global rate check ---
    if FRateLimitGlobal > 0 then
    begin
      if LNow <> FRateGlobalWindow then
      begin
        FRateGlobalWindow := LNow;
        FRateGlobalCount  := 0;
      end;
      Inc(FRateGlobalCount);
      if FRateGlobalCount > FRateLimitGlobal then
      begin
        Result := False;
        Exit;
      end;
    end;

    // --- Per-IP rate check ---
    if FRateLimitPerIP > 0 then
    begin
      // Pack window (high 32 bits) + count (low 32 bits) into one Int64
      if FRateBuckets.TryGetValue(LIP, LPacked) then
      begin
        LWindow := LPacked shr 32;
        LCount  := Integer(LPacked and $FFFFFFFF);
        if LNow <> LWindow then
        begin
          LWindow := LNow;
          LCount  := 0;
        end;
      end
      else
      begin
        LWindow := LNow;
        LCount  := 0;
      end;
      Inc(LCount);
      FRateBuckets.AddOrSetValue(LIP, (LWindow shl 32) or Int64(LCount));
      if LCount > FRateLimitPerIP then
      begin
        Result := False;
        Exit;
      end;
    end;
  finally
    FRateLock.Leave;
  end;
end;

// ===========================================================================
// Shared: lifecycle (constructor/destructor) — must precede any Listen path
// ===========================================================================

constructor TPoseidonNativeServer.Create;
begin
  inherited Create;
  FIdleTimeoutMs           := 10000;
  FMaxConnections          := 0;
  FMaxConnectionsPerIP     := 0;
  FMinTLSVersion           := TLS1_2_VERSION;
  FMaxRequestSize          := MAX_REQUEST_SIZE;    // R-4: 8MB
  FMaxHeaderSize           := 65536;               // R-4: 64KB
  FDrainTimeoutMs          := 30000;               // R-1: 30s
  FDrainEvent              := TEvent.Create(nil, True, False, '');
  FMaxQueueDepth           := 0;                   // R-5: unlimited
  FMaxWSFrameSize          := 16 * 1024 * 1024;    // R-3: 16MB
  FH2MaxConcurrentStreams  := 100;                 // P-1
  FH2InitialWindowSize     := 65535;               // P-1
  FSecureHeadersEnabled    := False;               // A-1: opt-in
  FServerBanner            := 'Poseidon/1.0';      // A-2
  FTCPFastOpen             := False;               // TCP_FASTOPEN: opt-in
  FMetricsEnabled          := False;
  FMetricsPath             := '/metrics';
  FMetricsAllowedCIDR      := '';
  FProxyProtocol           := ppDisabled;
  FRateLimitPerIP          := 0;
  FRateLimitGlobal         := 0;
  FRateLimitResponse       := 429;
  FRateLock                := TCriticalSection.Create;
  FRateBuckets             := TDictionary<string, Int64>.Create;
  FRateGlobalCount         := 0;
  FRateGlobalWindow        := 0;
  FPerIPCount              := TDictionary<string, Integer>.Create;
  FWSHandlers              := TDictionary<string, TWSMessageCallback>.Create;
  FWSLock                  := TCriticalSection.Create;
  // R-5: create the protocol dispatcher with a server-backed adapter
  FDispatcher              := TProtocolDispatcher.Create(TServerDispatchAdapter.Create(Self));
end;

destructor TPoseidonNativeServer.Destroy;
var
  LPair: TPair<string, Pointer>;
begin
  if FActive then
    try Stop except end;
  if FCertCtxByHost <> nil then
  begin
    for LPair in FCertCtxByHost do
      if LPair.Value <> nil then TPoseidonSSL.CTX_Free(LPair.Value);
    FreeAndNil(FCertCtxByHost);
  end;
  if FSSLCtx <> nil then
  begin
    TPoseidonSSL.CTX_Free(FSSLCtx);
    FSSLCtx := nil;
  end;
  FreeAndNil(FMetrics);
  FreeAndNil(FRateLock);
  FreeAndNil(FRateBuckets);
  FreeAndNil(FPerIPCount);
  FreeAndNil(FWSHandlers);
  FreeAndNil(FWSLock);
  FreeAndNil(FDrainEvent);
  FreeAndNil(FDispatcher);  // R-5: releases adapter interface ref
  inherited Destroy;
end;

// ===========================================================================
// Shared: WebSocket — upgrade, frame dispatch, handler registration
// ===========================================================================

procedure TPoseidonNativeServer._UpgradeToWS(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
var
  LConn:  TNativeConn absolute AConn;
  LKey:   string;
  LResp:  TBytes;
  I:      Integer;
begin
  LKey := '';
  for I := 0 to High(AReq.Headers) do
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Key') then
    begin
      LKey := AReq.Headers[I].Value;
      Break;
    end;
  if LKey = '' then
  begin
    LResp := _BuildResponse(400, 'text/plain',
      TEncoding.ASCII.GetBytes('Missing Sec-WebSocket-Key'), False, []);
    _EncryptAndSend(AConn, LResp);
    Exit;
  end;

  LResp := TWebSocketUtils.BuildHandshakeResponse(LKey);
  LConn.WSMode   := CM_WEBSOCKET;
  LConn.WSPath   := AReq.Path;
  LConn.AccumLen := 0;

  LConn.WSConn := TPoseidonWSConn.Create(
    LConn.RemoteAddr,
    procedure(const AData: TBytes)
    begin
      _EncryptAndSend(AConn, AData);
    end,
    procedure
    begin
      _CloseConn(AConn);
    end
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
  var AExtra: TArray<TPair<string,string>>);
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
    Sleep(SWEEP_INTERVAL_MS);
    if not FActive then Break;
    if FIdleTimeoutMs <= 0 then Continue;

    FConnLock.Enter;
    try
      SetLength(LSnap, FConnList.Count);
      for I := 0 to FConnList.Count - 1 do LSnap[I] := FConnList[I];
    finally
      FConnLock.Leave;
    end;

    LNow := Now;
    for I := 0 to High(LSnap) do
    begin
      LConn := TNativeConn(LSnap[I]);
      LIdle := MilliSecondsBetween(LNow, LConn.LastActivity);
      if LIdle > FIdleTimeoutMs then
{$IFDEF MSWINDOWS}
        shutdown(LConn.Socket, SD_BOTH);
{$ELSE}
        shutdown(LConn.Socket, SHUT_RDWR);
{$ENDIF}
    end;
  end;
end;

// ===========================================================================
// Windows — IOCP implementation
// ===========================================================================

{$IFDEF MSWINDOWS}

function _IocpCreate(FileH, Existing: THandle; Key: NativeUInt;
  Threads: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateIoCompletionPort';

function _IocpGet(Port: THandle; pBytes: PDWORD; pKey: PNativeUInt;
  pOvl: PPointer; Ms: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetQueuedCompletionStatus';

function _IocpPost(Port: THandle; Bytes: DWORD; Key: NativeUInt;
  pOvl: Pointer): BOOL; stdcall;
  external 'kernel32.dll' name 'PostQueuedCompletionStatus';

function _WsaBind(s: TSocket; addr: PSockAddrIn; addrlen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'bind';

function _WsaAccept(s: TSocket; addr: PSockAddrIn; addrlen: PInteger): TSocket; stdcall;
  external 'ws2_32.dll' name 'accept';

function _WsaListen(s: TSocket; backlog: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'listen';

type
  TIocpAction = (iaRecv, iaSend);

  PRecvCtx = ^TRecvCtx;
  TRecvCtx = record
    Ovl:    TOverlapped;            // MUST be first
    Action: TIocpAction;
    Conn:   Pointer;
    WsaBuf: TWsaBuf;
    Data:   array[0..RECV_BUF_SIZE - 1] of Byte;
  end;

  PSendCtx = ^TSendCtx;
  TSendCtx = record
    Ovl:       TOverlapped;         // MUST be first
    Action:    TIocpAction;
    Conn:      Pointer;
    WsaBuf:    TWsaBuf;
    SendBuf:   TBytes;
    ActualLen: Integer;             // P-4: bytes to send; 0 = use Length(SendBuf)
  end;

  PIocpHdr = ^TIocpHdr;
  TIocpHdr = record
    Ovl:    TOverlapped;
    Action: TIocpAction;
    Conn:   Pointer;
  end;

// Note: an attempted pool of PRecvCtx/PSendCtx (W9) measured WORSE than
// AllocMem/New under load — a single TMonitor across 8 workers @ 30k+ ops/s
// becomes a hotter contention point than the FastMM allocator. Kept the
// allocator path; a per-worker (thread-local) pool would be the next
// experiment if pursued.

procedure TPoseidonNativeServer.Listen(const AHost: string; APort: Integer;
  AOnRequest: TOnNativeRequest; AOnListen: TProc);
var
  LAddr:       TSockAddrIn;
  LOne:        Integer;
  LWorkers, I: Integer;
begin
  if FActive then
    raise Exception.Create('TPoseidonNativeServer: already listening');

  var LWsaData: TWSAData;
  if WSAStartup($0202, LWsaData) <> 0 then
    raise Exception.Create('WSAStartup failed');

  FOnRequest := AOnRequest;
  FActive    := True;
  FConnLock  := TCriticalSection.Create;
  FConnList  := TList.Create;

  FIocp := _IocpCreate(INVALID_HANDLE_VALUE, 0, 0, 0);
  if FIocp = 0 then RaiseLastOSError;

  FListenSocket := WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, nil, 0,
    WSA_FLAG_OVERLAPPED);
  if FListenSocket = INVALID_SOCKET then RaiseLastOSError;

  LOne := 1;
  setsockopt(FListenSocket, SOL_SOCKET, SO_REUSEADDR,
    PAnsiChar(@LOne), SizeOf(LOne));

  // TCP_FASTOPEN (RFC 7413) — opt-in; Windows 10 1607+, value = 1 to enable
  if FTCPFastOpen then
    setsockopt(FListenSocket, IPPROTO_TCP, 15 {TCP_FASTOPEN},
      PAnsiChar(@LOne), SizeOf(LOne));
  // Failure is silently ignored: older Windows versions return WSAENOPROTOOPT

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  if (AHost = '0.0.0.0') or (AHost = '') then
    LAddr.sin_addr.S_addr := INADDR_ANY
  else
    LAddr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(AHost)));

  if _WsaBind(FListenSocket, @LAddr, SizeOf(LAddr)) = SOCKET_ERROR then
    RaiseLastOSError;
  if _WsaListen(FListenSocket, SOMAXCONN) = SOCKET_ERROR then
    RaiseLastOSError;

  // W14: tested ProcessorCount × 1 vs × 2 empirically. ×2 wins by ~50% at
  // c=100 — extra workers absorb IOCP wait time while others process.
  if FWorkerCount > 0 then
    LWorkers := FWorkerCount
  else
    LWorkers := Min(Max(WORKER_COUNT_MIN, TThread.ProcessorCount * 2), WORKER_COUNT_MAX);
  SetLength(FWorkers, LWorkers);
  for I := 0 to LWorkers - 1 do
    FWorkers[I] := TThread.CreateAnonymousThread(procedure begin _WorkerLoop; end);
  for I := 0 to LWorkers - 1 do
  begin
    FWorkers[I].FreeOnTerminate := False;
    FWorkers[I].Start;
  end;

  FAcceptThread := TThread.CreateAnonymousThread(procedure begin _Accept; end);
  FAcceptThread.FreeOnTerminate := False;
  FAcceptThread.Start;

  if FMetricsEnabled then
    FMetrics := TPoseidonMetrics.Create;

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
begin
  if not FActive then Exit;
  FActive := False;

  closesocket(FListenSocket);
  FListenSocket := INVALID_SOCKET;

  FAcceptThread.WaitFor;
  FreeAndNil(FAcceptThread);

  if FIdleSweepThread <> nil then
  begin
    FIdleSweepThread.WaitFor;
    FreeAndNil(FIdleSweepThread);
  end;

  // Force every client socket into error state — pending recv/send will
  // complete with WSAESHUTDOWN, workers call _CloseConn naturally and remove
  // the conn from FConnList. Drain then waits for that to happen.
  FConnLock.Enter;
  try
    for I := 0 to FConnList.Count - 1 do
      shutdown(TNativeConn(FConnList[I]).Socket, SD_BOTH);
  finally
    FConnLock.Leave;
  end;

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
        TPoseidonSSL.Free_SSL(LConn.SSLHandle);
        LConn.SSLHandle   := nil;
        LConn.SSLReadBio  := nil;
        LConn.SSLWriteBio := nil;
      end;
      closesocket(LConn.Socket);
      LConn.Free;
    end;
  finally
    FConnLock.Leave;
  end;

  for I := 0 to High(FWorkers) do
    _IocpPost(FIocp, 0, 0, nil);
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  SetLength(FWorkers, 0);

  CloseHandle(FIocp);
  FIocp := 0;
  FreeAndNil(FConnList);
  FreeAndNil(FConnLock);
  WSACleanup;
end;

procedure TPoseidonNativeServer._Accept;
var
  LClient:   TSocket;
  LAddr:     TSockAddrIn;
  LAddrLen:  Integer;
  LRemoteIP: AnsiString;
begin
  while FActive do
  begin
    FillChar(LAddr, SizeOf(LAddr), 0);
    LAddrLen := SizeOf(LAddr);
    LClient := _WsaAccept(FListenSocket, @LAddr, @LAddrLen);
    if LClient = INVALID_SOCKET then Break;
    LRemoteIP := inet_ntoa(LAddr.sin_addr);
    try
      _OnNewSocket(LClient,
        string(LRemoteIP) + ':' + IntToStr(ntohs(LAddr.sin_port)));
    except
      closesocket(LClient);
    end;
  end;
end;

procedure TPoseidonNativeServer._OnNewSocket(ASocket: NativeUInt;
  const ARemoteAddr: string);
var
  LOne:  Integer;
  LConn: TNativeConn;
begin
  LOne := 1;
  setsockopt(TSocket(ASocket), IPPROTO_TCP, TCP_NODELAY,
    PAnsiChar(@LOne), SizeOf(LOne));
  setsockopt(TSocket(ASocket), SOL_SOCKET, SO_KEEPALIVE,
    PAnsiChar(@LOne), SizeOf(LOne));

  if _IocpCreate(THandle(ASocket), FIocp, 0, 0) = 0 then
  begin
    closesocket(TSocket(ASocket));
    Exit;
  end;
  LConn := TNativeConn.Create(TSocket(ASocket), ARemoteAddr);
  if FSSLEnabled then
  begin
    try
      LConn.SSLHandle := TPoseidonSSL.New_SSL(FSSLCtx);
      TPoseidonSSL.Setup_Server(LConn.SSLHandle,
        LConn.SSLReadBio, LConn.SSLWriteBio);
    except
      LConn.Free;
      closesocket(TSocket(ASocket));
      Exit;
    end;
  end;
  // Connection limit + per-IP enforcement (atomic under FConnLock)
  if not _AdmitAndRegister(LConn) then
  begin
    if LConn.SSLHandle <> nil then TPoseidonSSL.Free_SSL(LConn.SSLHandle);
    LConn.Free;
    closesocket(TSocket(ASocket));
    Exit;
  end;
  if Assigned(FMetrics) then FMetrics.AdjustConnections(1);
  _PostRecv(LConn);
end;

procedure TPoseidonNativeServer._PostRecv(AConn: Pointer);
var
  LConn:  TNativeConn absolute AConn;
  LCtx:   PRecvCtx;
  LFlags: DWORD;
  LBytes: DWORD;
  LRes:   Integer;
begin
  LCtx := AllocMem(SizeOf(TRecvCtx));        // W9 reverted: FastMM is fast enough
  LCtx^.Action     := iaRecv;
  LCtx^.Conn       := AConn;
  LCtx^.WsaBuf.len := RECV_BUF_SIZE;
  LCtx^.WsaBuf.buf := @LCtx^.Data[0];
  LFlags := 0;
  LBytes := 0;

  LRes := WSARecv(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, LFlags,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if (LRes = SOCKET_ERROR) and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    FreeMem(LCtx);
    _CloseConn(AConn);
  end;
end;

procedure TPoseidonNativeServer._PostSend(AConn: Pointer; const AResponse: TBytes;
  AActualLen: Integer = 0);
var
  LConn:    TNativeConn absolute AConn;
  LCtx:     PSendCtx;
  LBytes:   DWORD;
  LRes:     Integer;
  LSendLen: Integer;
begin
  // P-4: AActualLen > 0 when AResponse is a pool buffer larger than the response.
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AResponse);

  if LSendLen = 0 then
  begin
    if LConn.KeepAlive then _PostRecv(AConn)
    else _CloseConn(AConn);
    Exit;
  end;

  New(LCtx);
  FillChar(LCtx^.Ovl, SizeOf(TOverlapped), 0);  // Ovl.hEvent must be 0 for IOCP
  LCtx^.Action     := iaSend;
  LCtx^.Conn       := AConn;
  LCtx^.SendBuf    := AResponse;
  LCtx^.ActualLen  := AActualLen;
  LCtx^.WsaBuf.len := ULONG(LSendLen);
  LCtx^.WsaBuf.buf := @LCtx^.SendBuf[0];
  LBytes := 0;

  LRes := WSASend(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, 0,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if (LRes = SOCKET_ERROR) and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    // P-4: return pool buffer before disposing context
    TBufferPool.Release(LCtx^.SendBuf);
    Dispose(LCtx);
    _CloseConn(AConn);
  end;
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
  if Assigned(FMetrics) then FMetrics.AdjustConnections(-1);
  if LConn.WSMode = CM_WEBSOCKET then
  begin
    if LConn.WSConn <> nil then
      (LConn.WSConn as TPoseidonWSConn).Invalidate;
    LConn.WSConn := nil;
  end;
  FreeAndNil(LConn.H2Conn);
  if LConn.SSLHandle <> nil then
  begin
    TPoseidonSSL.Free_SSL(LConn.SSLHandle);  // also frees both BIOs
    LConn.SSLHandle   := nil;
    LConn.SSLReadBio  := nil;
    LConn.SSLWriteBio := nil;
  end;
  // R-6: TCP half-close — FIN before RST so the client receives the last bytes
  shutdown(LConn.Socket, SD_SEND);
  closesocket(LConn.Socket);
  LConn.Free;
  // R-1: wake the drain event so Stop() can proceed without polling
  if Assigned(FDrainEvent) then FDrainEvent.SetEvent;
end;

procedure TPoseidonNativeServer._WorkerLoop;
var
  LBytes: DWORD;
  LKey:   NativeUInt;
  LOvl:   Pointer;
  LHdr:   PIocpHdr;
  LConn:  TNativeConn;
  LOK:    BOOL;
begin
  while True do
  begin
    LOvl   := nil;
    LBytes := 0;
    LKey   := 0;
    LOK    := _IocpGet(FIocp, @LBytes, @LKey, @LOvl, INFINITE);

    if LOvl = nil then Break;  // shutdown pill

    try
      LHdr  := PIocpHdr(LOvl);
      LConn := TNativeConn(LHdr^.Conn);

      if (not LOK) or (LBytes = 0) then
      begin
        case LHdr^.Action of
          iaRecv: FreeMem(PRecvCtx(LOvl));
          iaSend:
          begin
            // P-4: return pool buffer (no-op for non-pool buffers)
            TBufferPool.Release(PSendCtx(LOvl)^.SendBuf);
            Dispose(PSendCtx(LOvl));
          end;
        end;
        _CloseConn(LConn);
        Continue;
      end;

      case LHdr^.Action of
        iaRecv:
        begin
          _ProcessRecv(LConn, @PRecvCtx(LOvl)^.Data[0], LBytes);
          FreeMem(PRecvCtx(LOvl));
        end;
        iaSend:
        begin
          // P-4: return pool buffer (no-op for non-pool buffers)
          TBufferPool.Release(PSendCtx(LOvl)^.SendBuf);
          Dispose(PSendCtx(LOvl));
          // During TLS handshake we keep the connection alive regardless of
          // HTTP KeepAlive — re-arm recv for the next handshake message.
          if (LConn.SSLHandle <> nil) and not LConn.SSLHandshook then
            _PostRecv(LConn)
          else if LConn.KeepAlive then
          begin
            if LConn.AccumLen > 0 then
              _ProcessRecv(LConn, nil, 0)
            else
              _PostRecv(LConn);
          end
          else _CloseConn(LConn);
        end;
      end;
    except
      on E: Exception do
        _Log(llError, '[iocp] WORKER_EX [' + E.ClassName + ']: ' + E.Message);
    end;
  end;
end;

// ===========================================================================
// Linux — epoll implementation
// ===========================================================================

{$ELSE}

const
  MAX_EVENTS   = 256;  // was 64 — batch maior reduz syscalls epoll_wait sob 100+ conns
  // epoll(7) event flags
  EPOLLIN      = $00000001;
  EPOLLOUT     = $00000004;
  EPOLLERR     = $00000008;
  EPOLLHUP     = $00000010;
  EPOLLONESHOT = Integer($40000000);
  // epoll_ctl operations
  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  EPOLL_CTL_MOD = 3;
  // epoll_create1 flags
  EPOLL_CLOEXEC  = $80000;
  // setsockopt — SO_REUSEPORT (Linux 3.9+): kernel distribui accepts entre workers
  SO_REUSEPORT   = 15;

type
  // Union: ptr/fd/u32/u64 — largest field is Pointer (8 bytes on 64-bit).
  epoll_data_t = record
    case Integer of
      0: (ptr: Pointer);
      1: (fd:  Integer);
      2: (u32: UInt32);
      3: (u64: UInt64);
  end;
  // Packed to match Linux ABI: 4 bytes events + 8 bytes data = 12 bytes.
  epoll_event = packed record
    events: UInt32;
    data:   epoll_data_t;
  end;

function epoll_create1(flags: Integer): Integer; cdecl;
  external 'c' name 'epoll_create1';
function epoll_ctl(epfd, op, fd: Integer; event: Pointer): Integer; cdecl;
  external 'c' name 'epoll_ctl';
function epoll_wait(epfd: Integer; events: Pointer; maxevents, timeout: Integer): Integer; cdecl;
  external 'c' name 'epoll_wait';

// accept4, pipe, read, write, close — declared explicitly to avoid conflicts
// with Pascal built-in identifiers and Delphi RTL renames.
function _LinuxAccept4(sockfd: Integer; addr: Pointer; addrlen: Pointer;
  flags: Integer): Integer; cdecl; external 'c' name 'accept4';
function _LinuxPipe(pipefd: PInteger): Integer; cdecl;
  external 'c' name 'pipe';
function _LinuxRead(fd: Integer; buf: Pointer; count: NativeUInt): NativeInt; cdecl;
  external 'c' name 'read';
function _LinuxWrite(fd: Integer; buf: Pointer; count: NativeUInt): NativeInt; cdecl;
  external 'c' name 'write';
function _LinuxClose(fd: Integer): Integer; cdecl;
  external 'c' name 'close';

// Socket functions — raw declarations to avoid type mismatch with Posix unit bindings.
function _LinuxSocket(domain, typ, protocol: Integer): Integer; cdecl;
  external 'c' name 'socket';
function _LinuxBind(sockfd: Integer; addr: Pointer; addrlen: UInt32): Integer; cdecl;
  external 'c' name 'bind';
function _LinuxListen(sockfd, backlog: Integer): Integer; cdecl;
  external 'c' name 'listen';
function _LinuxSetsockopt(sockfd, level, optname: Integer; optval: Pointer; optlen: UInt32): Integer; cdecl;
  external 'c' name 'setsockopt';
function _LinuxRecv(sockfd: Integer; buf: Pointer; len: NativeUInt; flags: Integer): NativeInt; cdecl;
  external 'c' name 'recv';
function _LinuxSend(sockfd: Integer; buf: Pointer; len: NativeUInt; flags: Integer): NativeInt; cdecl;
  external 'c' name 'send';

// ---------------------------------------------------------------------------
// Listen
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer.Listen(const AHost: string; APort: Integer;
  AOnRequest: TOnNativeRequest; AOnListen: TProc);
var
  LAddr:       sockaddr_in;
  LOne:        Integer;
  LWorkers, I: Integer;
  LEv:         epoll_event;
  LPipe:       array[0..1] of Integer;
begin
  if FActive then
    raise Exception.Create('TPoseidonNativeServer: already listening');

  FOnRequest := AOnRequest;
  FActive    := True;
  FConnLock  := TCriticalSection.Create;
  FConnList  := TList.Create;

  // Shutdown pipe: read-end [0] registered in epoll with nil sentinel.
  if _LinuxPipe(@LPipe[0]) < 0 then
    raise Exception.Create('pipe() failed: ' + IntToStr(GetLastError));
  FShutdownPipe[0] := LPipe[0];
  FShutdownPipe[1] := LPipe[1];

  FEpollFd := epoll_create1(EPOLL_CLOEXEC);
  if FEpollFd < 0 then
    raise Exception.Create('epoll_create1 failed: ' + IntToStr(GetLastError));

  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events   := EPOLLIN;
  LEv.data.ptr := nil;  // shutdown sentinel
  epoll_ctl(FEpollFd, EPOLL_CTL_ADD, FShutdownPipe[0], @LEv);

  FListenSocket := NativeUInt(_LinuxSocket(AF_INET, SOCK_STREAM or SOCK_CLOEXEC, 0));
  if Integer(FListenSocket) < 0 then
    raise Exception.Create('socket() failed: ' + IntToStr(GetLastError));

  LOne := 1;
  _LinuxSetsockopt(Integer(FListenSocket), SOL_SOCKET, SO_REUSEADDR,
    @LOne, SizeOf(LOne));
  _LinuxSetsockopt(Integer(FListenSocket), SOL_SOCKET, SO_REUSEPORT,
    @LOne, SizeOf(LOne));  // kernel load-balances accepts entre worker threads

  // TCP_FASTOPEN (RFC 7413) — opt-in; Linux 3.7+; value = SYN queue length
  // Requires /proc/sys/net/ipv4/tcp_fastopen to have bit 2 set (server mode).
  // Failure (ENOPROTOOPT on older kernels) is silently ignored.
  if FTCPFastOpen then
    _LinuxSetsockopt(Integer(FListenSocket), IPPROTO_TCP, 23 {TCP_FASTOPEN},
      @LOne, SizeOf(LOne));

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  if (AHost = '0.0.0.0') or (AHost = '') then
    LAddr.sin_addr.s_addr := INADDR_ANY
  else
    LAddr.sin_addr.s_addr := inet_addr(MarshaledAString(AnsiString(AHost)));

  if _LinuxBind(Integer(FListenSocket), @LAddr, SizeOf(LAddr)) < 0 then
    raise Exception.Create('bind() failed: ' + IntToStr(GetLastError));

  if _LinuxListen(Integer(FListenSocket), SOMAXCONN) < 0 then
    raise Exception.Create('listen() failed: ' + IntToStr(GetLastError));

  if FWorkerCount > 0 then
    LWorkers := FWorkerCount
  else
    LWorkers := Min(Max(WORKER_COUNT_MIN, TThread.ProcessorCount * 2), WORKER_COUNT_MAX);
  SetLength(FWorkers, LWorkers);
  for I := 0 to LWorkers - 1 do
    FWorkers[I] := TThread.CreateAnonymousThread(procedure begin _WorkerLoop; end);
  for I := 0 to LWorkers - 1 do
  begin
    FWorkers[I].FreeOnTerminate := False;
    FWorkers[I].Start;
  end;

  FAcceptThread := TThread.CreateAnonymousThread(procedure begin _Accept; end);
  FAcceptThread.FreeOnTerminate := False;
  FAcceptThread.Start;

  if FMetricsEnabled then
    FMetrics := TPoseidonMetrics.Create;

  // AOnListen fires here — server is functional (workers + accept running).
  // Sweep is intentionally started after: if AOnListen blocks (e.g. Readln),
  // sweep still starts when Listen() resumes instead of never starting.
  if Assigned(AOnListen) then
    AOnListen();

  FIdleSweepThread := TThread.CreateAnonymousThread(procedure begin _IdleSweepLoop; end);
  FIdleSweepThread.FreeOnTerminate := False;
  FIdleSweepThread.Start;
end;

// ---------------------------------------------------------------------------
// Stop
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer.Stop;
var
  I:      Integer;
  LConn:  TNativeConn;
  LDummy: Byte;
begin
  if not FActive then Exit;
  FActive := False;

  _LinuxClose(Integer(FListenSocket));
  FListenSocket := NativeUInt(-1);

  FAcceptThread.WaitFor;
  FreeAndNil(FAcceptThread);

  if FIdleSweepThread <> nil then
  begin
    FIdleSweepThread.WaitFor;
    FreeAndNil(FIdleSweepThread);
  end;

  // Force every client socket into error state — pending recv/send completes
  // with -1/EBADF and workers call _CloseConn naturally.
  FConnLock.Enter;
  try
    for I := 0 to FConnList.Count - 1 do
      shutdown(TNativeConn(FConnList[I]).Socket, SHUT_RDWR);
  finally
    FConnLock.Leave;
  end;

  // R-1: event-driven drain — no polling; FDrainEvent fires from each _CloseConn
  FDrainEvent.ResetEvent;
  if (TInterlocked.Read(FInFlightCount) > 0) or (FConnList.Count > 0) then
    FDrainEvent.WaitFor(FDrainTimeoutMs);

  // Final cleanup under lock — any stragglers.
  FConnLock.Enter;
  try
    while FConnList.Count > 0 do
    begin
      LConn := TNativeConn(FConnList[0]);
      FConnList.Delete(0);
      if LConn.SSLHandle <> nil then
      begin
        TPoseidonSSL.Free_SSL(LConn.SSLHandle);
        LConn.SSLHandle   := nil;
        LConn.SSLReadBio  := nil;
        LConn.SSLWriteBio := nil;
      end;
      epoll_ctl(FEpollFd, EPOLL_CTL_DEL, LConn.Socket, nil);
      _LinuxClose(LConn.Socket);
      LConn.Free;
    end;
  finally
    FConnLock.Leave;
  end;

  // Write one byte per worker — level-triggered sentinel wakes each one.
  LDummy := 0;
  for I := 0 to High(FWorkers) do
    _LinuxWrite(FShutdownPipe[1], @LDummy, 1);

  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  SetLength(FWorkers, 0);

  _LinuxClose(FEpollFd);
  _LinuxClose(FShutdownPipe[0]);
  _LinuxClose(FShutdownPipe[1]);
  FEpollFd         := -1;
  FShutdownPipe[0] := -1;
  FShutdownPipe[1] := -1;

  FreeAndNil(FConnList);
  FreeAndNil(FConnLock);
end;

// ---------------------------------------------------------------------------
// Accept thread — blocking accept4 produces non-blocking client fds
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._Accept;
var
  LFd:      Integer;
  LAddr:    sockaddr_in;
  LAddrLen: Cardinal;  // socklen_t
  LIP:      AnsiString;
begin
  while FActive do
  begin
    FillChar(LAddr, SizeOf(LAddr), 0);
    LAddrLen := SizeOf(LAddr);
    LFd := _LinuxAccept4(Integer(FListenSocket), @LAddr, @LAddrLen,
      SOCK_NONBLOCK or SOCK_CLOEXEC);
    if LFd < 0 then
    begin
      if GetLastError = EINTR then Continue;
      Break;
    end;
    LIP := AnsiString(inet_ntoa(LAddr.sin_addr));
    try
      _OnNewSocket(NativeUInt(LFd),
        string(LIP) + ':' + IntToStr(ntohs(LAddr.sin_port)));
    except
      _LinuxClose(LFd);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// New connection setup
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._OnNewSocket(ASocket: NativeUInt;
  const ARemoteAddr: string);
var
  LOne:  Integer;
  LConn: TNativeConn;
  LEv:   epoll_event;
begin
  LOne := 1;
  _LinuxSetsockopt(Integer(ASocket), IPPROTO_TCP, TCP_NODELAY,
    @LOne, SizeOf(LOne));
  _LinuxSetsockopt(Integer(ASocket), SOL_SOCKET, SO_KEEPALIVE,
    @LOne, SizeOf(LOne));

  LConn := TNativeConn.Create(Integer(ASocket), ARemoteAddr);
  if FSSLEnabled then
  begin
    try
      LConn.SSLHandle := TPoseidonSSL.New_SSL(FSSLCtx);
      TPoseidonSSL.Setup_Server(LConn.SSLHandle,
        LConn.SSLReadBio, LConn.SSLWriteBio);
    except
      LConn.Free;
      _LinuxClose(Integer(ASocket));
      Exit;
    end;
  end;
  // Connection limit + per-IP enforcement (atomic under FConnLock)
  if not _AdmitAndRegister(LConn) then
  begin
    if LConn.SSLHandle <> nil then TPoseidonSSL.Free_SSL(LConn.SSLHandle);
    LConn.Free;
    _LinuxClose(Integer(ASocket));
    Exit;
  end;
  if Assigned(FMetrics) then FMetrics.AdjustConnections(1);

  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events   := EPOLLIN or EPOLLONESHOT;
  LEv.data.ptr := LConn;
  epoll_ctl(FEpollFd, EPOLL_CTL_ADD, Integer(ASocket), @LEv);
end;

// ---------------------------------------------------------------------------
// _PostRecv — re-arm EPOLLIN|EPOLLONESHOT for next read event
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._PostRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv:   epoll_event;
begin
  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events   := EPOLLIN or EPOLLONESHOT;
  LEv.data.ptr := AConn;
  epoll_ctl(FEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
end;

// ---------------------------------------------------------------------------
// _PostSend — store response bytes, kick off non-blocking send loop
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._PostSend(AConn: Pointer; const AResponse: TBytes;
  AActualLen: Integer = 0);
var
  LConn:    TNativeConn absolute AConn;
  LSendLen: Integer;
begin
  // P-4: AActualLen > 0 when AResponse is a pool buffer larger than the response.
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AResponse);

  if LSendLen = 0 then
  begin
    if LConn.KeepAlive then _PostRecv(AConn)
    else _CloseConn(AConn);
    Exit;
  end;
  LConn.PendingSend       := AResponse;
  LConn.PendingSendActual := AActualLen;  // 0 = use full Length(PendingSend)
  LConn.SentBytes         := 0;
  _FlushSend(AConn);
end;

// ---------------------------------------------------------------------------
// _FlushSend — send() loop; arms EPOLLOUT on EAGAIN (partial send)
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._FlushSend(AConn: Pointer);
var
  LConn:      TNativeConn absolute AConn;
  LRemain:    Integer;
  LN:         NativeInt;
  LEv:        epoll_event;
  LTotalSend: Integer;
begin
  // P-4: use PendingSendActual when set (pool buffer with only first N bytes valid)
  LTotalSend := LConn.PendingSendActual;
  if LTotalSend = 0 then LTotalSend := Length(LConn.PendingSend);

  while LConn.SentBytes < LTotalSend do
  begin
    LRemain := LTotalSend - LConn.SentBytes;
    LN := _LinuxSend(LConn.Socket,
      @LConn.PendingSend[LConn.SentBytes], LRemain, MSG_NOSIGNAL);
    if LN > 0 then
      Inc(LConn.SentBytes, LN)
    else
    begin
      if GetLastError = EAGAIN then
      begin
        // Kernel send buffer full — resume when EPOLLOUT fires.
        FillChar(LEv, SizeOf(LEv), 0);
        LEv.events   := EPOLLOUT or EPOLLONESHOT;
        LEv.data.ptr := AConn;
        epoll_ctl(FEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
      end
      else
        _CloseConn(AConn);
      Exit;
    end;
  end;

  // All bytes sent — P-4: return pool buffer (no-op for non-pool buffers)
  TBufferPool.Release(LConn.PendingSend);
  LConn.PendingSendActual := 0;
  // During TLS handshake we keep the connection alive regardless of HTTP KeepAlive.
  if (LConn.SSLHandle <> nil) and not LConn.SSLHandshook then
    _PostRecv(AConn)
  else if LConn.KeepAlive then
  begin
    if LConn.AccumLen > 0 then
      _ProcessRecv(AConn, nil, 0)  // pipelined request already in AccumBuf
    else
      _PostRecv(AConn);
  end
  else
    _CloseConn(AConn);
end;

// ---------------------------------------------------------------------------
// _DoRecv — reads one chunk and hands it to _ProcessRecv
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._DoRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LBuf:  array[0..RECV_BUF_SIZE - 1] of Byte;
  LN:    NativeInt;
begin
  LN := _LinuxRecv(LConn.Socket, @LBuf[0], RECV_BUF_SIZE, 0);
  if LN > 0 then
    _ProcessRecv(AConn, @LBuf[0], Cardinal(LN))
  else if LN = 0 then
    _CloseConn(AConn)  // graceful FIN
  else if GetLastError <> EAGAIN then
    _CloseConn(AConn);
  // EAGAIN on level-triggered: harmless — EPOLLONESHOT stays disarmed
  // until _PostRecv re-arms it.
end;

// ---------------------------------------------------------------------------
// _CloseConn — guarded against double-close from Stop()
// ---------------------------------------------------------------------------

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
  if Assigned(FMetrics) then FMetrics.AdjustConnections(-1);
  if LConn.WSMode = CM_WEBSOCKET then
  begin
    if LConn.WSConn <> nil then
      (LConn.WSConn as TPoseidonWSConn).Invalidate;
    LConn.WSConn := nil;
  end;
  FreeAndNil(LConn.H2Conn);
  if LConn.SSLHandle <> nil then
  begin
    TPoseidonSSL.Free_SSL(LConn.SSLHandle);  // also frees both BIOs
    LConn.SSLHandle   := nil;
    LConn.SSLReadBio  := nil;
    LConn.SSLWriteBio := nil;
  end;
  epoll_ctl(FEpollFd, EPOLL_CTL_DEL, LConn.Socket, nil);
  // R-6: TCP half-close — FIN before RST so the client receives the last bytes
  shutdown(LConn.Socket, SHUT_WR);
  _LinuxClose(LConn.Socket);
  LConn.Free;
  // R-1: wake the drain event so Stop() can proceed without polling
  if Assigned(FDrainEvent) then FDrainEvent.SetEvent;
end;

// ---------------------------------------------------------------------------
// Worker loop — epoll_wait dispatcher
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._WorkerLoop;
var
  LEvents: array[0..MAX_EVENTS - 1] of epoll_event;
  LN, I:   Integer;
  LConn:   TNativeConn;
  LDone:   Boolean;
  LDummy:  Byte;
begin
  LDone := False;
  while not LDone do
  begin
    LN := epoll_wait(FEpollFd, @LEvents[0], MAX_EVENTS, -1);
    if LN < 0 then
    begin
      if GetLastError = EINTR then Continue;
      Break;
    end;

    for I := 0 to LN - 1 do
    begin
      if LEvents[I].data.ptr = nil then
      begin
        // Shutdown sentinel: consume one byte so level-triggered fires
        // exactly once per worker.
        _LinuxRead(FShutdownPipe[0], @LDummy, 1);
        LDone := True;
        Break;
      end;

      LConn := TNativeConn(LEvents[I].data.ptr);
      try
        if (LEvents[I].events and (EPOLLERR or EPOLLHUP)) <> 0 then
          _CloseConn(LConn)
        else
        begin
          if (LEvents[I].events and EPOLLIN) <> 0 then
            _DoRecv(LConn);
          if (LEvents[I].events and EPOLLOUT) <> 0 then
            _FlushSend(LConn);
        end;
      except
        on E: Exception do
          _Log(llError, '[epoll] WORKER_EX [' + E.ClassName + ']: ' + E.Message);
      end;
    end;
  end;
end;

{$ENDIF MSWINDOWS}

end.
