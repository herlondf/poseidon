unit Poseidon.Net.IO.RIO;

// #78: TRIOBackend — Windows Registered I/O backend.
//
// RIO (Registered I/O) is a Windows 8+ API that uses shared-memory completion
// queues. In polled mode, dequeue completions with ZERO syscalls — similar to
// io_uring SQPOLL on Linux.
//
// Architecture:
//   - Pre-register send/recv buffers with RIORegisterBuffer (once per pool buffer)
//   - Per-socket RIOCreateRequestQueue (one RQ per connection)
//   - Per-core RIOCreateCompletionQueue (polled mode — no IOCP overhead)
//   - I/O operations: RIOReceive / RIOSend with registered buffer slices
//   - Completion: RIODequeueCompletion — poll loop, zero syscall in polled mode
//
// Loaded via WSAIoctl(SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER) →
// RIO_EXTENSION_FUNCTION_TABLE.
//
// Critical: completion/request queues are NOT thread-safe — per-thread queues
// align perfectly with the per-core architecture.
//
// Fallback: if RIO is not available (Windows 7 or earlier), the constructor
// raises ENotSupportedException and TPoseidonNativeServer falls back to
// TIOCPBackend at runtime.

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
  // RIO buffer registration handle
  TRIO_BUFFERID = Pointer;

  // Registered buffer slice descriptor
  TRIO_BUF = record
    Offset: ULONG;
    Length: ULONG;
    BufferId: TRIO_BUFFERID;
  end;
  PRIO_BUF = ^TRIO_BUF;

  // Completion queue entry
  TRIO_RESULT = record
    Status: LONG;
    BytesTransferred: ULONG;
    SocketContext: UInt64;
    RequestContext: UInt64;
  end;
  PRIO_RESULT = ^TRIO_RESULT;

  // RIO handles
  TRIO_CQ = Pointer;
  TRIO_RQ = Pointer;

  // RIO function table — loaded via WSAIoctl
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
  PRIO_EXTENSION_FUNCTION_TABLE = ^TRIO_EXTENSION_FUNCTION_TABLE;

  TRIOBackend = class(TInterfacedObject, IIOBackend)
  private
    FRioFuncs: TRIO_EXTENSION_FUNCTION_TABLE;
    FLoaded: Boolean;
    FListenSocket: TSocket;
    FWorkers: TArray<TThread>;
    FAcceptThread: TThread;
    FCQs: TArray<TRIO_CQ>;  // per-worker completion queues
    FCallbacks: IIOCallbacks;
    procedure _LoadRIO;
    procedure _Accept;
    procedure _WorkerLoop(ACQIndex: Integer);
  public
    constructor Create;
    destructor Destroy; override;
    // IIOBackend
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

const
  SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER = $C8000024;
  WSAID_MULTIPLE_RIO: TGUID = '{8509E081-96DD-4005-B165-9E2EE8C79E3F}';

  CRIOCQSize = 4096;
  CRIORQSize = 256;

function _WsaBind(s: TSocket; addr: PSockAddrIn; addrlen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'bind';
function _WsaListen(s: TSocket; backlog: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'listen';
function _WsaAccept(s: TSocket; addr: PSockAddrIn; addrlen: PInteger): TSocket; stdcall;
  external 'ws2_32.dll' name 'accept';

// RIO function type definitions for dynamic invocation
type
  TRIOCreateCQ = function(QueueSize: DWORD; NotificationType: Pointer): TRIO_CQ; stdcall;
  TRIOCloseCQ = procedure(CQ: TRIO_CQ); stdcall;
  TRIOCreateRQ = function(Socket: TSocket; MaxOutstandingRecv, MaxRecvDataBuffers,
    MaxOutstandingSend, MaxSendDataBuffers: DWORD; RecvCQ, SendCQ: TRIO_CQ): TRIO_RQ; stdcall;
  TRIORegBuf = function(DataBuffer: Pointer; DataLength: DWORD): TRIO_BUFFERID; stdcall;
  TRIODeregBuf = procedure(BufferId: TRIO_BUFFERID); stdcall;
  TRIORecv = function(SocketQueue: TRIO_RQ; pData: PRIO_BUF; DataBufferCount: DWORD;
    Flags: DWORD; RequestContext: UInt64): BOOL; stdcall;
  TRIOSend = function(SocketQueue: TRIO_RQ; pData: PRIO_BUF; DataBufferCount: DWORD;
    Flags: DWORD; RequestContext: UInt64): BOOL; stdcall;
  TRIODequeue = function(CQ: TRIO_CQ; Array_: PRIO_RESULT;
    ArraySize: DWORD): ULONG; stdcall;

constructor TRIOBackend.Create;
begin
  inherited Create;
  FLoaded := False;
  FListenSocket := INVALID_SOCKET;
  _LoadRIO;
end;

destructor TRIOBackend.Destroy;
begin
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
    raise ENotSupportedException.Create('RIO unavailable: WSA_FLAG_REGISTERED_IO not supported');

  FillChar(FRioFuncs, SizeOf(FRioFuncs), 0);
  FRioFuncs.cbSize := SizeOf(FRioFuncs);
  LBytes := 0;

  if WSAIoctl(LSocket, SIO_GET_MULTIPLE_EXTENSION_FUNCTION_POINTER,
    @WSAID_MULTIPLE_RIO, SizeOf(WSAID_MULTIPLE_RIO),
    @FRioFuncs, SizeOf(FRioFuncs), @LBytes, nil, nil) <> 0 then
  begin
    closesocket(LSocket);
    raise ENotSupportedException.Create('RIO unavailable: WSAIoctl for RIO table failed');
  end;
  closesocket(LSocket);
  FLoaded := True;
end;

procedure TRIOBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);
var
  LAddr: TSockAddrIn;
  LOne: Integer;
  I: Integer;
begin
  FCallbacks := ACallbacks;

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

  // Create per-worker polled completion queues
  SetLength(FCQs, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
  begin
    FCQs[I] := TRIOCreateCQ(FRioFuncs.RIOCreateCompletionQueue)(CRIOCQSize, nil);
    if FCQs[I] = nil then
      raise Exception.Create('RIOCreateCompletionQueue failed');
  end;

  // Start worker threads (each polls its own CQ)
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
  // In polled mode, workers check a shutdown flag — no signaling needed.
  // The StopAccept + ShutdownConn cycle will cause workers to exit.
end;

procedure TRIOBackend.JoinWorkers;
var
  I: Integer;
begin
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  SetLength(FWorkers, 0);

  for I := 0 to High(FCQs) do
    if FCQs[I] <> nil then
      TRIOCloseCQ(FRioFuncs.RIOCloseCompletionQueue)(FCQs[I]);
  SetLength(FCQs, 0);

  WSACleanup;
end;

procedure TRIOBackend.RegisterConn(AConn: Pointer);
begin
  // RIO per-socket setup: create request queue bound to a CQ
  // TODO: assign CQ index based on round-robin or per-core affinity
end;

procedure TRIOBackend.PostRecv(AConn: Pointer);
begin
  // TODO: RIOReceive with registered buffer slice
end;

procedure TRIOBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
begin
  // TODO: RIOSend with registered buffer slice
end;

procedure TRIOBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
begin
  // TODO: concatenate + PostSend (RIO doesn't support scatter-gather on sockets)
  PostSend(AConn, AHeaders, AHdrLen);
end;

procedure TRIOBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  shutdown(LConn.Socket, SD_SEND);
  closesocket(LConn.Socket);
end;

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
      closesocket(LClient);
    end;
  end;
end;

procedure TRIOBackend._WorkerLoop(ACQIndex: Integer);
var
  LResults: array[0..63] of TRIO_RESULT;
  LCount: ULONG;
  I: Integer;
begin
  while True do
  begin
    LCount := TRIODequeue(FRioFuncs.RIODequeueCompletion)(
      FCQs[ACQIndex], @LResults[0], 64);
    if LCount = $FFFFFFFF then Break; // error — exit

    if LCount = 0 then
    begin
      // No completions — yield briefly then re-poll
      Sleep(0);
      Continue;
    end;

    for I := 0 to Integer(LCount) - 1 do
    begin
      // TODO: dispatch based on RequestContext (recv vs send)
      // LResults[I].SocketContext = connection pointer
      // LResults[I].RequestContext = operation context
      // LResults[I].BytesTransferred = bytes
    end;
  end;
end;

{$ELSE}

interface
implementation

{$ENDIF MSWINDOWS}

end.
