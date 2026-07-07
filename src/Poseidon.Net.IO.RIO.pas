unit Poseidon.Net.IO.RIO;

// #78: TRIOBackend — Windows Registered I/O backend.
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
    Offset: ULONG;
    Length: ULONG;
    BufferId: TRIO_BUFFERID;
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
    // Union — we use polled mode (type=0), no further fields needed
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
    FShutdown: Boolean;
    FNextCQ: Integer;
    // Pre-allocated recv pool
    FRecvPool: Pointer;
    FRecvPoolBufId: TRIO_BUFFERID;
    FRecvFreeStack: array of Integer;
    FRecvFreeTop: Integer;
    FRecvPoolLock: TCriticalSection;
    procedure _LoadRIO;
    procedure _Accept;
    procedure _WorkerLoop(ACQIdx: Integer);
    function _RecvPoolAcquire: Integer;
    procedure _RecvPoolRelease(AIdx: Integer);
    function _RecvSlotPtr(AIdx: Integer): PByte;
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

  CRecvBufSize  = 32768;
  CRecvPoolSize = 512;
  CRecvPoolBytes = CRecvPoolSize * CRecvBufSize;
  CRIOCQSize = 4096;
  CRIORQRecv = 32;
  CRIORQSend = 32;

  // RequestContext encoding: low bit = action, rest = context index/pointer
  CTagRecv = UInt64(0);
  CTagSend = UInt64(1);

type
  // RIO function types
  TFnCreateCQ = function(QueueSize: DWORD; NotificationCompletion: PRIO_NOTIFICATION_COMPLETION): TRIO_CQ; stdcall;
  TFnCloseCQ = procedure(CQ: TRIO_CQ); stdcall;
  TFnCreateRQ = function(Socket: TSocket; MaxOutstandingRecv, MaxRecvDataBuffers,
    MaxOutstandingSend, MaxSendDataBuffers: DWORD; RecvCQ, SendCQ: TRIO_CQ): TRIO_RQ; stdcall;
  TFnRegBuf = function(DataBuffer: PAnsiChar; DataLength: DWORD): TRIO_BUFFERID; stdcall;
  TFnDeregBuf = procedure(BufferId: TRIO_BUFFERID); stdcall;
  TFnRecv = function(SocketQueue: TRIO_RQ; pData: PRIO_BUF; DataBufferCount: ULONG;
    Flags: DWORD; RequestContext: Pointer): BOOL; stdcall;
  TFnSend = function(SocketQueue: TRIO_RQ; pData: PRIO_BUF; DataBufferCount: ULONG;
    Flags: DWORD; RequestContext: Pointer): BOOL; stdcall;
  TFnDequeue = function(CQ: TRIO_CQ; Array_: PRIO_RESULT;
    ArraySize: DWORD): ULONG; stdcall;

  // Send context — heap-allocated, holds buffer reference until completion
  PRIOSendCtx = ^TRIOSendCtx;
  TRIOSendCtx = record
    Conn: TNativeConn;
    SendBuf: TBytes;
    BufId: TRIO_BUFFERID;
    ActualLen: Integer;
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
begin
  inherited Create;
  FListenSocket := INVALID_SOCKET;
  FShutdown := False;
  FNextCQ := 0;
  FRecvPool := nil;
  FRecvPoolBufId := nil;
  FRecvPoolLock := TCriticalSection.Create;
  _LoadRIO;

  // Pre-allocate contiguous recv buffer pool and register with RIO
  FRecvPool := VirtualAlloc(nil, CRecvPoolBytes, MEM_COMMIT or MEM_RESERVE,
    PAGE_READWRITE);
  if FRecvPool = nil then
    raise Exception.Create('VirtualAlloc for RIO recv pool failed');

  FRecvPoolBufId := TFnRegBuf(FRio.RIORegisterBuffer)(PAnsiChar(FRecvPool),
    CRecvPoolBytes);
  if FRecvPoolBufId = Pointer($FFFFFFFF) then
    raise Exception.Create('RIORegisterBuffer for recv pool failed');

  SetLength(FRecvFreeStack, CRecvPoolSize);
  FRecvFreeTop := CRecvPoolSize;
  var I: Integer;
  for I := 0 to CRecvPoolSize - 1 do
    FRecvFreeStack[I] := I;
end;

destructor TRIOBackend.Destroy;
begin
  if (FRecvPoolBufId <> nil) and (FRecvPoolBufId <> Pointer($FFFFFFFF)) then
    TFnDeregBuf(FRio.RIODeregisterBuffer)(FRecvPoolBufId);
  if FRecvPool <> nil then
    VirtualFree(FRecvPool, 0, MEM_RELEASE);
  FreeAndNil(FRecvPoolLock);
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
    @FRio, SizeOf(FRio), @LBytes, nil, nil) <> 0 then
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
// IIOBackend — lifecycle
// ---------------------------------------------------------------------------

procedure TRIOBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);
var
  LAddr: TSockAddrIn;
  LOne: Integer;
  I: Integer;
begin
  FCallbacks := ACallbacks;
  FShutdown := False;

  FListenSocket := WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, nil, 0,
    WSA_FLAG_REGISTERED_IO);
  if FListenSocket = INVALID_SOCKET then
    RaiseLastOSError;

  LOne := 1;
  setsockopt(FListenSocket, SOL_SOCKET, SO_REUSEADDR,
    PAnsiChar(@LOne), SizeOf(LOne));
  if AFastOpen then
    setsockopt(FListenSocket, IPPROTO_TCP, 15 {TCP_FASTOPEN},
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

  // Per-worker polled completion queues
  SetLength(FCQs, AWorkerCount);
  SetLength(FCQLocks, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
  begin
    FCQs[I] := TFnCreateCQ(FRio.RIOCreateCompletionQueue)(CRIOCQSize, nil);
    if FCQs[I] = nil then
      raise Exception.Create('RIOCreateCompletionQueue failed');
    FCQLocks[I] := TCriticalSection.Create;
  end;

  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
  begin
    var LIdx := I;
    FWorkers[I] := TThread.CreateAnonymousThread(
      procedure begin _WorkerLoop(LIdx); end);
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
begin
  shutdown(LConn.Socket, SD_BOTH);
end;

procedure TRIOBackend.SignalWorkers;
begin
  FShutdown := True;
end;

procedure TRIOBackend.JoinWorkers;
var
  I: Integer;
begin
  FShutdown := True;
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
  LCQIdx := TInterlocked.Increment(FNextCQ) mod Length(FCQs);

  // Create per-socket request queue bound to recv CQ and send CQ (same CQ)
  FCQLocks[LCQIdx].Enter;
  try
    LRQ := TFnCreateRQ(FRio.RIOCreateRequestQueue)(
      LConn.Socket, CRIORQRecv, 1, CRIORQSend, 1,
      FCQs[LCQIdx], FCQs[LCQIdx]);
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

  // Register the send buffer with RIO
  LSendCtx^.BufId := TFnRegBuf(FRio.RIORegisterBuffer)(
    PAnsiChar(@AData[0]), Length(AData));
  if LSendCtx^.BufId = Pointer($FFFFFFFF) then
  begin
    Dispose(LSendCtx);
    TBufferPool.Release(AData);
    FCallbacks.OnConnError(AConn);
    Exit;
  end;

  LBuf.BufferId := LSendCtx^.BufId;
  LBuf.Offset := 0;
  LBuf.Length := ULONG(LSendLen);

  // Encode: pointer to send context in high bits, tag send in low bit
  LReqCtx := (UInt64(LSendCtx) and $FFFFFFFFFFFFFFFE) or CTagSend;

  LConn.AddRef;

  if not TFnSend(FRio.RIOSend)(LConn.RioRQ, @LBuf, 1, 0,
    Pointer(LReqCtx)) then
  begin
    LConn.Release;
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
  LHLen, LBLen: Integer;
  LConcat: TBytes;
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

  // RIO doesn't support scatter-gather — concatenate into pool buffer
  LConcat := TBufferPool.Acquire(LHLen + LBLen);
  if LHLen > 0 then Move(AHeaders[0], LConcat[0], LHLen);
  if LBLen > 0 then Move(ABody[0], LConcat[LHLen], LBLen);

  PostSend(AConn, LConcat, LHLen + LBLen);
end;

procedure TRIOBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  LConn.RioRQ := nil;
  shutdown(LConn.Socket, SD_SEND);
  if not TSocketPool.Recycle(LConn.Socket) then
    closesocket(LConn.Socket);
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
  LResults: array[0..63] of TRIO_RESULT;
  LCount: ULONG;
  I: Integer;
  LReqCtx: UInt64;
  LConn: TNativeConn;
  LSlotIdx: Integer;
  LSendCtx: PRIOSendCtx;
  LSpinCount: Integer;
begin
  LSpinCount := 0;
  while not FShutdown do
  begin
    FCQLocks[ACQIdx].Enter;
    try
      LCount := TFnDequeue(FRio.RIODequeueCompletion)(
        FCQs[ACQIdx], @LResults[0], 64);
    finally
      FCQLocks[ACQIdx].Leave;
    end;

    if LCount = $FFFFFFFF then Break;

    if LCount = 0 then
    begin
      Inc(LSpinCount);
      // Adaptive spin: yield → sleep(0) → sleep(1)
      if LSpinCount < 1000 then
        TThread.SpinWait(32)
      else if LSpinCount < 5000 then
        Sleep(0)
      else
        Sleep(1);
      Continue;
    end;

    LSpinCount := 0;

    for I := 0 to Integer(LCount) - 1 do
    begin
      LConn := TNativeConn(Pointer(LResults[I].SocketContext));
      LReqCtx := UInt64(LResults[I].RequestContext);

      try
        if (LReqCtx and 1) = 0 then
        begin
          // RECV completion
          LSlotIdx := Integer(LReqCtx shr 1);

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
          LConn.Release;
        end
        else
        begin
          // SEND completion
          LSendCtx := PRIOSendCtx(Pointer(LReqCtx and $FFFFFFFFFFFFFFFE));

          TFnDeregBuf(FRio.RIODeregisterBuffer)(LSendCtx^.BufId);

          if (LResults[I].Status <> 0) then
          begin
            TBufferPool.Release(LSendCtx^.SendBuf);
            Dispose(LSendCtx);
            FCallbacks.OnConnError(LConn);
          end
          else
          begin
            TBufferPool.Release(LSendCtx^.SendBuf);
            Dispose(LSendCtx);
            FCallbacks.OnSendComplete(LConn);
          end;
          LConn.Release;
        end;
      except
        on E: Exception do
          Writeln(ErrOutput, '[rio] WORKER_EX [', E.ClassName, ']: ', E.Message);
      end;
    end;
  end;
end;

{$ELSE}

interface
implementation

{$ENDIF MSWINDOWS}

end.
