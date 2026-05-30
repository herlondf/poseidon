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
  Poseidon.Net.WebSocket,
  Poseidon.Net.HTTP2;

type
  TPoseidonNativeRequest = record
    Method:      string;
    Path:        string;
    QueryString: string;
    RawBody:     TBytes;
    RemoteAddr:  string;
    KeepAlive:   Boolean;
    Headers:     TArray<TPair<string,string>>;
  end;

  TOnNativeRequest = reference to procedure(
    const AReq:          TPoseidonNativeRequest;
    out   AStatus:       Integer;
    out   AContentType:  string;
    out   ABody:         TBytes;
    out   AExtraHeaders: TArray<TPair<string,string>>);

  TLogLevel = (llDebug, llInfo, llWarning, llError);
  TOnPoseidonLog = reference to procedure(ALevel: TLogLevel; const AMessage: string);

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
{$IFDEF MSWINDOWS}
    FIocp:          THandle;
{$ELSE}
    FEpollFd:       Integer;
    FShutdownPipe:  array[0..1] of Integer;
{$ENDIF}

    procedure _Accept;
    procedure _OnNewSocket(ASocket: NativeUInt; const ARemoteAddr: string);
    procedure _PostRecv(AConn: Pointer);
    procedure _PostSend(AConn: Pointer; const AResponse: TBytes);
    procedure _CloseConn(AConn: Pointer);
    procedure _WorkerLoop;
    procedure _ProcessRecv(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);
    procedure _ProcessRecvSSL(AConn: Pointer; const ABuf: PByte; ALen: Cardinal;
      out AAborted: Boolean);
    procedure _ProcessRecvPlain(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);
    procedure _DispatchAccumBuf(AConn: Pointer);
    function  _TryParseRequest(AConn: Pointer;
      out AReq: TPoseidonNativeRequest; out ABadRequest: Boolean): Boolean;
    function  _DecodeChunked(ABuf: PByte; ABufLen: Integer;
      out ABody: TBytes; out AConsumed: Integer; out AMalformed: Boolean): Boolean;
    function  _BuildResponse(AStatus: Integer; const AContentType: string;
      const ABody: TBytes; AKeepAlive: Boolean;
      const AExtra: TArray<TPair<string,string>>): TBytes;
    procedure _EncryptAndSend(AConn: Pointer; const AAppData: TBytes);
    procedure _SSLFlushWriteBio(AConn: Pointer);
    procedure _IdleSweepLoop;
    function  _AdmitAndRegister(AConn: Pointer): Boolean;
    procedure _UnregisterIP(const ARemoteAddr: string);
    procedure _TryGzipResponse(const AReq: TPoseidonNativeRequest;
      const AContentType: string; var ABody: TBytes;
      var AExtra: TArray<TPair<string,string>>);
    procedure _UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function  _DispatchWSFrames(AConn: Pointer): Boolean;
    // HTTP/2 helpers — called from _ProcessRecv and used as TH2Conn callbacks
    procedure _H2Send(AConn: Pointer; const AData: TBytes);
    procedure _H2Close(AConn: Pointer);
    procedure _H2OnRequest(const AReq: TH2RequestData;
      var AStatus: Integer; var AContentType: string; var ABody: TBytes;
      var AExtra: TArray<TPair<string,string>>);
    procedure _Log(ALevel: TLogLevel; const AMessage: string);
{$IFNDEF MSWINDOWS}
    procedure _DoRecv(AConn: Pointer);
    procedure _FlushSend(AConn: Pointer);
{$ENDIF}
  public
    constructor Create;
    destructor  Destroy; override;
    procedure ConfigureSSL(const ACertFile, AKeyFile: string);
    procedure AddSSLCert(const AHostName, ACertFile, AKeyFile: string);
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
    procedure RegisterWSHandler(const APath: string; AHandler: TWSMessageCallback);
  end;

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows,
  Winapi.Winsock2,
  Poseidon.Net.SSL,
  Poseidon.Net.Pool.Buffer;
{$ELSE}
uses
  Posix.SysSocket,
  Posix.NetinetIn,
  Posix.NetinetTcp,
  Posix.ArpaInet,
  Posix.Unistd,
  Posix.Errno,
  Poseidon.Net.SSL,
  Poseidon.Net.Pool.Buffer;
{$ENDIF}

// ===========================================================================
// Shared constants
// ===========================================================================

const
  MAX_REQUEST_SIZE = 8 * 1024 * 1024;
  RECV_BUF_SIZE    = 32768;  // was 8192 — match CrossSocket; reduz recv() syscalls em payloads maiores
  ACCUM_INITIAL    = 8192;
  WORKER_COUNT_MIN = 4;
  CM_HTTP          = 0;
  CM_WEBSOCKET     = 1;

// ===========================================================================
// Shared type — TNativeConn
// Socket field type differs per platform; Linux adds PendingSend/SentBytes
// for the non-blocking send loop.
// ===========================================================================

type
  TNativeConn = class
  public
{$IFDEF MSWINDOWS}
    Socket:     TSocket;
{$ELSE}
    Socket:     Integer;
{$ENDIF}
    RemoteAddr:    string;
    AccumBuf:      TBytes;
    AccumLen:      Integer;
    KeepAlive:     Boolean;
    LastActivity:  TDateTime;   // updated on every _ProcessRecv — drives idle-timeout
    SSLHandle:     Pointer;   // SSL* (nil when plain HTTP)
    SSLReadBio:    Pointer;   // BIO* — encrypted bytes from network
    SSLWriteBio:   Pointer;   // BIO* — encrypted bytes to network
    SSLHandshook:  Boolean;
    WSMode:        Byte;
    WSPath:        string;
    WSConn:        IPoseidonWSConn;
    H2Conn:        TH2Conn;     // non-nil when connection uses HTTP/2 (via ALPN)
{$IFNDEF MSWINDOWS}
    PendingSend:   TBytes;
    SentBytes:     Integer;
{$ENDIF}
    constructor Create(
{$IFDEF MSWINDOWS}ASocket: TSocket{$ELSE}ASocket: Integer{$ENDIF};
      const AAddr: string);
    destructor  Destroy; override;
  end;

destructor TNativeConn.Destroy;
begin
  if AccumBuf <> nil then TBufferPool.Release(AccumBuf);
  FreeAndNil(H2Conn);
  inherited Destroy;
end;

constructor TNativeConn.Create(
{$IFDEF MSWINDOWS}ASocket: TSocket{$ELSE}ASocket: Integer{$ENDIF};
  const AAddr: string);
begin
  Socket    := ASocket;
  RemoteAddr := AAddr;
  AccumBuf  := TBufferPool.Acquire;   // pooled 8KB; skip if request grows beyond
  AccumLen  := 0;
  KeepAlive := False;
  LastActivity := Now;
  SSLHandle    := nil;
  SSLReadBio   := nil;
  SSLWriteBio  := nil;
  SSLHandshook := False;
  WSMode       := CM_HTTP;
  WSPath       := '';
  WSConn       := nil;
  H2Conn       := nil;
end;

// ===========================================================================
// Shared: _TryParseRequest
// ===========================================================================

function TPoseidonNativeServer._TryParseRequest(AConn: Pointer;
  out AReq: TPoseidonNativeRequest; out ABadRequest: Boolean): Boolean;
// Zero-Split parser: scans AccumBuf byte-by-byte using indices, materializing
// strings only for the final Method/Path/Headers values. Eliminates the big
// LData GetString + 2 Split TArray allocations per request.
const
  MAX_HEADER_SECTION = 65536;   // 64 KB hard cap on request-line + headers
  MAX_HEADER_COUNT   = 100;
  SP                 = $20;
  HT                 = $09;
  CR                 = $0D;
  LF                 = $0A;

  function BufToStr(const ABuf: TBytes; AStart, ALen: Integer): string;
  begin
    if ALen <= 0 then Result := ''
    else Result := TEncoding.ASCII.GetString(ABuf, AStart, ALen);
  end;

var
  LConn:         TNativeConn absolute AConn;
  I:             Integer;
  LHdrEnd:       Integer;
  LScanEnd:      Integer;
  LLineStart:    Integer;
  LLineEnd:      Integer;
  LSpace1:       Integer;
  LSpace2:       Integer;
  LColonPos:     Integer;
  LQPos:         Integer;
  LValStart:     Integer;
  LName, LValue: string;
  LCL:           Int64;
  LBodyStart,
  LConsumed:     Integer;
  LHdrCount:     Integer;
  LIsHttp11:     Boolean;
  LIsChunked:    Boolean;
  LChunkBody:    TBytes;
  LChunkBytes:   Integer;
  LChunkBad:     Boolean;
begin
  Result      := False;
  ABadRequest := False;

  // Scan for CRLFCRLF (end of headers)
  LHdrEnd  := -1;
  LScanEnd := LConn.AccumLen - 4;
  if LScanEnd > MAX_HEADER_SECTION then LScanEnd := MAX_HEADER_SECTION;
  for I := 0 to LScanEnd do
    if (LConn.AccumBuf[I]   = CR) and (LConn.AccumBuf[I+1] = LF) and
       (LConn.AccumBuf[I+2] = CR) and (LConn.AccumBuf[I+3] = LF) then
    begin
      LHdrEnd := I;
      Break;
    end;

  if LHdrEnd < 0 then
  begin
    if LConn.AccumLen > MAX_HEADER_SECTION then ABadRequest := True;
    Exit;
  end;

  // --- Parse request line: METHOD SP PATH[?QUERY] [SP HTTP/x.y] CRLF ---
  // Find end of request line
  LLineEnd := -1;
  for I := 0 to LHdrEnd - 1 do
    if (LConn.AccumBuf[I] = CR) and (LConn.AccumBuf[I+1] = LF) then
    begin
      LLineEnd := I;
      Break;
    end;
  if LLineEnd <= 0 then begin ABadRequest := True; Exit; end;

  // First space separates method from path
  LSpace1 := -1;
  for I := 0 to LLineEnd - 1 do
    if LConn.AccumBuf[I] = SP then begin LSpace1 := I; Break; end;
  if LSpace1 <= 0 then begin ABadRequest := True; Exit; end;

  // Second space separates path from version (optional in HTTP/0.9)
  LSpace2 := -1;
  for I := LSpace1 + 1 to LLineEnd - 1 do
    if LConn.AccumBuf[I] = SP then begin LSpace2 := I; Break; end;
  if LSpace2 < 0 then LSpace2 := LLineEnd;

  AReq.Method := BufToStr(LConn.AccumBuf, 0, LSpace1);

  // Find '?' inside path to split path/query
  LQPos := -1;
  for I := LSpace1 + 1 to LSpace2 - 1 do
    if LConn.AccumBuf[I] = Byte('?') then begin LQPos := I; Break; end;
  if LQPos > 0 then
  begin
    AReq.Path        := BufToStr(LConn.AccumBuf, LSpace1 + 1, LQPos - LSpace1 - 1);
    AReq.QueryString := BufToStr(LConn.AccumBuf, LQPos + 1, LSpace2 - LQPos - 1);
  end
  else
  begin
    AReq.Path        := BufToStr(LConn.AccumBuf, LSpace1 + 1, LSpace2 - LSpace1 - 1);
    AReq.QueryString := '';
  end;

  // Detect HTTP/1.1 by raw bytes (no string allocation)
  LIsHttp11 := False;
  if (LLineEnd - LSpace2 - 1) = 8 then
    LIsHttp11 :=
      (LConn.AccumBuf[LSpace2 + 1] = Byte('H')) and
      (LConn.AccumBuf[LSpace2 + 2] = Byte('T')) and
      (LConn.AccumBuf[LSpace2 + 3] = Byte('T')) and
      (LConn.AccumBuf[LSpace2 + 4] = Byte('P')) and
      (LConn.AccumBuf[LSpace2 + 5] = Byte('/')) and
      (LConn.AccumBuf[LSpace2 + 6] = Byte('1')) and
      (LConn.AccumBuf[LSpace2 + 7] = Byte('.')) and
      (LConn.AccumBuf[LSpace2 + 8] = Byte('1'));
  AReq.KeepAlive := LIsHttp11;

  // --- Parse headers ---
  LCL        := 0;
  LIsChunked := False;
  LHdrCount  := 0;
  SetLength(AReq.Headers, MAX_HEADER_COUNT);

  LLineStart := LLineEnd + 2;
  while LLineStart < LHdrEnd do
  begin
    if LHdrCount >= MAX_HEADER_COUNT then Break;

    LLineEnd := -1;
    for I := LLineStart to LHdrEnd - 1 do
      if (LConn.AccumBuf[I] = CR) and (LConn.AccumBuf[I+1] = LF) then
      begin
        LLineEnd := I;
        Break;
      end;
    if LLineEnd < 0 then Break;
    if LLineEnd = LLineStart then  // empty line — skip
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    LColonPos := -1;
    for I := LLineStart to LLineEnd - 1 do
      if LConn.AccumBuf[I] = Byte(':') then begin LColonPos := I; Break; end;
    if LColonPos < 0 then
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    // Skip OWS after colon
    LValStart := LColonPos + 1;
    while (LValStart < LLineEnd) and
          ((LConn.AccumBuf[LValStart] = SP) or (LConn.AccumBuf[LValStart] = HT)) do
      Inc(LValStart);

    LName  := BufToStr(LConn.AccumBuf, LLineStart, LColonPos - LLineStart);
    LValue := BufToStr(LConn.AccumBuf, LValStart,  LLineEnd - LValStart);

    AReq.Headers[LHdrCount] := TPair<string,string>.Create(LName, LValue);
    Inc(LHdrCount);

    if SameText(LName, 'Connection') then
    begin
      if Pos('keep-alive', LowerCase(LValue)) > 0 then AReq.KeepAlive := True;
      if Pos('close',      LowerCase(LValue)) > 0 then AReq.KeepAlive := False;
    end
    else if SameText(LName, 'Content-Length') then
      LCL := StrToInt64Def(LValue, 0)
    else if SameText(LName, 'Transfer-Encoding') then
      LIsChunked := Pos('chunked', LowerCase(LValue)) > 0;

    LLineStart := LLineEnd + 2;
  end;
  SetLength(AReq.Headers, LHdrCount);

  LBodyStart := LHdrEnd + 4;

  if LIsChunked then
  begin
    if not _DecodeChunked(@LConn.AccumBuf[LBodyStart],
         LConn.AccumLen - LBodyStart,
         LChunkBody, LChunkBytes, LChunkBad) then
    begin
      ABadRequest := LChunkBad;
      Exit;
    end;
    AReq.RawBody := LChunkBody;
    LConsumed    := LBodyStart + LChunkBytes;
  end
  else
  begin
    if LCL > 0 then
    begin
      if LConn.AccumLen - LBodyStart < LCL then Exit;
      SetLength(AReq.RawBody, LCL);
      Move(LConn.AccumBuf[LBodyStart], AReq.RawBody[0], LCL);
    end
    else
      SetLength(AReq.RawBody, 0);
    LConsumed := LBodyStart + LCL;
  end;

  AReq.RemoteAddr := LConn.RemoteAddr;

  if LConn.AccumLen > LConsumed then
    Move(LConn.AccumBuf[LConsumed], LConn.AccumBuf[0],
      LConn.AccumLen - LConsumed);
  LConn.AccumLen := LConn.AccumLen - LConsumed;

  Result := True;
end;

// ===========================================================================
// Shared: _DecodeChunked
// Result=True  → all chunks decoded; AConsumed = bytes consumed from ABuf
// Result=False, AMalformed=False → incomplete, need more data
// Result=False, AMalformed=True  → malformed chunk encoding → close conn
// ===========================================================================

function TPoseidonNativeServer._DecodeChunked(ABuf: PByte; ABufLen: Integer;
  out ABody: TBytes; out AConsumed: Integer; out AMalformed: Boolean): Boolean;
var
  LPos:       Integer;
  LCRLFP:     Integer;
  LSize:      AnsiString;
  LSemi:      Integer;
  LChunk:     Int64;
  LOldLen:    Integer;
  LDataStart: Integer;
  LBytes:     PByte;
  I, LLen:    Integer;
begin
  Result     := False;
  AMalformed := False;
  AConsumed  := 0;
  SetLength(ABody, 0);
  LPos   := 0;
  LBytes := ABuf;

  while True do
  begin
    // Find CRLF after chunk-size line
    LCRLFP := -1;
    I := LPos;
    while I < ABufLen - 1 do
    begin
      if (LBytes[I] = $0D) and (LBytes[I + 1] = $0A) then
      begin
        LCRLFP := I;
        Break;
      end;
      Inc(I);
    end;
    if LCRLFP < 0 then Exit;

    LLen := LCRLFP - LPos;
    if LLen < 1 then begin AMalformed := True; Exit; end;
    if LLen > 16 then begin AMalformed := True; Exit; end;  // hex size cap

    SetLength(LSize, LLen);
    Move(LBytes[LPos], LSize[1], LLen);

    LSemi := 0;
    for I := 1 to LLen do
      if LSize[I] = ';' then begin LSemi := I; Break; end;
    if LSemi > 0 then SetLength(LSize, LSemi - 1);

    if not TryStrToInt64('$' + string(LSize), LChunk) or (LChunk < 0) then
    begin
      AMalformed := True;
      Exit;
    end;

    if LChunk = 0 then
    begin
      LPos := LCRLFP + 2;
      I := LPos;
      while I < ABufLen - 1 do
      begin
        if (LBytes[I] = $0D) and (LBytes[I + 1] = $0A) then
        begin
          Inc(I, 2);
          LPos := I;
          Break;
        end;
        Inc(I);
      end;
      AConsumed := LPos;
      Result    := True;
      Exit;
    end;

    if LChunk > MAX_REQUEST_SIZE then begin AMalformed := True; Exit; end;

    LDataStart := LCRLFP + 2;
    if Int64(LDataStart) + LChunk + 2 > Int64(ABufLen) then Exit;

    LOldLen := Length(ABody);
    SetLength(ABody, LOldLen + Integer(LChunk));
    Move(LBytes[LDataStart], ABody[LOldLen], LChunk);

    LPos := LDataStart + Integer(LChunk) + 2;
  end;
end;

// ===========================================================================
// Shared: SSL helpers — encrypt-and-send + handshake write-BIO flush
// ===========================================================================

procedure TPoseidonNativeServer._EncryptAndSend(AConn: Pointer;
  const AAppData: TBytes);
var
  LConn:    TNativeConn absolute AConn;
  LPending: Integer;
  LEnc:     TBytes;
  LN:       Integer;
begin
  if LConn.SSLHandle = nil then
  begin
    _PostSend(AConn, AAppData);
    Exit;
  end;

  if Length(AAppData) > 0 then
  begin
    if TPoseidonSSL.SSL_Write(LConn.SSLHandle, @AAppData[0],
         Length(AAppData)) <= 0 then
    begin
      _CloseConn(AConn);
      Exit;
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
// Shared: _TryGzipResponse — opt-in gzip Content-Encoding negotiation
// ===========================================================================

procedure TPoseidonNativeServer._TryGzipResponse(const AReq: TPoseidonNativeRequest;
  const AContentType: string; var ABody: TBytes;
  var AExtra: TArray<TPair<string,string>>);
const
  GZIP_MIN_SIZE = 1024;
var
  I:        Integer;
  LAccept:  string;
  LCTLower: string;
  LSrc:     TBytesStream;
  LDest:    TBytesStream;
  LZip:     TZCompressionStream;
begin
  if not FCompressionEnabled then Exit;
  if Length(ABody) < GZIP_MIN_SIZE then Exit;

  LCTLower := LowerCase(AContentType);
  if LCTLower.StartsWith('image/') or LCTLower.StartsWith('video/') or
     LCTLower.StartsWith('audio/') or (LCTLower = 'application/zip') or
     (LCTLower = 'application/gzip') or (LCTLower = 'application/octet-stream') then
    Exit;

  LAccept := '';
  for I := 0 to High(AReq.Headers) do
    if SameText(AReq.Headers[I].Key, 'Accept-Encoding') then
    begin
      LAccept := AReq.Headers[I].Value;
      Break;
    end;
  if Pos('gzip', LowerCase(LAccept)) <= 0 then Exit;

  LSrc := TBytesStream.Create(ABody);
  try
    LDest := TBytesStream.Create;
    try
      // WindowBits=31 → gzip wrapper (vs 15=raw deflate or 47=auto-detect)
      LZip := TZCompressionStream.Create(LDest, zcDefault, 31);
      try
        LZip.CopyFrom(LSrc, 0);
      finally
        LZip.Free;
      end;
      SetLength(ABody, LDest.Size);
      if LDest.Size > 0 then
        Move(LDest.Bytes[0], ABody[0], LDest.Size);
    finally
      LDest.Free;
    end;
  finally
    LSrc.Free;
  end;

  SetLength(AExtra, Length(AExtra) + 1);
  AExtra[High(AExtra)] := TPair<string,string>.Create('Content-Encoding', 'gzip');
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
  // Register SNI callback so hostnames registered via AddSSLCert can switch CTX.
  TPoseidonSSL.CTX_SetSNICallback(FSSLCtx, @PoseidonSNIServernameCallback, Self);
  // Register ALPN callback to negotiate "h2" when HTTP2Enabled is True.
  if FH2Enabled then
    TPoseidonSSL.CTX_SetALPN(FSSLCtx, Self);
  FSSLEnabled := True;
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
// Shared: _BuildResponse — ONE TBytes = headers + body
// ===========================================================================

// Pre-encoded HTTP response fragments — initialized in `initialization`.
// _BuildResponse Move()s these directly into the output TBytes, avoiding
// UTF-16 string concat + TEncoding.ASCII.GetBytes per response (W3).
var
  G_STATUS_200, G_STATUS_201, G_STATUS_204,
  G_STATUS_301, G_STATUS_302, G_STATUS_303, G_STATUS_304,
  G_STATUS_400, G_STATUS_401, G_STATUS_403, G_STATUS_404, G_STATUS_405,
  G_STATUS_409, G_STATUS_413, G_STATUS_422, G_STATUS_429,
  G_STATUS_500, G_STATUS_503: TBytes;
  G_CT_PREFIX:   TBytes;   // 'Content-Type: '
  G_CL_PREFIX:   TBytes;   // 'Content-Length: '
  G_CONN_KA:     TBytes;   // 'Connection: keep-alive'#13#10
  G_CONN_CLOSE:  TBytes;   // 'Connection: close'#13#10
  G_CRLF:        TBytes;   // #13#10

  // Pre-encoded common Content-Type values — Move()'d into Result when the
  // response uses one of these (~95% of REST APIs hit application/json).
  G_CT_JSON, G_CT_TEXT, G_CT_HTML, G_CT_PROBLEM, G_CT_FORM, G_CT_OCTET: TBytes;

  // Pre-encoded default error body — eliminates per-request UTF-8 encoding
  // in _ProcessRecv even on successful paths (the value is replaced by the
  // user handler but the allocation was still happening every time).
  G_DEFAULT_ERROR_BODY: TBytes;

function DigitCount(AValue: Integer): Integer; inline;
begin
  if AValue < 10 then Result := 1
  else if AValue < 100 then Result := 2
  else if AValue < 1000 then Result := 3
  else if AValue < 10000 then Result := 4
  else if AValue < 100000 then Result := 5
  else if AValue < 1000000 then Result := 6
  else if AValue < 10000000 then Result := 7
  else if AValue < 100000000 then Result := 8
  else if AValue < 1000000000 then Result := 9
  else Result := 10;
end;

procedure WriteIntToBuffer(var ABuf: TBytes; APos: Integer; AValue: Integer);
// Writes AValue as ASCII digits into ABuf starting at APos. Caller must
// have allocated enough space (see DigitCount). No bounds check.
var
  LScratch: array[0..11] of Byte;
  LLen, I, LV: Integer;
begin
  if AValue = 0 then
  begin
    ABuf[APos] := $30;  // '0'
    Exit;
  end;
  LLen := 0;
  LV := AValue;
  while LV > 0 do
  begin
    LScratch[LLen] := Byte($30 + (LV mod 10));
    Inc(LLen);
    LV := LV div 10;
  end;
  for I := 0 to LLen - 1 do
    ABuf[APos + I] := LScratch[LLen - 1 - I];
end;

function GetContentTypeValueBytes(const AContentType: string;
  out AAlloc: Boolean): TBytes;
// Returns the pre-encoded bytes for the given content-type, or builds on the fly.
// AAlloc = True when the returned TBytes was freshly allocated (i.e., not a cached G_CT_*).
begin
  AAlloc := False;
  if      AContentType = 'application/json'         then Result := G_CT_JSON
  else if AContentType = 'text/plain'               then Result := G_CT_TEXT
  else if AContentType = 'text/html'                then Result := G_CT_HTML
  else if AContentType = 'application/problem+json' then Result := G_CT_PROBLEM
  else if AContentType = 'application/x-www-form-urlencoded' then Result := G_CT_FORM
  else if AContentType = 'application/octet-stream' then Result := G_CT_OCTET
  else
  begin
    Result := TEncoding.ASCII.GetBytes(AContentType);
    AAlloc := True;
  end;
end;

function GetStatusLineBytes(AStatus: Integer): TBytes;
begin
  case AStatus of
    200: Result := G_STATUS_200;
    201: Result := G_STATUS_201;
    204: Result := G_STATUS_204;
    301: Result := G_STATUS_301;
    302: Result := G_STATUS_302;
    303: Result := G_STATUS_303;
    304: Result := G_STATUS_304;
    400: Result := G_STATUS_400;
    401: Result := G_STATUS_401;
    403: Result := G_STATUS_403;
    404: Result := G_STATUS_404;
    405: Result := G_STATUS_405;
    409: Result := G_STATUS_409;
    413: Result := G_STATUS_413;
    422: Result := G_STATUS_422;
    429: Result := G_STATUS_429;
    500: Result := G_STATUS_500;
    503: Result := G_STATUS_503;
  else
    // Slow path for uncommon codes — build inline.
    Result := TEncoding.ASCII.GetBytes(
      'HTTP/1.1 ' + IntToStr(AStatus) + ' Unknown'#13#10);
  end;
end;

function TPoseidonNativeServer._BuildResponse(AStatus: Integer;
  const AContentType: string; const ABody: TBytes; AKeepAlive: Boolean;
  const AExtra: TArray<TPair<string,string>>): TBytes;
// Hot path: pre-cached fragments are Move()'d into Result. Common
// Content-Type values are pre-encoded (W3+); variable values write directly
// into Result via TEncoding.ASCII.GetBytes (no intermediate TBytes alloc).
var
  LStatusBytes: TBytes;
  LConnBytes:   TBytes;
  LCTValue:     TBytes;
  LCTAlloced:   Boolean;
  LExtraStr:    string;
  LBodyLen, LCLLen, LExtraLen: Integer;
  LTotal, LPos: Integer;
  I:            Integer;
begin
  LStatusBytes := GetStatusLineBytes(AStatus);
  if AKeepAlive then LConnBytes := G_CONN_KA
  else               LConnBytes := G_CONN_CLOSE;

  LCTValue := GetContentTypeValueBytes(AContentType, LCTAlloced);
  LBodyLen := Length(ABody);
  LCLLen   := DigitCount(LBodyLen);

  if Length(AExtra) > 0 then
  begin
    LExtraStr := '';
    for I := 0 to High(AExtra) do
      LExtraStr := LExtraStr + AExtra[I].Key + ': ' + AExtra[I].Value + #13#10;
  end;
  LExtraLen := Length(LExtraStr);

  LTotal := Length(LStatusBytes)
          + Length(G_CT_PREFIX) + Length(LCTValue) + 2  // '\r\n'
          + Length(G_CL_PREFIX) + LCLLen + 2
          + Length(LConnBytes)
          + LExtraLen
          + Length(G_CRLF)
          + Length(ABody);
  SetLength(Result, LTotal);
  LPos := 0;

  Move(LStatusBytes[0], Result[LPos], Length(LStatusBytes));
  Inc(LPos, Length(LStatusBytes));

  Move(G_CT_PREFIX[0], Result[LPos], Length(G_CT_PREFIX));
  Inc(LPos, Length(G_CT_PREFIX));
  if Length(LCTValue) > 0 then
  begin
    Move(LCTValue[0], Result[LPos], Length(LCTValue));
    Inc(LPos, Length(LCTValue));
  end;
  Result[LPos] := $0D; Result[LPos + 1] := $0A; Inc(LPos, 2);

  Move(G_CL_PREFIX[0], Result[LPos], Length(G_CL_PREFIX));
  Inc(LPos, Length(G_CL_PREFIX));
  WriteIntToBuffer(Result, LPos, LBodyLen);
  Inc(LPos, LCLLen);
  Result[LPos] := $0D; Result[LPos + 1] := $0A; Inc(LPos, 2);

  Move(LConnBytes[0], Result[LPos], Length(LConnBytes));
  Inc(LPos, Length(LConnBytes));

  if LExtraLen > 0 then
  begin
    TEncoding.ASCII.GetBytes(LExtraStr, 1, LExtraLen, Result, LPos);
    Inc(LPos, LExtraLen);
  end;

  Move(G_CRLF[0], Result[LPos], Length(G_CRLF));
  Inc(LPos, Length(G_CRLF));

  if Length(ABody) > 0 then
    Move(ABody[0], Result[LPos], Length(ABody));
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
        LConn.H2Conn := TH2Conn.Create(AConn, _H2Send, _H2Close, _H2OnRequest);
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
        SetLength(LConn.AccumBuf,
          Max(LConn.AccumLen + LDecN, Length(LConn.AccumBuf) * 2));
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
begin
  if LConn.AccumLen + Integer(ALen) > Length(LConn.AccumBuf) then
    SetLength(LConn.AccumBuf,
      Max(LConn.AccumLen + Integer(ALen), Length(LConn.AccumBuf) * 2));
  Move(ABuf^, LConn.AccumBuf[LConn.AccumLen], ALen);
  Inc(LConn.AccumLen, ALen);
end;

procedure TPoseidonNativeServer._DispatchAccumBuf(AConn: Pointer);
var
  LConn:    TNativeConn absolute AConn;
  LReq:     TPoseidonNativeRequest;
  LStatus:  Integer;
  LCT:      string;
  LBody:    TBytes;
  LExtra:   TArray<TPair<string,string>>;
  LResp:    TBytes;
  LBad:     Boolean;
  LUpgrade: string;
  LWsKey:   string;
  I:        Integer;
begin
  if LConn.AccumLen > MAX_REQUEST_SIZE then
  begin
    _CloseConn(AConn);
    Exit;
  end;

  // HTTP/2: route all accumulated data to TH2Conn processor
  if LConn.H2Conn <> nil then
  begin
    if LConn.AccumLen > 0 then
    begin
      LConn.H2Conn.ProcessData(@LConn.AccumBuf[0], LConn.AccumLen);
      LConn.AccumLen := 0;
    end;
    if not LConn.H2Conn.GoAwaySent then
      _PostRecv(AConn);
    Exit;
  end;

  if LConn.WSMode = CM_WEBSOCKET then
  begin
    if _DispatchWSFrames(AConn) then
      _PostRecv(AConn);
    Exit;
  end;

  if not _TryParseRequest(AConn, LReq, LBad) then
  begin
    if LBad then
    begin
      LResp := _BuildResponse(400, 'text/plain',
        TEncoding.ASCII.GetBytes('Bad Request'), False, []);
      _EncryptAndSend(AConn, LResp);
    end
    else
      _PostRecv(AConn);
    Exit;
  end;

  LUpgrade := '';
  LWsKey   := '';
  for I := 0 to High(LReq.Headers) do
  begin
    if SameText(LReq.Headers[I].Key, 'Upgrade')           then LUpgrade := LReq.Headers[I].Value;
    if SameText(LReq.Headers[I].Key, 'Sec-WebSocket-Key') then LWsKey   := LReq.Headers[I].Value;
  end;
  if SameText(LUpgrade, 'websocket') and (LWsKey <> '') then
  begin
    _UpgradeToWS(AConn, LReq);
    Exit;
  end;

  LConn.KeepAlive := LReq.KeepAlive;
  TInterlocked.Increment(FInFlightCount);
  try
    LStatus := 500;
    LCT     := 'application/json';
    LBody   := G_DEFAULT_ERROR_BODY;  // pre-encoded; overwritten by handler
    SetLength(LExtra, 0);
    try
      FOnRequest(LReq, LStatus, LCT, LBody, LExtra);
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

  _TryGzipResponse(LReq, LCT, LBody, LExtra);
  LResp := _BuildResponse(LStatus, LCT, LBody, LReq.KeepAlive, LExtra);
  _EncryptAndSend(AConn, LResp);
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

constructor TPoseidonNativeServer.Create;
begin
  inherited Create;
  FIdleTimeoutMs       := 10000;   // 10s default; set 0 to disable
  FMaxConnections      := 0;       // unlimited by default
  FMaxConnectionsPerIP := 0;       // unlimited by default
  FPerIPCount          := TDictionary<string, Integer>.Create;
  FWSHandlers          := TDictionary<string, TWSMessageCallback>.Create;
  FWSLock              := TCriticalSection.Create;
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
  FreeAndNil(FPerIPCount);
  FreeAndNil(FWSHandlers);
  FreeAndNil(FWSLock);
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
  LBody   := G_DEFAULT_ERROR_BODY;
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
    Ovl:     TOverlapped;           // MUST be first
    Action:  TIocpAction;
    Conn:    Pointer;
    WsaBuf:  TWsaBuf;
    SendBuf: TBytes;
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
    LWorkers := Max(WORKER_COUNT_MIN, TThread.ProcessorCount * 2);
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

  FIdleSweepThread := TThread.CreateAnonymousThread(procedure begin _IdleSweepLoop; end);
  FIdleSweepThread.FreeOnTerminate := False;
  FIdleSweepThread.Start;

  if Assigned(AOnListen) then
    AOnListen();
end;

procedure TPoseidonNativeServer.Stop;
const
  DRAIN_MS = 30000;
  POLL_MS  = 50;
var
  LElapsed, I: Integer;
  LConn:       TNativeConn;
  LConns:      TArray<Pointer>;
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

  LElapsed := 0;
  while ((TInterlocked.Read(FInFlightCount) > 0) or (FConnList.Count > 0))
    and (LElapsed < DRAIN_MS) do
  begin
    Sleep(POLL_MS);
    Inc(LElapsed, POLL_MS);
  end;

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

procedure TPoseidonNativeServer._PostSend(AConn: Pointer; const AResponse: TBytes);
var
  LConn:  TNativeConn absolute AConn;
  LCtx:   PSendCtx;
  LBytes: DWORD;
  LRes:   Integer;
begin
  if Length(AResponse) = 0 then
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
  LCtx^.WsaBuf.len := Length(AResponse);
  LCtx^.WsaBuf.buf := @LCtx^.SendBuf[0];
  LBytes := 0;

  LRes := WSASend(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, 0,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if (LRes = SOCKET_ERROR) and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
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
  closesocket(LConn.Socket);
  LConn.Free;
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
          iaSend: Dispose(PSendCtx(LOvl));
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
    LWorkers := Max(WORKER_COUNT_MIN, TThread.ProcessorCount * 2);
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

  FIdleSweepThread := TThread.CreateAnonymousThread(procedure begin _IdleSweepLoop; end);
  FIdleSweepThread.FreeOnTerminate := False;
  FIdleSweepThread.Start;

  if Assigned(AOnListen) then
    AOnListen();
end;

// ---------------------------------------------------------------------------
// Stop
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer.Stop;
const
  DRAIN_MS = 30000;
  POLL_MS  = 50;
var
  LElapsed, I: Integer;
  LConn:       TNativeConn;
  LConns:      TArray<Pointer>;
  LDummy:      Byte;
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

  LElapsed := 0;
  while ((TInterlocked.Read(FInFlightCount) > 0) or (FConnList.Count > 0))
    and (LElapsed < DRAIN_MS) do
  begin
    Sleep(POLL_MS);
    Inc(LElapsed, POLL_MS);
  end;

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

procedure TPoseidonNativeServer._PostSend(AConn: Pointer; const AResponse: TBytes);
var
  LConn: TNativeConn absolute AConn;
begin
  if Length(AResponse) = 0 then
  begin
    if LConn.KeepAlive then _PostRecv(AConn)
    else _CloseConn(AConn);
    Exit;
  end;
  LConn.PendingSend := AResponse;
  LConn.SentBytes   := 0;
  _FlushSend(AConn);
end;

// ---------------------------------------------------------------------------
// _FlushSend — send() loop; arms EPOLLOUT on EAGAIN (partial send)
// ---------------------------------------------------------------------------

procedure TPoseidonNativeServer._FlushSend(AConn: Pointer);
var
  LConn:   TNativeConn absolute AConn;
  LRemain: Integer;
  LN:      NativeInt;
  LEv:     epoll_event;
begin
  while LConn.SentBytes < Length(LConn.PendingSend) do
  begin
    LRemain := Length(LConn.PendingSend) - LConn.SentBytes;
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

  // All bytes sent.
  LConn.PendingSend := nil;
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
  _LinuxClose(LConn.Socket);
  LConn.Free;
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

initialization
  // W3: pre-encode common HTTP response fragments once.
  G_STATUS_200 := TEncoding.ASCII.GetBytes('HTTP/1.1 200 OK'#13#10);
  G_STATUS_201 := TEncoding.ASCII.GetBytes('HTTP/1.1 201 Created'#13#10);
  G_STATUS_204 := TEncoding.ASCII.GetBytes('HTTP/1.1 204 No Content'#13#10);
  G_STATUS_301 := TEncoding.ASCII.GetBytes('HTTP/1.1 301 Moved Permanently'#13#10);
  G_STATUS_302 := TEncoding.ASCII.GetBytes('HTTP/1.1 302 Found'#13#10);
  G_STATUS_303 := TEncoding.ASCII.GetBytes('HTTP/1.1 303 See Other'#13#10);
  G_STATUS_304 := TEncoding.ASCII.GetBytes('HTTP/1.1 304 Not Modified'#13#10);
  G_STATUS_400 := TEncoding.ASCII.GetBytes('HTTP/1.1 400 Bad Request'#13#10);
  G_STATUS_401 := TEncoding.ASCII.GetBytes('HTTP/1.1 401 Unauthorized'#13#10);
  G_STATUS_403 := TEncoding.ASCII.GetBytes('HTTP/1.1 403 Forbidden'#13#10);
  G_STATUS_404 := TEncoding.ASCII.GetBytes('HTTP/1.1 404 Not Found'#13#10);
  G_STATUS_405 := TEncoding.ASCII.GetBytes('HTTP/1.1 405 Method Not Allowed'#13#10);
  G_STATUS_409 := TEncoding.ASCII.GetBytes('HTTP/1.1 409 Conflict'#13#10);
  G_STATUS_413 := TEncoding.ASCII.GetBytes('HTTP/1.1 413 Payload Too Large'#13#10);
  G_STATUS_422 := TEncoding.ASCII.GetBytes('HTTP/1.1 422 Unprocessable Entity'#13#10);
  G_STATUS_429 := TEncoding.ASCII.GetBytes('HTTP/1.1 429 Too Many Requests'#13#10);
  G_STATUS_500 := TEncoding.ASCII.GetBytes('HTTP/1.1 500 Internal Server Error'#13#10);
  G_STATUS_503 := TEncoding.ASCII.GetBytes('HTTP/1.1 503 Service Unavailable'#13#10);
  G_CT_PREFIX  := TEncoding.ASCII.GetBytes('Content-Type: ');
  G_CL_PREFIX  := TEncoding.ASCII.GetBytes('Content-Length: ');
  G_CONN_KA    := TEncoding.ASCII.GetBytes('Connection: keep-alive'#13#10);
  G_CONN_CLOSE := TEncoding.ASCII.GetBytes('Connection: close'#13#10);
  G_CRLF       := TEncoding.ASCII.GetBytes(#13#10);

  // W3+: pre-encode common content-type values
  G_CT_JSON    := TEncoding.ASCII.GetBytes('application/json');
  G_CT_TEXT    := TEncoding.ASCII.GetBytes('text/plain');
  G_CT_HTML    := TEncoding.ASCII.GetBytes('text/html');
  G_CT_PROBLEM := TEncoding.ASCII.GetBytes('application/problem+json');
  G_CT_FORM    := TEncoding.ASCII.GetBytes('application/x-www-form-urlencoded');
  G_CT_OCTET   := TEncoding.ASCII.GetBytes('application/octet-stream');

  G_DEFAULT_ERROR_BODY := TEncoding.UTF8.GetBytes(
    '{"error":"Internal Server Error"}');

end.
