unit Poseidon.Net.IO.RIO;

// TRIOBackend — Windows Registered I/O backend.
//
// RIO (Windows 8+) uses shared-memory completion queues. In polled mode,
// dequeue completions with ZERO syscalls — similar to io_uring SQPOLL.
//
// Architecture:
//   - Pre-register recv buffers once (CRecvPoolSize × 32KB)
//   - Per-socket RIOCreateRequestQueue bound to a per-worker CQ
//   - RIOReceive / RIOSend with registered buffer slices
//   - RIODequeueCompletion — zero-syscall poll loop per worker
//
// Loaded via WSAIoctl(SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER).
//
// Completion/request queues are NOT thread-safe — per-worker CQs match
// the per-core architecture. Each connection is pinned to one CQ via
// round-robin assignment at RegisterConn time.
//
// If RIO is unavailable (Windows 7), constructor raises ENotSupportedException
// and TPoseidonNativeServer falls back to TIOCPBackend.

{$IFDEF MSWINDOWS}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Winapi.Windows,
  Winapi.Winsock2,
  Poseidon.Net.IO,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer;

type
  TRIO_BUFFERID = Pointer;
  TRIO_CQ = Pointer;
  TRIO_RQ = Pointer;

  TRIO_BUF = record
    BufferId: TRIO_BUFFERID;
    Offset: ULONG;
    Length: ULONG;
  end;
  PRIO_BUF = ^TRIO_BUF;

  TRIO_RESULT = record
    Status: LONG;
    BytesTransferred: ULONG;
    SocketContext: UInt64;
    RequestContext: UInt64;
  end;
  PRIO_RESULT = ^TRIO_RESULT;

  TRIO_NOTIFICATION_COMPLETION = record
    Typ: Integer;
    case Integer of
      0: ();
      2: (
        IocpHandle: THandle;
        CompletionKey: Pointer;
        pOverlapped: POverlapped
      );
  end;
  PRIO_NOTIFICATION_COMPLETION = ^TRIO_NOTIFICATION_COMPLETION;

  TRIO_EXTENSION_FUNCTION_TABLE = record
    cbSize: DWORD;
    RIOReceive: Pointer;
    RIOReceiveEx: Pointer;
    RIOSend: Pointer;
    RIOSendEx: Pointer;
    RIOCloseCompletionQueue: Pointer;
    RIOCreateCompletionQueue: Pointer;
    RIOCreateRequestQueue: Pointer;
    RIODequeueCompletion: Pointer;
    RIONotify: Pointer;
    RIORegisterBuffer: Pointer;
    RIODeregisterBuffer: Pointer;
    RIOResizeCompletionQueue: Pointer;
    RIOResizeRequestQueue: Pointer;
  end;

  TRIOBackend = class(TInterfacedObject, IIOBackend)
  private
    FRio: TRIO_EXTENSION_FUNCTION_TABLE;
    FListenSocket: TSocket;
    FWorkers: TArray<TThread>;
    FAcceptThread: TThread;
    FCQs: TArray<TRIO_CQ>;
    FCQLocks: TArray<TCriticalSection>;
    FCallbacks: IIOCallbacks;
    FShutdown: Int64;  // 0=running, 1=shutdown; atomic via TInterlocked (Read requires Int64)
    FNextCQ: Integer;
    // Pre-allocated recv pool
    FRecvPool: Pointer;
    FRecvPoolBufId: TRIO_BUFFERID;
    FRecvFreeStack: array of Integer;
    FRecvFreeTop: Integer;
    FRecvPoolLock: TCriticalSection;
    FSendPool: Pointer;
    FSendPoolBufId: TRIO_BUFFERID;
    FSendFreeStack: array of Integer;
    FSendFreeTop: Integer;
    FSendPoolLock: TCriticalSection;
    FWorkerIOCPs: TArray<THandle>;
    FWorkerOvls: TArray<POverlapped>;
    procedure _LoadRIO;
    procedure _Accept;
    procedure _WorkerLoop(ACQIdx: Integer);
    function _MakeWorkerThread(ACQIdx: Integer): TThread;
    function _RecvPoolAcquire: Integer;
    procedure _RecvPoolRelease(AIdx: Integer);
    function _RecvSlotPtr(AIdx: Integer): PByte;
    function _SendPoolAcquire: Integer;
    procedure _SendPoolRelease(AIdx: Integer);
    function _SendSlotPtr(AIdx: Integer): PByte;
  public
    constructor Create;
    destructor Destroy; override;
    procedure StartListening(const AHost: string; APort: Integer;
      AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
      AAcceptThreads: Integer = 1);
    procedure StopAccept;
    procedure ShutdownConn(AConn: Pointer);
    procedure SignalWorkers;
    procedure JoinWorkers;
    procedure RegisterConn(AConn: Pointer);
    procedure PostRecv(AConn: Pointer);
    procedure PostSend(AConn: Pointer; const AData: TBytes; AActualLen: Integer);
    procedure PostSendV(AConn: Pointer;
      const AHeaders: TBytes; AHdrLen: Integer;
      const ABody: TBytes; ABodyLen: Integer);
    procedure SocketClose(AConn: Pointer);
  end;

implementation

uses
  Poseidon.Net.Pool.Socket;

const
  SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER = $C8000024;
  WSAID_MULTIPLE_RIO: TGUID = '{8509E081-96DD-4005-B165-9E2EE8C79E3F}';
  WSA_FLAG_REGISTERED_IO = $100;

  CRIOInvalidBufId = TRIO_BUFFERID(NativeUInt(-1));

  CTCP_FASTOPEN = 15;
  CRecvBufSize = 32768;
  CRecvPoolSize = 512;
  // +1 slot de headroom: RIOReceive rejeita com WSAEINVAL quando Offset+Length
  // == buffer size (offset+length deve ser ESTRITAMENTE menor). Nunca usamos
  // este slot extra — apenas garante que o último slot válido (índice N-1)
  // caiba dentro do buffer registrado com folga.
  CRecvPoolBytes = (CRecvPoolSize + 1) * CRecvBufSize;
  CSendBufSize = 32768;
  CSendPoolSize = 512;
  // Mesmo headroom do recv pool — evita WSAEINVAL em RIOSend com o último slot.
  CSendPoolBytes = (CSendPoolSize + 1) * CSendBufSize;
  CRIOCQSize = 4096;
  CRIORQRecv = 32;
  CRIORQSend = 32;
  CRIONotifyIOCP = 2;

  // RequestContext encoding: low bit = action, rest = context index/pointer
  CTagRecv = UInt64(0);
  CTagSend = UInt64(1);
  CRioMsgDefer = $02;
  CRioCorruptCQ = ULONG($FFFFFFFF);

type
  // RIO function types
  TFnCreateCQ = function(QueueSize: DWORD; NotificationCompletion: PRIO_NOTIFICATION_COMPLETION): TRIO_CQ; stdcall;
  TFnCloseCQ = procedure(CQ: TRIO_CQ); stdcall;
  TFnCreateRQ = function(Socket: TSocket; MaxOutstandingRecv, MaxRecvDataBuffers,
    MaxOutstandingSend, MaxSendDataBuffers: DWORD; RecvCQ, SendCQ: TRIO_CQ;
    SocketContext: Pointer): TRIO_RQ; stdcall;
  TFnRegBuf = function(DataBuffer: PAnsiChar; DataLength: DWORD): TRIO_BUFFERID; stdcall;
  TFnDeregBuf = procedure(BufferId: TRIO_BUFFERID); stdcall;
  TFnRecv = function(SocketQueue: TRIO_RQ; pData: PRIO_BUF; DataBufferCount: ULONG;
    Flags: DWORD; RequestContext: Pointer): BOOL; stdcall;
  TFnSend = function(SocketQueue: TRIO_RQ; pData: PRIO_BUF; DataBufferCount: ULONG;
    Flags: DWORD; RequestContext: Pointer): BOOL; stdcall;
  TFnDequeue = function(CQ: TRIO_CQ; Array_: PRIO_RESULT;
    ArraySize: DWORD): ULONG; stdcall;
  TFnNotify = function(CQ: TRIO_CQ): BOOL; stdcall;

  // Send context — heap-allocated, holds buffer reference until completion
  PRIOSendCtx = ^TRIOSendCtx;
  TRIOSendCtx = record
    Conn: TNativeConn;
    SendBuf: TBytes;
    SlotIdx: Integer;
    BufId: TRIO_BUFFERID;
    ActualLen: Integer;
    BodyBuf: TBytes;
    SlotIdx2: Integer;
    BufId2: TRIO_BUFFERID;
    Remaining: Integer;
  end;

function VirtualAllocExNuma(hProcess: THandle; lpAddress: Pointer;
  dwSize: NativeUInt; flAllocationType, flProtect, nndPreferred: DWORD): Pointer; stdcall;
  external 'kernel32.dll';
function GetCurrentProcessorNumber: DWORD; stdcall;
  external 'kernel32.dll';
function GetNumaProcessorNode(Processor: Byte; var NodeNumber: Byte): BOOL; stdcall;
  external 'kernel32.dll';

function _GetNumaNode: DWORD;
var
  LProc: DWORD;
  LNode: Byte;
begin
  Result := 0;
  LProc := GetCurrentProcessorNumber;
  if LProc > 255 then Exit;
  if GetNumaProcessorNode(Byte(LProc), LNode) then
    Result := LNode;
end;

function _WsaBind(s: TSocket; addr: PSockAddrIn; addrlen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'bind';
function _WsaListen(s: TSocket; backlog: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'listen';
function _WsaAccept(s: TSocket; addr: PSockAddrIn; addrlen: PInteger): TSocket; stdcall;
  external 'ws2_32.dll' name 'accept';

// ---------------------------------------------------------------------------
// Constructor / Destructor
// ---------------------------------------------------------------------------

constructor TRIOBackend.Create;
var
  I: Integer;
  LNumaNode: DWORD;
begin
  inherited Create;
  FListenSocket := INVALID_SOCKET;
  FShutdown := 0;
  FNextCQ := 0;
  FRecvPool := nil;
  FRecvPoolBufId := nil;
  FRecvPoolLock := TCriticalSection.Create;
  FSendPoolLock := TCriticalSection.Create;
  FSendPool := nil;
  FSendPoolBufId := nil;
  _LoadRIO;

  LNumaNode := _GetNumaNode;

  FRecvPool := VirtualAllocExNuma(GetCurrentProcess, nil, CRecvPoolBytes,
    MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE, LNumaNode);
  if FRecvPool = nil then
    raise Exception.Create('VirtualAllocExNuma for RIO recv pool failed');

  FRecvPoolBufId := TFnRegBuf(FRio.RIORegisterBuffer)(PAnsiChar(FRecvPool),
    CRecvPoolBytes);
  if FRecvPoolBufId = CRIOInvalidBufId then
    raise Exception.Create('RIORegisterBuffer for recv pool failed');

  SetLength(FRecvFreeStack, CRecvPoolSize);
  FRecvFreeTop := CRecvPoolSize;
  for I := 0 to CRecvPoolSize - 1 do
    FRecvFreeStack[I] := I;

  FSendPool := VirtualAllocExNuma(GetCurrentProcess, nil, CSendPoolBytes,
    MEM_COMMIT or MEM_RESERVE, PAGE_READWRITE, LNumaNode);
  if FSendPool = nil then
    raise Exception.Create('VirtualAllocExNuma for RIO send pool failed');

  FSendPoolBufId := TFnRegBuf(FRio.RIORegisterBuffer)(PAnsiChar(FSendPool),
    CSendPoolBytes);
  if FSendPoolBufId = CRIOInvalidBufId then
    raise Exception.Create('RIORegisterBuffer for send pool failed');

  SetLength(FSendFreeStack, CSendPoolSize);
  FSendFreeTop := CSendPoolSize;
  for I := 0 to CSendPoolSize - 1 do
    FSendFreeStack[I] := I;
end;

destructor TRIOBackend.Destroy;
begin
  if (FRecvPoolBufId <> nil) and (FRecvPoolBufId <> CRIOInvalidBufId) then
    TFnDeregBuf(FRio.RIODeregisterBuffer)(FRecvPoolBufId);
  if FRecvPool <> nil then
    VirtualFree(FRecvPool, 0, MEM_RELEASE);
  if (FSendPoolBufId <> nil) and (FSendPoolBufId <> CRIOInvalidBufId) then
    TFnDeregBuf(FRio.RIODeregisterBuffer)(FSendPoolBufId);
  if FSendPool <> nil then
    VirtualFree(FSendPool, 0, MEM_RELEASE);
  FreeAndNil(FRecvPoolLock);
  FreeAndNil(FSendPoolLock);
  inherited Destroy;
end;

procedure TRIOBackend._LoadRIO;
var
  LWsaData: TWSAData;
  LSocket: TSocket;
  LBytes: DWORD;
begin
  if WSAStartup($0202, LWsaData) <> 0 then
    raise ENotSupportedException.Create('WSAStartup failed');

  LSocket := WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, nil, 0,
    WSA_FLAG_REGISTERED_IO);
  if LSocket = INVALID_SOCKET then
    raise ENotSupportedException.Create(
      'RIO unavailable: WSA_FLAG_REGISTERED_IO not supported');

  FillChar(FRio, SizeOf(FRio), 0);
  FRio.cbSize := SizeOf(FRio);
  LBytes := 0;

  if WSAIoctl(LSocket, SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER,
    @WSAID_MULTIPLE_RIO, SizeOf(WSAID_MULTIPLE_RIO),
    @FRio, SizeOf(FRio), LBytes, nil, nil) <> 0 then
  begin
    closesocket(LSocket);
    raise ENotSupportedException.Create(
      'RIO unavailable: WSAIoctl for RIO function table failed');
  end;
  closesocket(LSocket);
end;

// ---------------------------------------------------------------------------
// Recv pool
// ---------------------------------------------------------------------------

function TRIOBackend._RecvPoolAcquire: Integer;
begin
  FRecvPoolLock.Enter;
  try
    if FRecvFreeTop > 0 then
    begin
      Dec(FRecvFreeTop);
      Result := FRecvFreeStack[FRecvFreeTop];
    end
    else
      Result := -1;
  finally
    FRecvPoolLock.Leave;
  end;
end;

procedure TRIOBackend._RecvPoolRelease(AIdx: Integer);
begin
  FRecvPoolLock.Enter;
  try
    FRecvFreeStack[FRecvFreeTop] := AIdx;
    Inc(FRecvFreeTop);
  finally
    FRecvPoolLock.Leave;
  end;
end;

function TRIOBackend._RecvSlotPtr(AIdx: Integer): PByte;
begin
  Result := PByte(FRecvPool) + NativeUInt(AIdx) * CRecvBufSize;
end;

// ---------------------------------------------------------------------------
// Send pool
// ---------------------------------------------------------------------------

function TRIOBackend._SendPoolAcquire: Integer;
begin
  FSendPoolLock.Enter;
  try
    if FSendFreeTop > 0 then
    begin
      Dec(FSendFreeTop);
      Result := FSendFreeStack[FSendFreeTop];
    end
    else
      Result := -1;
  finally
    FSendPoolLock.Leave;
  end;
end;

procedure TRIOBackend._SendPoolRelease(AIdx: Integer);
begin
  FSendPoolLock.Enter;
  try
    FSendFreeStack[FSendFreeTop] := AIdx;
    Inc(FSendFreeTop);
  finally
    FSendPoolLock.Leave;
  end;
end;

function TRIOBackend._SendSlotPtr(AIdx: Integer): PByte;
begin
  Result := PByte(FSendPool) + NativeUInt(AIdx) * CSendBufSize;
end;

function TRIOBackend._MakeWorkerThread(ACQIdx: Integer): TThread;
// ACQIdx é parâmetro (capturado por valor pela closure) — evita o bug clássico
// de captura por referência quando a variável do loop é usada diretamente.
begin
  Result := TThread.CreateAnonymousThread(procedure begin _WorkerLoop(ACQIdx); end);
end;

// ---------------------------------------------------------------------------
// IIOBackend — lifecycle
// ---------------------------------------------------------------------------

procedure TRIOBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);
var
  LAddr: TSockAddrIn;
  LOne: Integer;
  I: Integer;
  LNotify: TRIO_NOTIFICATION_COMPLETION;
begin
  FCallbacks := ACallbacks;
  FShutdown := 0;

  FListenSocket := WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, nil, 0,
    WSA_FLAG_REGISTERED_IO);
  if FListenSocket = INVALID_SOCKET then
    RaiseLastOSError;

  LOne := 1;
  setsockopt(FListenSocket, SOL_SOCKET, SO_REUSEADDR,
    PAnsiChar(@LOne), SizeOf(LOne));
  if AFastOpen then
    setsockopt(FListenSocket, IPPROTO_TCP, CTCP_FASTOPEN,
      PAnsiChar(@LOne), SizeOf(LOne));

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port := htons(APort);
  if (AHost = '0.0.0.0') or (AHost = '') then
    LAddr.sin_addr.S_addr := INADDR_ANY
  else
    LAddr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(AHost)));

  if _WsaBind(FListenSocket, @LAddr, SizeOf(LAddr)) = SOCKET_ERROR then
    RaiseLastOSError;
  if _WsaListen(FListenSocket, SOMAXCONN) = SOCKET_ERROR then
    RaiseLastOSError;

  TSocketPool.LoadDisconnectEx(FListenSocket);

  SetLength(FCQs, AWorkerCount);
  SetLength(FCQLocks, AWorkerCount);
  SetLength(FWorkerIOCPs, AWorkerCount);
  SetLength(FWorkerOvls, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
  begin
    FWorkerIOCPs[I] := CreateIoCompletionPort(INVALID_HANDLE_VALUE, 0, 0, 1);
    if FWorkerIOCPs[I] = 0 then
      raise Exception.Create('CreateIoCompletionPort for RIO worker failed');
    New(FWorkerOvls[I]);
    FillChar(FWorkerOvls[I]^, SizeOf(TOverlapped), 0);

    FillChar(LNotify, SizeOf(LNotify), 0);
    LNotify.Typ := CRIONotifyIOCP;
    LNotify.IocpHandle := FWorkerIOCPs[I];
    LNotify.CompletionKey := nil;
    LNotify.pOverlapped := FWorkerOvls[I];

    FCQs[I] := TFnCreateCQ(FRio.RIOCreateCompletionQueue)(CRIOCQSize, @LNotify);
    if FCQs[I] = nil then
      raise Exception.Create('RIOCreateCompletionQueue failed');
    FCQLocks[I] := TCriticalSection.Create;
  end;

  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
  begin
    // Fix: captura por VALOR via parâmetro de função. Assignment em variável
    // local (LIdx := I) seria capturada por REFERÊNCIA pela anonymous method
    // — todas as N threads leriam o mesmo LIdx (última iteração), colapsando
    // o polling em uma única CQ e vazando completions das demais.
    FWorkers[I] := _MakeWorkerThread(I);
    FWorkers[I].FreeOnTerminate := False;
    FWorkers[I].Start;
  end;

  FAcceptThread := TThread.CreateAnonymousThread(procedure begin _Accept; end);
  FAcceptThread.FreeOnTerminate := False;
  FAcceptThread.Start;
end;

procedure TRIOBackend.StopAccept;
begin
  closesocket(FListenSocket);
  FListenSocket := INVALID_SOCKET;
  if FAcceptThread <> nil then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;
end;

procedure TRIOBackend.ShutdownConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LSock: TSocket;
begin
  // #173: skip if SocketClose already invalidated the handle (recycled fd).
  LSock := LConn.Socket;
  if LSock <> INVALID_SOCKET then
    shutdown(LSock, SD_BOTH);
end;

procedure TRIOBackend.SignalWorkers;
var
  I: Integer;
begin
  TInterlocked.Exchange(FShutdown, 1);
  for I := 0 to High(FWorkerIOCPs) do
    PostQueuedCompletionStatus(FWorkerIOCPs[I], 0, 0, nil);
end;

procedure TRIOBackend.JoinWorkers;
var
  I: Integer;
begin
  TInterlocked.Exchange(FShutdown, 1);
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  SetLength(FWorkers, 0);

  for I := 0 to High(FCQs) do
  begin
    if FCQs[I] <> nil then
      TFnCloseCQ(FRio.RIOCloseCompletionQueue)(FCQs[I]);
    FreeAndNil(FCQLocks[I]);
  end;
  SetLength(FCQs, 0);
  SetLength(FCQLocks, 0);

  for I := 0 to High(FWorkerIOCPs) do
  begin
    if FWorkerIOCPs[I] <> 0 then
      CloseHandle(FWorkerIOCPs[I]);
    if FWorkerOvls[I] <> nil then
      Dispose(FWorkerOvls[I]);
  end;
  SetLength(FWorkerIOCPs, 0);
  SetLength(FWorkerOvls, 0);

  WSACleanup;
end;

// ---------------------------------------------------------------------------
// IIOBackend — per-connection
// ---------------------------------------------------------------------------

procedure TRIOBackend.RegisterConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LCQIdx: Integer;
  LRQ: TRIO_RQ;
begin
  // Round-robin CQ assignment
  LCQIdx := Cardinal(TInterlocked.Increment(FNextCQ)) mod Cardinal(Length(FCQs));

  // Create per-socket request queue bound to recv CQ and send CQ (same CQ)
  FCQLocks[LCQIdx].Enter;
  try
    LRQ := TFnCreateRQ(FRio.RIOCreateRequestQueue)(
      LConn.Socket, CRIORQRecv, 1, CRIORQSend, 1,
      FCQs[LCQIdx], FCQs[LCQIdx], Pointer(LConn));
  finally
    FCQLocks[LCQIdx].Leave;
  end;

  if LRQ = nil then
  begin
    FCallbacks.OnConnError(AConn);
    Exit;
  end;

  LConn.RioRQ := LRQ;
end;

procedure TRIOBackend.PostRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LSlotIdx: Integer;
  LBuf: TRIO_BUF;
  LReqCtx: UInt64;
begin
  LSlotIdx := _RecvPoolAcquire;
  if LSlotIdx < 0 then
  begin
    FCallbacks.OnConnError(AConn);
    Exit;
  end;

  LBuf.BufferId := FRecvPoolBufId;
  LBuf.Offset := ULONG(LSlotIdx) * CRecvBufSize;
  LBuf.Length := CRecvBufSize;

  // Encode: slot index in high bits, tag recv in low bit
  LReqCtx := (UInt64(LSlotIdx) shl 1) or CTagRecv;

  LConn.AddRef;

  if not TFnRecv(FRio.RIOReceive)(LConn.RioRQ, @LBuf, 1, 0,
    Pointer(LReqCtx)) then
  begin
    LConn.Release;
    _RecvPoolRelease(LSlotIdx);
    FCallbacks.OnConnError(AConn);
  end;
end;

procedure TRIOBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
var
  LConn: TNativeConn absolute AConn;
  LSendLen: Integer;
  LSendCtx: PRIOSendCtx;
  LBuf: TRIO_BUF;
  LReqCtx: UInt64;
  LSlotIdx: Integer;
  LRelTmp: TBytes;
begin
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AData);

  if LSendLen = 0 then
  begin
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  New(LSendCtx);
  LSendCtx^.Conn := LConn;
  LSendCtx^.SendBuf := AData;
  LSendCtx^.ActualLen := LSendLen;
  LSendCtx^.BodyBuf := nil;
  LSendCtx^.SlotIdx2 := -2;
  LSendCtx^.BufId2 := nil;
  LSendCtx^.Remaining := 1;

  LSlotIdx := -1;
  if LSendLen <= CSendBufSize then
    LSlotIdx := _SendPoolAcquire;

  if LSlotIdx >= 0 then
  begin
    LSendCtx^.SlotIdx := LSlotIdx;
    LSendCtx^.BufId := nil;
    Move(AData[0], _SendSlotPtr(LSlotIdx)^, LSendLen);
    LBuf.BufferId := FSendPoolBufId;
    LBuf.Offset := ULONG(LSlotIdx) * CSendBufSize;
    LBuf.Length := ULONG(LSendLen);
  end
  else
  begin
    // Fallback: per-op registration for oversized or pool-exhausted sends
    LSendCtx^.SlotIdx := -1;
    LSendCtx^.BufId := TFnRegBuf(FRio.RIORegisterBuffer)(
      PAnsiChar(@AData[0]), Length(AData));
    if LSendCtx^.BufId = CRIOInvalidBufId then
    begin
      Dispose(LSendCtx);
      LRelTmp := AData;                 // AData is const; Release needs a var
      TBufferPool.Release(LRelTmp);
      FCallbacks.OnConnError(AConn);
      Exit;
    end;
    LBuf.BufferId := LSendCtx^.BufId;
    LBuf.Offset := 0;
    LBuf.Length := ULONG(LSendLen);
  end;

  LReqCtx := (UInt64(LSendCtx) and $FFFFFFFFFFFFFFFE) or CTagSend;
  LConn.AddRef;

  if not TFnSend(FRio.RIOSend)(LConn.RioRQ, @LBuf, 1, 0,
    Pointer(LReqCtx)) then
  begin
    LConn.Release;
    if LSendCtx^.SlotIdx >= 0 then
      _SendPoolRelease(LSendCtx^.SlotIdx)
    else
      TFnDeregBuf(FRio.RIODeregisterBuffer)(LSendCtx^.BufId);
    TBufferPool.Release(LSendCtx^.SendBuf);
    Dispose(LSendCtx);
    FCallbacks.OnConnError(AConn);
  end;
end;

procedure TRIOBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
var
  LConn: TNativeConn absolute AConn;
  LHLen: Integer;
  LBLen: Integer;
  LSendCtx: PRIOSendCtx;
  LBufH: TRIO_BUF;
  LBufB: TRIO_BUF;
  LReqCtx: UInt64;
  LSlotH: Integer;
  LSlotB: Integer;
  LConcat: TBytes;
  LTmpH: TBytes;
  LTmpB: TBytes;
begin
  LHLen := AHdrLen;
  if LHLen = 0 then LHLen := Length(AHeaders);
  LBLen := ABodyLen;
  if LBLen = 0 then LBLen := Length(ABody);

  if LHLen + LBLen = 0 then
  begin
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  // Single buffer — delegate to PostSend
  if LHLen = 0 then
  begin
    PostSend(AConn, ABody, LBLen);
    Exit;
  end;
  if LBLen = 0 then
  begin
    PostSend(AConn, AHeaders, LHLen);
    Exit;
  end;

  // Both parts present — try two-slot approach with RIO_MSG_DEFER
  LSlotH := -1;
  LSlotB := -1;
  if LHLen <= CSendBufSize then
    LSlotH := _SendPoolAcquire;
  if (LSlotH >= 0) and (LBLen <= CSendBufSize) then
    LSlotB := _SendPoolAcquire;

  if (LSlotH < 0) or (LSlotB < 0) then
  begin
    // Fallback: concatenate into single buffer
    if LSlotH >= 0 then _SendPoolRelease(LSlotH);
    LConcat := TBufferPool.Acquire(LHLen + LBLen);
    Move(AHeaders[0], LConcat[0], LHLen);
    Move(ABody[0], LConcat[LHLen], LBLen);
    LTmpH := AHeaders; TBufferPool.Release(LTmpH);
    LTmpB := ABody;    TBufferPool.Release(LTmpB);
    PostSend(AConn, LConcat, LHLen + LBLen);
    Exit;
  end;

  // Two-send with RIO_MSG_DEFER — avoids concatenation memcpy
  New(LSendCtx);
  LSendCtx^.Conn := LConn;
  LSendCtx^.SendBuf := AHeaders;
  LSendCtx^.BodyBuf := ABody;
  LSendCtx^.SlotIdx := LSlotH;
  LSendCtx^.SlotIdx2 := LSlotB;
  LSendCtx^.BufId := nil;
  LSendCtx^.BufId2 := nil;
  LSendCtx^.ActualLen := LHLen + LBLen;
  LSendCtx^.Remaining := 2;

  Move(AHeaders[0], _SendSlotPtr(LSlotH)^, LHLen);
  Move(ABody[0], _SendSlotPtr(LSlotB)^, LBLen);

  LBufH.BufferId := FSendPoolBufId;
  LBufH.Offset := ULONG(LSlotH) * CSendBufSize;
  LBufH.Length := ULONG(LHLen);

  LBufB.BufferId := FSendPoolBufId;
  LBufB.Offset := ULONG(LSlotB) * CSendBufSize;
  LBufB.Length := ULONG(LBLen);

  LReqCtx := (UInt64(LSendCtx) and $FFFFFFFFFFFFFFFE) or CTagSend;
  LConn.AddRef;
  LConn.AddRef;

  if not TFnSend(FRio.RIOSend)(LConn.RioRQ, @LBufH, 1, CRioMsgDefer,
    Pointer(LReqCtx)) then
  begin
    LConn.Release;
    LConn.Release;
    _SendPoolRelease(LSlotH);
    _SendPoolRelease(LSlotB);
    TBufferPool.Release(LSendCtx^.SendBuf);
    TBufferPool.Release(LSendCtx^.BodyBuf);
    Dispose(LSendCtx);
    FCallbacks.OnConnError(AConn);
    Exit;
  end;

  if not TFnSend(FRio.RIOSend)(LConn.RioRQ, @LBufB, 1, 0,
    Pointer(LReqCtx)) then
  begin
    // First deferred send already accepted by kernel — SlotH cannot be freed
    // here. Mark Remaining=1 so the CQ completion for the first send will
    // clean up SlotH, HeaderBuf and Dispose the context.
    LSendCtx^.Remaining := 1;
    LSendCtx^.ActualLen := -1;  // signal error to CQ completion handler
    LSendCtx^.SlotIdx2 := -2;   // mark second slot as not submitted
    LConn.Release;  // drop ref for the second (failed) send only
    _SendPoolRelease(LSlotB);
    TBufferPool.Release(LSendCtx^.BodyBuf);
    LSendCtx^.BodyBuf := nil;
    FCallbacks.OnConnError(AConn);
  end;
end;

procedure TRIOBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LSock: TSocket;
begin
  LConn.RioRQ := nil;
  // #173: invalidate the conn's handle copy before recycling the descriptor.
  LSock := LConn.Socket;
  LConn.Socket := INVALID_SOCKET;
  shutdown(LSock, SD_SEND);
  if not TSocketPool.Recycle(LSock) then
    closesocket(LSock);
end;

// ---------------------------------------------------------------------------
// Accept thread
// ---------------------------------------------------------------------------

procedure TRIOBackend._Accept;
var
  LClient: TSocket;
  LAddr: TSockAddrIn;
  LAddrLen: Integer;
  LRemoteIP: AnsiString;
  LOne: Integer;
begin
  while True do
  begin
    FillChar(LAddr, SizeOf(LAddr), 0);
    LAddrLen := SizeOf(LAddr);
    LClient := _WsaAccept(FListenSocket, @LAddr, @LAddrLen);
    if LClient = INVALID_SOCKET then Break;

    LOne := 1;
    setsockopt(LClient, IPPROTO_TCP, TCP_NODELAY,
      PAnsiChar(@LOne), SizeOf(LOne));
    setsockopt(LClient, SOL_SOCKET, SO_KEEPALIVE,
      PAnsiChar(@LOne), SizeOf(LOne));

    LRemoteIP := inet_ntoa(LAddr.sin_addr);
    try
      FCallbacks.OnNewConn(NativeUInt(LClient),
        string(LRemoteIP) + ':' + IntToStr(ntohs(LAddr.sin_port)));
    except
      if not TSocketPool.Recycle(LClient) then
        closesocket(LClient);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Worker loop — zero-syscall poll
// ---------------------------------------------------------------------------

procedure TRIOBackend._WorkerLoop(ACQIdx: Integer);
var
  LResults: array[0..255] of TRIO_RESULT;
  LCount: ULONG;
  I: Integer;
  LReqCtx: UInt64;
  LConn: TNativeConn;
  LSlotIdx: Integer;
  LSendCtx: PRIOSendCtx;
  LBytesXfer: DWORD;
  LCompKey: NativeUInt;
  LOverlapped: POverlapped;
  LHadError: Boolean;
begin
  while TInterlocked.Read(FShutdown) = 0 do
  begin
    TFnNotify(FRio.RIONotify)(FCQs[ACQIdx]);

    // Block until notification or timeout (100ms handles Notify/drain race)
    GetQueuedCompletionStatus(FWorkerIOCPs[ACQIdx],
      LBytesXfer, LCompKey, LOverlapped, 100);

    if TInterlocked.Read(FShutdown) <> 0 then Break;

    // Burst dequeue — drain all available completions
    while True do
    begin
      LCount := TFnDequeue(FRio.RIODequeueCompletion)(
        FCQs[ACQIdx], @LResults[0], 256);

      if LCount = CRioCorruptCQ then
      begin
        Writeln(ErrOutput, '[rio] FATAL: CQ corruption on worker ', ACQIdx);
        TInterlocked.Exchange(FShutdown, 1);
        Break;
      end;
      if LCount = 0 then Break;

      for I := 0 to Integer(LCount) - 1 do
      begin
        LConn := TNativeConn(Pointer(LResults[I].SocketContext));
        LReqCtx := UInt64(LResults[I].RequestContext);

        try
          if (LReqCtx and 1) = 0 then
          begin
            // RECV completion
            LSlotIdx := Integer(LReqCtx shr 1);
            try
              if (LResults[I].Status <> 0) or (LResults[I].BytesTransferred = 0) then
              begin
                _RecvPoolRelease(LSlotIdx);
                FCallbacks.OnConnError(LConn);
              end
              else
              begin
                FCallbacks.OnRecv(LConn, _RecvSlotPtr(LSlotIdx),
                  LResults[I].BytesTransferred);
                _RecvPoolRelease(LSlotIdx);
              end;
            finally
              LConn.Release;
            end;
          end
          else
          begin
            // SEND completion
            LSendCtx := PRIOSendCtx(Pointer(LReqCtx and $FFFFFFFFFFFFFFFE));

            Dec(LSendCtx^.Remaining);

            if (LResults[I].Status <> 0) or (LResults[I].BytesTransferred = 0) then
              LSendCtx^.ActualLen := -1;

            if LSendCtx^.Remaining > 0 then
            begin
              // More completions expected — just release conn ref
              LConn.Release;
            end
            else
            begin
              // Last completion — full cleanup
              if LSendCtx^.SlotIdx >= 0 then
                _SendPoolRelease(LSendCtx^.SlotIdx);
              if LSendCtx^.SlotIdx2 >= 0 then
                _SendPoolRelease(LSendCtx^.SlotIdx2);
              if (LSendCtx^.BufId <> nil) and (LSendCtx^.BufId <> CRIOInvalidBufId) then
                TFnDeregBuf(FRio.RIODeregisterBuffer)(LSendCtx^.BufId);
              if (LSendCtx^.BufId2 <> nil) and (LSendCtx^.BufId2 <> CRIOInvalidBufId) then
                TFnDeregBuf(FRio.RIODeregisterBuffer)(LSendCtx^.BufId2);

              TBufferPool.Release(LSendCtx^.SendBuf);
              if LSendCtx^.BodyBuf <> nil then
                TBufferPool.Release(LSendCtx^.BodyBuf);

              LHadError := LSendCtx^.ActualLen = -1;
              Dispose(LSendCtx);

              try
                if LHadError then
                  FCallbacks.OnConnError(LConn)
                else
                  FCallbacks.OnSendComplete(LConn);
              finally
                LConn.Release;
              end;
            end;
          end;
        except
          on E: Exception do
            Writeln(ErrOutput, '[rio] WORKER_EX [', E.ClassName, ']: ', E.Message);
        end;
      end;
    end;
  end;
end;

{$ELSE}

interface
implementation

{$ENDIF MSWINDOWS}

end.
