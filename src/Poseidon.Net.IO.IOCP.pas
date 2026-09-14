unit Poseidon.Net.IO.IOCP;

// TIOCPBackend - Windows IOCP (I/O Completion Ports) backend.
// R-1: extracted from Poseidon.Net.HttpServer.  All platform-specific Windows
// socket code lives here; HttpServer.pas now references this unit only at
// construction time via a single {$IFDEF MSWINDOWS}.

{$IFDEF MSWINDOWS}

interface

uses
  {$IFDEF FPC}
  // Windows/WinSock2 first, RTL last: later units win name clashes, so the RTL
  // TCriticalSection/TBytes/TThread beat the Win32 look-alikes.
  Windows,
  WinSock2,
  SysUtils,
  Classes,
  syncobjs,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Winapi.Windows,
  Winapi.Winsock2,
  {$ENDIF}
  Poseidon.Net.IO,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.Pool.Socket;

type
  TIOCPBackend = class(TInterfacedObject, IIOBackend)
  private
    FIocp: THandle;
    FListenSocket: TSocket;
    FWorkers: TArray<TThread>;
    FCallbacks: IIOCallbacks;
    FShutdown: Int64;  // 0=running, 1=shutdown; atomic via TInterlocked (Read requires Int64)
    FAcceptEx: Pointer;
    FGetAcceptExSockaddrs: Pointer;
    FAcceptCtxs: array of Pointer;  // PAcceptCtx, allocated in StartListening
    FDisconnectEx: Pointer;
    FSocketPool: TSocketPool;  // #225: instance-owned, never shared across backends
    procedure _LoadExtensions;
    procedure _PostOneAccept(AIdx: Integer; ARetriesLeft: Integer = 3);
    procedure _WorkerLoop;
    procedure _OnRecvReady(AConn: Pointer);
    function DrainCompletions(ATimeoutMs: Cardinal;
      ATarget: Pointer = nil): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    procedure StartListening(const AHost: string; APort: Integer;
      AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
      AAcceptThreads: Integer = 1);
    procedure SetInlineDispatch(AEnabled: Boolean);
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
    procedure SocketClose(AConn: Pointer; AFinalTeardown: Boolean = False);
  end;

implementation

uses
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.HttpServer;

// #223: WSAStartup/WSACleanup are process-wide (refcounted internally by
// Winsock itself), but each TIOCPBackend instance previously called
// WSAStartup on Start and WSACleanup on JoinWorkers unconditionally. Two
// TPoseidonNativeServer instances created sequentially in one process (as
// DUnitX's SyncDispatch and async DeferredResponse fixtures do - the
// second's SetupFixture runs right after the first's TeardownFixture) can
// then race: the first instance's WSACleanup tears down Winsock
// process-wide for however long it takes the second instance to call
// WSAStartup again, and ANY other Winsock user active in that window (this
// test suite's own raw-socket HTTP client included, which never calls
// WSAStartup itself and relies on some server instance having already done
// so) sees connect()/socket() fail with no server-side error at all - this
// got much easier to hit once Stop() itself got fast (see the drain-loop
// fix above), leaving less incidental time for things to settle.
// Fix: initialize Winsock at most once per process and never tear it down
// during normal operation - the standard pattern for a library that can't
// know whether it is the process's only Winsock user. WSACleanup is
// harmless to skip; Windows reclaims everything at process exit regardless.
var
  GWinsockStarted: Integer;  // 0 = not yet, 1 = started; CAS-guarded, never reset

procedure _WinsockAcquire;
var
  LWsaData: TWSAData;
begin
  if TInterlocked.CompareExchange(GWinsockStarted, 1, 0) = 0 then
    if WSAStartup($0202, LWsaData) <> 0 then
      raise Exception.Create('WSAStartup failed');
end;


function _IocpCreate(FileH, Existing: THandle; Key: NativeUInt;
  Threads: DWORD): THandle; stdcall;
  external 'kernel32.dll' name 'CreateIoCompletionPort';

function _IocpGet(Port: THandle; pBytes: PDWORD; pKey: PNativeUInt;
  pOvl: PPointer; Ms: DWORD): BOOL; stdcall;
  external 'kernel32.dll' name 'GetQueuedCompletionStatus';

type
  TOVERLAPPED_ENTRY = record
    lpCompletionKey: NativeUInt;
    lpOverlapped: Pointer;
    Internal: NativeUInt;
    dwNumberOfBytesTransferred: DWORD;
  end;
  POVERLAPPED_ENTRY = ^TOVERLAPPED_ENTRY;

function _IocpGetEx(Port: THandle; lpEntries: POVERLAPPED_ENTRY;
  ulCount: ULONG; ulNumEntriesRemoved: PULONG;
  dwMs: DWORD; fAlertable: BOOL): BOOL; stdcall;
  external 'kernel32.dll' name 'GetQueuedCompletionStatusEx';

function _IocpPost(Port: THandle; Bytes: DWORD; Key: NativeUInt;
  pOvl: Pointer): BOOL; stdcall;
  external 'kernel32.dll' name 'PostQueuedCompletionStatus';

function _SetFileCompletionNotificationModes(FileHandle: THandle;
  Flags: Byte): BOOL; stdcall;
  external 'kernel32.dll' name 'SetFileCompletionNotificationModes';

const
  FILE_SKIP_COMPLETION_PORT_ON_SUCCESS = $01;
  FILE_SKIP_SET_EVENT_ON_HANDLE = $02;

function _CancelIoEx(hFile: THandle; lpOverlapped: POverlapped): BOOL; stdcall;
  external 'kernel32.dll' name 'CancelIoEx';

function _WsaBind(s: TSocket; addr: PSockAddrIn; addrlen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'bind';

function _WsaListen(s: TSocket; backlog: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'listen';

// Static mswsock exports - fallback for when WSAIoctl(SIO_GET_EXTENSION_FUNCTION_
// POINTER) is rejected (WSAEINVAL) by an intercepting Winsock provider/LSP
// (some VPN/proxy/security software). AcceptEx and GetAcceptExSockaddrs are
// exported by name from mswsock.dll, so we can bind them directly.
function _mswAcceptEx(sListenSocket, sAcceptSocket: TSocket; lpOutputBuffer: Pointer;
  dwReceiveDataLength: DWORD; dwLocalAddressLength, dwRemoteAddressLength: DWORD;
  lpdwBytesReceived: PDWORD; lpOverlapped: PWSAOverlapped): BOOL; stdcall;
  external 'mswsock.dll' name 'AcceptEx';
procedure _mswGetAcceptExSockaddrs(lpOutputBuffer: Pointer; dwReceiveDataLength: DWORD;
  dwLocalAddressLength, dwRemoteAddressLength: DWORD;
  var LocalSockaddr: PSockAddr; var LocalSockaddrLength: Integer;
  var RemoteSockaddr: PSockAddr; var RemoteSockaddrLength: Integer); stdcall;
  external 'mswsock.dll' name 'GetAcceptExSockaddrs';

const
  SIO_GET_EXTENSION_FUNCTION_POINTER = $C8000006;
  WSAID_ACCEPTEX: TGUID = '{B5367DF1-CBAC-11CF-95CA-00805F48A169}';
  WSAID_GETACCEPTEXSOCKADDRS: TGUID = '{B5367DF2-CBAC-11CF-95CA-00805F48A169}';

type
  TAcceptExFunc = function(sListenSocket, sAcceptSocket: TSocket;
    lpOutputBuffer: Pointer; dwReceiveDataLength: DWORD;
    dwLocalAddressLength, dwRemoteAddressLength: DWORD;
    lpdwBytesReceived: PDWORD; lpOverlapped: PWSAOverlapped): BOOL; stdcall;

  TGetAcceptExSockaddrsFunc = procedure(lpOutputBuffer: Pointer;
    dwReceiveDataLength: DWORD;
    dwLocalAddressLength, dwRemoteAddressLength: DWORD;
    var LocalSockaddr: PSockAddr; var LocalSockaddrLength: Integer;
    var RemoteSockaddr: PSockAddr; var RemoteSockaddrLength: Integer); stdcall;

  TDisconnectExFunc = function(ASocket: TSocket; AOverlapped: POverlapped;
    AFlags: DWORD; AReserved: DWORD): BOOL; stdcall;


const
  CTCP_FASTOPEN = 15;
  CSO_UPDATE_ACCEPT_CONTEXT = $700B;
  CSO_EXCLUSIVEADDRUSE = -5;
  CSIO_KEEPALIVE_VALS = $98000004;
  CRecvBufSize = 32768;
  CIocpBatchSize = 64;
  CAcceptPoolSize = 16;
  CAddrBufSize = (SizeOf(TSockAddrIn) + 16) * 2;
  CTF_REUSE_SOCKET = $02;
  CKeepAliveTime = 30000;
  CKeepAliveInterval = 5000;

type
  {$IFDEF FPC}
  // FPC's WinSock2 exposes WSABUF but not the Delphi TWsaBuf alias.
  TWsaBuf = WSABUF;
  {$ENDIF}

  TKeepAliveVals = record
    OnOff: Cardinal;
    KeepAliveTime: Cardinal;
    KeepAliveInterval: Cardinal;
  end;

  TIocpAction = (iaRecv, iaSend, iaSendV, iaAccept, iaDisconnect, iaRecvZero);

  PRecvCtx = ^TRecvCtx;
  TRecvCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Conn: Pointer;
    WsaBuf: TWsaBuf;
    Data: array[0..CRecvBufSize - 1] of Byte;
  end;

  PRecvZeroCtx = ^TRecvZeroCtx;
  TRecvZeroCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Conn: Pointer;
    WsaBuf: TWsaBuf;                // len=0, buf=nil
  end;

  PSendCtx = ^TSendCtx;
  TSendCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Conn: Pointer;
    WsaBuf: TWsaBuf;
    SendBuf: TBytes;
    ActualLen: Integer;
    SentBytes: Integer;
  end;

  PSendVCtx = ^TSendVCtx;
  TSendVCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Conn: Pointer;
    WsaBufs: array[0..1] of TWsaBuf;
    HeaderBuf: TBytes;
    BodyBuf: TBytes;
  end;

  PAcceptCtx = ^TAcceptCtx;
  TAcceptCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    AcceptSocket: TSocket;
    AddrBuf: array[0..CAddrBufSize - 1] of Byte;
  end;

  PDisconnectCtx = ^TDisconnectCtx;
  TDisconnectCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Socket: TSocket;
  end;

  PIocpHdr = ^TIocpHdr;
  TIocpHdr = record
    Ovl: TOverlapped;
    Action: TIocpAction;
    Conn: Pointer;
  end;


{$IFDEF FPC}
// FPC: IOCP workers are TThread subclasses, not CreateAnonymousThread. Threads
// created via CreateAnonymousThread under FPC 3.3.1 have an incomplete RTL
// context: the FIRST object/closure CONSTRUCTED on such a thread (e.g. the
// per-request dispatch job) access-violates. A real TThread subclass gets full
// per-thread init, so constructions on it work. Delphi keeps the anonymous form.
type
  TFPCIocpWorker = class(TThread)
  public
    Backend: TIOCPBackend;
    procedure Execute; override;
  end;

procedure TFPCIocpWorker.Execute;
begin
  Backend._WorkerLoop;
end;
{$ENDIF}

constructor TIOCPBackend.Create;
begin
  inherited Create;
  FIocp := 0;
  FListenSocket := INVALID_SOCKET;
  FShutdown := 0;
  FAcceptEx := nil;
  FGetAcceptExSockaddrs := nil;
  FDisconnectEx := nil;
  FSocketPool := TSocketPool.Create;
end;

destructor TIOCPBackend.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FAcceptCtxs) do
    if FAcceptCtxs[I] <> nil then
    begin
      if PAcceptCtx(FAcceptCtxs[I])^.AcceptSocket <> INVALID_SOCKET then
        closesocket(PAcceptCtx(FAcceptCtxs[I])^.AcceptSocket);
      Dispose(PAcceptCtx(FAcceptCtxs[I]));
    end;
  if FListenSocket <> INVALID_SOCKET then
  begin
    closesocket(FListenSocket);
    FListenSocket := INVALID_SOCKET;
  end;
  if FIocp <> 0 then
  begin
    CloseHandle(FIocp);
    FIocp := 0;
  end;
  FreeAndNil(FSocketPool);
  inherited Destroy;
end;

procedure TIOCPBackend._LoadExtensions;
var
  LBytes: DWORD;
  LGuid: TGUID;
  LRes: Integer;
begin
  LBytes := 0;
  LGuid := WSAID_ACCEPTEX;
  LRes := WSAIoctl(FListenSocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FAcceptEx, SizeOf(FAcceptEx), {$IFDEF FPC}@LBytes{$ELSE}LBytes{$ENDIF}, nil, nil);
  if (LRes <> 0) or (FAcceptEx = nil) then
    FAcceptEx := @_mswAcceptEx;  // fallback: static mswsock export

  LGuid := WSAID_GETACCEPTEXSOCKADDRS;
  LRes := WSAIoctl(FListenSocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FGetAcceptExSockaddrs, SizeOf(FGetAcceptExSockaddrs),
    {$IFDEF FPC}@LBytes{$ELSE}LBytes{$ENDIF}, nil, nil);
  if (LRes <> 0) or (FGetAcceptExSockaddrs = nil) then
    FGetAcceptExSockaddrs := @_mswGetAcceptExSockaddrs;  // fallback: static mswsock export

  LGuid := StringToGUID('{7FDA2E11-8630-436F-A031-F536A6EEC157}');
  LRes := WSAIoctl(FListenSocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FDisconnectEx, SizeOf(FDisconnectEx),
    {$IFDEF FPC}@LBytes{$ELSE}LBytes{$ENDIF}, nil, nil);
  if LRes <> 0 then
    FDisconnectEx := nil;  // DisconnectEx is optional; fallback to closesocket
end;

procedure TIOCPBackend._PostOneAccept(AIdx: Integer; ARetriesLeft: Integer);
var
  LCtx: PAcceptCtx;
  LAcceptSocket: TSocket;
  LBytes: DWORD;
begin
  LAcceptSocket := FSocketPool.Acquire;
  if LAcceptSocket = INVALID_SOCKET then
    LAcceptSocket := WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, nil, 0,
      WSA_FLAG_OVERLAPPED);
  if LAcceptSocket = INVALID_SOCKET then Exit;

  if FAcceptCtxs[AIdx] = nil then
  begin
    New(LCtx);
    FAcceptCtxs[AIdx] := LCtx;
  end
  else
    LCtx := PAcceptCtx(FAcceptCtxs[AIdx]);

  FillChar(LCtx^, SizeOf(TAcceptCtx), 0);
  LCtx^.Action := iaAccept;
  LCtx^.AcceptSocket := LAcceptSocket;
  LBytes := 0;

  if not TAcceptExFunc(FAcceptEx)(FListenSocket, LAcceptSocket,
    @LCtx^.AddrBuf[0], 0,
    SizeOf(TSockAddrIn) + 16, SizeOf(TSockAddrIn) + 16,
    @LBytes, PWSAOverlapped(@LCtx^.Ovl)) then
  begin
    if WSAGetLastError <> WSA_IO_PENDING then
    begin
      closesocket(LAcceptSocket);
      LCtx^.AcceptSocket := INVALID_SOCKET;
      // #223: AcceptEx can fail transiently (observed right after another
      // Winsock user in the same process tears down/reinitializes sockets -
      // e.g. two TPoseidonNativeServer instances cycling in one test
      // process). Previously this abandoned the slot forever with no retry
      // and no log; losing even a few of the CAcceptPoolSize slots this way
      // eventually starves the whole accept pool, matching the #224
      // io_uring accept-rearm bug in spirit. Retry a bounded number of
      // times before giving up on this slot for good.
      if (TInterlocked.Read(FShutdown) = 0) and (ARetriesLeft > 0) then
        _PostOneAccept(AIdx, ARetriesLeft - 1)
      else if ARetriesLeft <= 0 then
        Writeln(ErrOutput, '[iocp] AcceptEx slot ', AIdx,
          ' permanently failed to re-arm after retries (errno ',
          WSAGetLastError, ')');
    end;
  end;
end;

procedure TIOCPBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);
var
  LAddr: TSockAddrIn;
  LOne: Integer;
  I: Integer;
begin
  FCallbacks := ACallbacks;

  _WinsockAcquire;

  FIocp := _IocpCreate(INVALID_HANDLE_VALUE, 0, 0, 0);
  if FIocp = 0 then RaiseLastOSError;

  FListenSocket := WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, nil, 0,
    WSA_FLAG_OVERLAPPED);
  if FListenSocket = INVALID_SOCKET then RaiseLastOSError;

  LOne := 1;
  setsockopt(FListenSocket, SOL_SOCKET, CSO_EXCLUSIVEADDRUSE,
    PAnsiChar(@LOne), SizeOf(LOne));

  // TCP_FASTOPEN (RFC 7413) - opt-in; Windows 10 1607+
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

  FSocketPool.LoadDisconnectEx(FListenSocket);
  _LoadExtensions;

  if _IocpCreate(THandle(FListenSocket), FIocp, 0, 0) = 0 then
    raise Exception.Create('IOCP associate listen socket failed');

  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
  {$IFDEF FPC}
  begin
    FWorkers[I] := TFPCIocpWorker.Create(True);  // suspended; started below
    TFPCIocpWorker(FWorkers[I]).Backend := Self;
  end;
  {$ELSE}
    FWorkers[I] := TThread.CreateAnonymousThread(procedure begin _WorkerLoop; end);
  {$ENDIF}
  for I := 0 to AWorkerCount - 1 do
  begin
    FWorkers[I].FreeOnTerminate := False;
    FWorkers[I].Start;
  end;

  if FAcceptEx <> nil then
  begin
    SetLength(FAcceptCtxs, CAcceptPoolSize);
    for I := 0 to CAcceptPoolSize - 1 do
    begin
      FAcceptCtxs[I] := nil;
      _PostOneAccept(I);
    end;
  end;
end;

procedure TIOCPBackend.SetInlineDispatch(AEnabled: Boolean);
begin
  // No submission batching in the IOCP backend - no-op.
end;

procedure TIOCPBackend.StopAccept;
begin
  TInterlocked.Exchange(FShutdown, 1);
  closesocket(FListenSocket);
  FListenSocket := INVALID_SOCKET;
end;

procedure TIOCPBackend.ShutdownConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LSock: TSocket;
begin
  // #173: read the handle once; skip if SocketClose already invalidated it,
  // so we never shutdown() a descriptor recycled by another connection.
  LSock := LConn.Socket;
  if LSock <> INVALID_SOCKET then
    shutdown(LSock, SD_BOTH);
end;

procedure TIOCPBackend.SignalWorkers;
var
  I: Integer;
begin
  TInterlocked.Exchange(FShutdown, 1);
  for I := 0 to High(FWorkers) do
    _IocpPost(FIocp, 0, 0, nil);
end;

procedure TIOCPBackend.JoinWorkers;
var
  I: Integer;
begin
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  SetLength(FWorkers, 0);
  // #leak-conn-ctx: deliberately NOT closing FIocp here anymore. Stop()'s
  // step 5 (the forced straggler walk) runs after JoinWorkers returns and
  // calls SocketClose(..., True) on any connection still open, which itself
  // calls DrainCompletions to consume completions for cancelled recv/
  // DisconnectEx ops still outstanding on those sockets - that only works if
  // the port those completions are queued to is still alive. Destroy already
  // closes FIocp if still open, which happens once this backend object
  // itself is freed, safely after Stop() (and step 5) has fully returned.
  // #223: deliberately no WSACleanup - see _WinsockAcquire comment above.
end;

procedure TIOCPBackend.RegisterConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LMode: u_long;
begin
  // #203: a socket recycled via DisconnectEx(CTF_REUSE_SOCKET) is STILL
  // associated with this IOCP from its previous connection - DisconnectEx does
  // not undo the association. CreateIoCompletionPort then returns 0 with
  // ERROR_INVALID_PARAMETER ("handle already has a completion port"). That is
  // NOT a failure: the association we need is already in place. Re-raising it
  // (as before) closed every reused connection with a bare FIN and no response,
  // which the client saw as a dropped request - the Windows-only connection-
  // churn flake. Only a genuinely different error is fatal here.
  if _IocpCreate(THandle(LConn.Socket), FIocp, 0, 0) = 0 then
    if GetLastError <> ERROR_INVALID_PARAMETER then
      raise Exception.Create('IOCP associate failed: ' + IntToStr(GetLastError));
  // Non-blocking: the readiness recv in _OnRecvReady MUST NOT block a worker
  // thread if the zero-byte-recv readiness was spurious/raced (data already
  // consumed) - a blocking recv there would pin the worker and can hang the
  // whole pool. Non-blocking makes it return WSAEWOULDBLOCK, which _OnRecvReady
  // handles by re-arming instead of blocking.
  LMode := 1;
  ioctlsocket(LConn.Socket, Integer(FIONBIO), LMode);
  // FILE_SKIP_COMPLETION_PORT_ON_SUCCESS - synchronous completion
  // is inline on the calling thread, avoids kernel-to-user transition
  _SetFileCompletionNotificationModes(THandle(LConn.Socket),
    FILE_SKIP_COMPLETION_PORT_ON_SUCCESS or FILE_SKIP_SET_EVENT_ON_HANDLE);
end;

procedure TIOCPBackend.PostRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LCtx: PRecvZeroCtx;
  LFlags: DWORD;
  LBytes: DWORD;
  LRes: Integer;
begin
  New(LCtx);
  FillChar(LCtx^, SizeOf(TRecvZeroCtx), 0);
  LCtx^.Action := iaRecvZero;
  LCtx^.Conn := AConn;
  // WsaBuf already zeroed - len=0, buf=nil (zero-byte recv)
  LFlags := 0;
  LBytes := 0;

  LConn.AddRef;
  // #leak-conn-ctx: tracked here (cleared on every Dispose(LCtx) path in this
  // unit) so SocketClose can cancel and safely wait for it if the completion
  // never gets dequeued before JoinWorkers returns, instead of either
  // leaking it or freeing it out from under a still-pending OS operation.
  // Set before posting: on the two synchronous-completion paths below,
  // Dispose(LCtx) happens (and clears this back to nil) before this function
  // returns, so there's no window where SocketClose could observe a stale
  // pointer to memory already freed here.
  LConn.PendingRecvCtx := LCtx;
  LRes := WSARecv(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, LFlags,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if LRes = 0 then
  begin
    // FILE_SKIP_COMPLETION_PORT_ON_SUCCESS - data already available
    LConn.PendingRecvCtx := nil;
    Dispose(LCtx);
    _OnRecvReady(AConn);
    LConn.Release;
  end
  else if WSAGetLastError <> WSA_IO_PENDING then
  begin
    LConn.PendingRecvCtx := nil;
    LConn.Release;
    Dispose(LCtx);
    FCallbacks.OnConnError(AConn);
  end;
end;

procedure TIOCPBackend._OnRecvReady(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LBuf: array[0..CRecvBufSize - 1] of Byte;
  LRecved: Integer;
begin
  LRecved := recv(LConn.Socket, LBuf[0], CRecvBufSize, 0);
  if LRecved > 0 then
    FCallbacks.OnRecv(LConn, @LBuf[0], Cardinal(LRecved))
  else if (LRecved = SOCKET_ERROR) and (WSAGetLastError = WSAEWOULDBLOCK) then
    // Spurious/raced readiness - no data yet. Re-arm the zero-byte recv instead
    // of treating it as an error (which would drop a live keep-alive connection).
    // The socket is non-blocking (RegisterConn), so recv never blocks here.
    PostRecv(AConn)
  else
    FCallbacks.OnConnError(AConn);
end;

procedure TIOCPBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
var
  LConn: TNativeConn absolute AConn;
  LCtx: PSendCtx;
  LBytes: DWORD;
  LRes: Integer;
  LSendLen: Integer;
begin
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AData);

  if LSendLen = 0 then
  begin
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  New(LCtx);
  FillChar(LCtx^.Ovl, SizeOf(TOverlapped), 0);
  LCtx^.Action := iaSend;
  LCtx^.Conn := AConn;
  LCtx^.SendBuf := AData;
  LCtx^.ActualLen := LSendLen;
  LCtx^.SentBytes := 0;
  LCtx^.WsaBuf.len := ULONG(LSendLen);
  LCtx^.WsaBuf.buf := @LCtx^.SendBuf[0];
  LBytes := 0;

  LConn.AddRef;
  LRes := WSASend(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, 0,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if LRes = 0 then
  begin
    // FILE_SKIP_COMPLETION_PORT_ON_SUCCESS: sync completion arrives inline.
    // Loop to handle consecutive partial sends that also complete synchronously.
    while Integer(LBytes) < (LCtx^.ActualLen - LCtx^.SentBytes) do
    begin
      Inc(LCtx^.SentBytes, Integer(LBytes));
      LCtx^.WsaBuf.buf := @LCtx^.SendBuf[LCtx^.SentBytes];
      LCtx^.WsaBuf.len := ULONG(LCtx^.ActualLen - LCtx^.SentBytes);
      FillChar(LCtx^.Ovl, SizeOf(TOverlapped), 0);
      LBytes := 0;
      LRes := WSASend(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, 0,
        PWSAOverlapped(@LCtx^.Ovl), nil);
      if LRes <> 0 then
      begin
        if WSAGetLastError = WSA_IO_PENDING then
          Exit;  // will complete via IOCP
        LConn.Release;
        TBufferPool.Release(LCtx^.SendBuf);
        Dispose(LCtx);
        FCallbacks.OnConnError(AConn);
        Exit;
      end;
    end;
    // Full send completed synchronously
    TBufferPool.Release(LCtx^.SendBuf);
    Dispose(LCtx);
    FCallbacks.OnSendComplete(LConn);
    LConn.Release;
  end
  else if WSAGetLastError <> WSA_IO_PENDING then
  begin
    LConn.Release;
    TBufferPool.Release(LCtx^.SendBuf);
    Dispose(LCtx);
    FCallbacks.OnConnError(AConn);
  end;
end;

procedure TIOCPBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
var
  LConn: TNativeConn absolute AConn;
  LCtx: PSendVCtx;
  LBytes: DWORD;
  LRes: Integer;
  LHLen: Integer;
  LBLen: Integer;
  LCount: DWORD;
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

  New(LCtx);
  FillChar(LCtx^.Ovl, SizeOf(TOverlapped), 0);
  LCtx^.Action := iaSendV;
  LCtx^.Conn := AConn;
  LCtx^.HeaderBuf := AHeaders;
  LCtx^.BodyBuf := ABody;

  LCount := 0;
  if LHLen > 0 then
  begin
    LCtx^.WsaBufs[LCount].len := ULONG(LHLen);
    LCtx^.WsaBufs[LCount].buf := @LCtx^.HeaderBuf[0];
    Inc(LCount);
  end;
  if LBLen > 0 then
  begin
    LCtx^.WsaBufs[LCount].len := ULONG(LBLen);
    LCtx^.WsaBufs[LCount].buf := @LCtx^.BodyBuf[0];
    Inc(LCount);
  end;

  LBytes := 0;
  LConn.AddRef;
  LRes := WSASend(LConn.Socket, @LCtx^.WsaBufs[0], LCount, LBytes, 0,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if LRes = 0 then
  begin
    TBufferPool.Release(LCtx^.HeaderBuf);
    TBufferPool.Release(LCtx^.BodyBuf);
    Dispose(LCtx);
    FCallbacks.OnSendComplete(LConn);
    LConn.Release;
  end
  else if WSAGetLastError <> WSA_IO_PENDING then
  begin
    LConn.Release;
    TBufferPool.Release(LCtx^.HeaderBuf);
    TBufferPool.Release(LCtx^.BodyBuf);
    Dispose(LCtx);
    FCallbacks.OnConnError(AConn);
  end;
end;

const
  // #leak-conn-ctx: how long SocketClose will let DrainCompletions wait, per
  // straggler socket, for the OS to actually deliver a still-outstanding
  // overlapped op's completion through the port before giving up and leaking
  // its context. Only paid once per connection still open at shutdown, and
  // only after CancelIoEx + closesocket have already been issued for it, so
  // this should resolve almost immediately in practice, not actually sleep
  // for the full bound.
  CPendingOpWaitMs = 250;

// #leak-conn-ctx: drains completions directly from the port, instead of
// polling OVERLAPPED.Internal (an earlier version of this fix did exactly
// that, and it never worked for a zero-byte recv specifically: confirmed
// empirically that GetQueuedCompletionStatus reliably delivers that
// operation's completion, with ERROR_OPERATION_ABORTED after CancelIoEx,
// while Internal stays STATUS_PENDING forever regardless of how long you
// wait or how the socket is closed. Whatever AFD.sys does internally for
// that operation type apparently updates the port's queue but not the
// OVERLAPPED's own status field, unlike a "real" I/O like DisconnectEx.
// Only safe to call once no worker thread is left running (Stop(), after
// JoinWorkers): a live worker could dequeue the very same completions this
// drains, freeing them twice. Frees whatever it dequeues regardless of
// which connection it belongs to (opportunistically also cleaning up other
// stragglers' completions still sitting in the queue, which is fine: each
// context is disposed exactly once here, and TNativeConn.PendingRecvCtx is
// cleared for its owner so that connection's own SocketClose call - if not
// already past this point - sees nil and does not try to touch it again).
// ATarget, when given, is compared against each dequeued OVERLAPPED pointer;
// the Boolean result says whether THAT specific one was seen and disposed
// before the deadline (the caller's one way to confirm its own context was
// actually freed here, since the loop may dispose other stragglers' contexts
// first). With ATarget = nil the result is always False; only the caller
// asking about a specific context cares about it.
function TIOCPBackend.DrainCompletions(ATimeoutMs: Cardinal;
  ATarget: Pointer): Boolean;
var
  LDeadline: UInt64;
  LRemainMs: Int64;
  LBytes: DWORD;
  LKey: NativeUInt;
  LOvl: Pointer;
  LHdr: PIocpHdr;
  LDisCtx: PDisconnectCtx;
  LAcceptCtx: PAcceptCtx;
begin
  Result := False;
  if FIocp = 0 then Exit;
  LDeadline := TThread.GetTickCount64 + ATimeoutMs;
  while True do
  begin
    LRemainMs := Int64(LDeadline) - Int64(TThread.GetTickCount64);
    if LRemainMs <= 0 then Exit;
    LBytes := 0;
    LKey := 0;
    LOvl := nil;
    // Ignore the True/False result: a completed-but-failed op (the common
    // case here, ERROR_OPERATION_ABORTED from our own CancelIoEx) returns
    // False while still filling LOvl, per GetQueuedCompletionStatus's own
    // documented contract. Only a nil LOvl means nothing was dequeued.
    _IocpGet(FIocp, @LBytes, @LKey, @LOvl, DWORD(LRemainMs));
    if LOvl = nil then Exit;
    if (ATarget <> nil) and (LOvl = ATarget) then Result := True;

    LHdr := PIocpHdr(LOvl);
    case LHdr^.Action of
      iaRecvZero:
      begin
        if TNativeConn(PRecvZeroCtx(LOvl)^.Conn).PendingRecvCtx = LOvl then
          TNativeConn(PRecvZeroCtx(LOvl)^.Conn).PendingRecvCtx := nil;
        Dispose(PRecvZeroCtx(LOvl));
      end;
      iaRecv: FreeMem(PRecvCtx(LOvl));
      iaSend:
      begin
        TBufferPool.Release(PSendCtx(LOvl)^.SendBuf);
        Dispose(PSendCtx(LOvl));
      end;
      iaSendV:
      begin
        TBufferPool.Release(PSendVCtx(LOvl)^.HeaderBuf);
        TBufferPool.Release(PSendVCtx(LOvl)^.BodyBuf);
        Dispose(PSendVCtx(LOvl));
      end;
      iaDisconnect:
      begin
        LDisCtx := PDisconnectCtx(LOvl);
        if LDisCtx^.Socket <> INVALID_SOCKET then
          closesocket(LDisCtx^.Socket);
        Dispose(LDisCtx);
      end;
      iaAccept:
      begin
        // FAcceptCtxs entries are a fixed, backend-owned pool reused for the
        // process lifetime, never heap-allocated per completion: nothing to
        // Dispose, just make sure a leftover accepted socket does not leak.
        LAcceptCtx := PAcceptCtx(LOvl);
        if LAcceptCtx^.AcceptSocket <> INVALID_SOCKET then
        begin
          closesocket(LAcceptCtx^.AcceptSocket);
          LAcceptCtx^.AcceptSocket := INVALID_SOCKET;
        end;
      end;
    end;
    // Once the one context the caller was actually waiting on is confirmed
    // disposed, stop: further _IocpGet calls would otherwise block up to
    // LRemainMs each for stragglers nobody asked about, wasting the rest of
    // the bound for nothing this caller needs.
    if Result then Exit;
  end;
end;

procedure TIOCPBackend.SocketClose(AConn: Pointer; AFinalTeardown: Boolean);
var
  LConn: TNativeConn absolute AConn;
  LCtx: PDisconnectCtx;
  LPendingRecv: PRecvZeroCtx;
  LSock: TSocket;
  LLinger: TLinger;
begin
  // #173: capture the handle and invalidate the connection's copy up-front, so
  // a concurrent IdleSweep.ShutdownConn cannot shutdown() a descriptor we are
  // about to recycle (CTF_REUSE_SOCKET) into another connection.
  LSock := LConn.Socket;
  LConn.Socket := INVALID_SOCKET;

  // #leak-conn-ctx: a still-outstanding zero-byte-recv (PostRecv posted it).
  // CRITICAL: only touch it ourselves when AFinalTeardown, i.e. when Stop()
  // has already run JoinWorkers, so no worker thread will ever dequeue this
  // completion. In the ordinary case (idle timeout, protocol error, any
  // close while the server is still running), workers are alive: a worker
  // WILL dequeue this recv's completion through the normal iaRecvZero path
  // in _WorkerLoop and Dispose it there. Draining it here too,
  // unconditionally, caused exactly that: a live worker's Dispose racing
  // this function's own Dispose on the same context, a double free that
  // FastMM4's CheckHeapForCorruption caught ("block header has been
  // corrupted" during a worker's FreeMem) on nothing more than a single
  // ordinary request. So outside final teardown, this field is cleared and
  // otherwise left alone, matching this function's original
  // (pre-#leak-conn-ctx) behavior: trust the worker loop, the only safe
  // single owner of that Dispose while it is still running.
  LPendingRecv := PRecvZeroCtx(LConn.PendingRecvCtx);
  LConn.PendingRecvCtx := nil;
  if AFinalTeardown and (LPendingRecv <> nil) then
  begin
    // CancelIoEx forces the pending recv to actually be cancelled instead of
    // possibly sitting outstanding forever (a genuinely idle keep-alive
    // connection has nothing else that would ever complete it). SO_LINGER{on,
    // 0} + closesocket then destroys the socket outright: nothing left to
    // gracefully close or pool for reuse once a recv was still outstanding
    // anyway (the CTF_REUSE_SOCKET dance below assumes a socket with no I/O
    // left on it), so an abortive close costs nothing here.
    //
    // DrainCompletions, not polling OVERLAPPED.Internal, is what actually
    // observes this completion: confirmed empirically (GetQueuedCompletionStatus
    // reliably delivers it, with ERROR_OPERATION_ABORTED, right after
    // CancelIoEx) that a zero-byte recv's Internal field never leaves
    // STATUS_PENDING no matter how the socket is closed or how long you wait,
    // while GetQueuedCompletionStatus does see it. Whatever AFD.sys does
    // internally for this operation type updates the port's queue but not the
    // OVERLAPPED's own status field, unlike DisconnectEx below. See
    // DrainCompletions's own header for the full reasoning.
    CancelIoEx(THandle(LSock), POverlapped(@LPendingRecv^.Ovl));
    LLinger.l_onoff := 1;
    LLinger.l_linger := 0;
    setsockopt(LSock, SOL_SOCKET, SO_LINGER, @LLinger, SizeOf(LLinger));
    closesocket(LSock);
    if not DrainCompletions(CPendingOpWaitMs, @LPendingRecv^.Ovl) then
      Writeln(ErrOutput, '[iocp] leaking RecvZeroCtx: OS did not report ',
        'completion within ', CPendingOpWaitMs, 'ms at shutdown');
    Exit;
  end;

  // TCP half-close - FIN before RST so the client receives the last bytes
  shutdown(LSock, SD_SEND);

  if FDisconnectEx <> nil then
  begin
    New(LCtx);
    FillChar(LCtx^, SizeOf(TDisconnectCtx), 0);
    LCtx^.Action := iaDisconnect;
    LCtx^.Socket := LSock;

    if not TDisconnectExFunc(FDisconnectEx)(LSock,
      POverlapped(@LCtx^.Ovl), CTF_REUSE_SOCKET, 0) then
    begin
      if WSAGetLastError = WSA_IO_PENDING then
      begin
        if AFinalTeardown then
        begin
          // Same reasoning as the recv above: only safe to drain and dispose
          // it ourselves when no live worker could also dequeue and dispose
          // the same context (that double free is exactly what broke the
          // recv case above when this was unconditional). closesocket forces
          // the OS to actually finish with LCtx^.Ovl. Closing here forfeits
          // CTF_REUSE_SOCKET's pooled reuse for this connection, moot at
          // final teardown anyway.
          closesocket(LSock);
          if not DrainCompletions(CPendingOpWaitMs, @LCtx^.Ovl) then
            Writeln(ErrOutput, '[iocp] leaking DisconnectCtx: OS did not ',
              'report completion within ', CPendingOpWaitMs, 'ms at shutdown');
        end;
        // Not final teardown: a worker is still alive to dequeue this
        // completion through the iaDisconnect path and Dispose(LCtx) there
        // (the original, always-safe behavior). Nothing more to do here.
        Exit;
      end;
      // DisconnectEx failed - fall through to closesocket
      Dispose(LCtx);
    end
    else
    begin
      // Completed synchronously - FILE_SKIP_COMPLETION_PORT_ON_SUCCESS
      // means no IOCP completion will arrive; handle inline.
      if not FSocketPool.AddRecycled(LCtx^.Socket) then
        closesocket(LCtx^.Socket);
      Dispose(LCtx);
      Exit;
    end;
  end;

  closesocket(LSock);
end;

// Worker loop

procedure TIOCPBackend._WorkerLoop;
var
  LEntries: array[0..CIocpBatchSize - 1] of TOVERLAPPED_ENTRY;
  LCount: ULONG;
  I: Integer;
  LOvl: Pointer;
  LBytes: DWORD;
  LHdr: PIocpHdr;
  LConn: TNativeConn;
  LAcceptCtx: PAcceptCtx;
  LDisCtx: PDisconnectCtx;
  LSendCtx: PSendCtx;
  LLocalAddr, LRemoteAddr: PSockAddr;
  LLocalLen, LRemoteLen: Integer;
  LRemoteIP: AnsiString;
  LRemotePort: Word;
  LOne: Integer;
  LAcceptIdx: Integer;
  LRes: Integer;
  LKA: TKeepAliveVals;
  LBytesRet: DWORD;
  LSawShutdown: Boolean;
begin
  try
  while True do
  begin
    if not _IocpGetEx(FIocp, @LEntries[0], CIocpBatchSize, @LCount,
      INFINITE, False) then
      Break;

    // #228: SignalWorkers posts exactly one nil "poison pill" per worker
    // thread in a tight loop. GetQueuedCompletionStatusEx retrieves up to
    // CIocpBatchSize (64) entries in ONE call, so a single thread that wakes
    // first can dequeue MORE THAN ONE pill in the same batch -- silently
    // starving another worker thread of its shutdown signal, which then
    // blocks forever in the INFINITE wait above (~25% hang rate observed in
    // Stop_NoInFlight_ReturnsQuickly and the wider suite, #228). Re-post any
    // pill beyond the first found in this batch so the total pill count in
    // circulation always matches the number of threads still running,
    // regardless of how the OS happens to batch them. Process the REST of
    // the batch before honoring shutdown too -- exiting on the first nil
    // used to silently drop any real completion queued after it in the
    // same batch.
    LSawShutdown := False;
    for I := 0 to Integer(LCount) - 1 do
    begin
      LOvl := LEntries[I].lpOverlapped;
      LBytes := LEntries[I].dwNumberOfBytesTransferred;

      if LOvl = nil then
      begin
        if LSawShutdown then
          _IocpPost(FIocp, 0, 0, nil)
        else
          LSawShutdown := True;
        Continue;
      end;

      try
        LHdr := PIocpHdr(LOvl);

        if LHdr^.Action = iaAccept then
        begin
          LAcceptCtx := PAcceptCtx(LOvl);

          if (TInterlocked.Read(FShutdown) <> 0) or (LAcceptCtx^.AcceptSocket = INVALID_SOCKET) then
          begin
            if LAcceptCtx^.AcceptSocket <> INVALID_SOCKET then
              closesocket(LAcceptCtx^.AcceptSocket);
            LAcceptCtx^.AcceptSocket := INVALID_SOCKET;
            Continue;
          end;

          setsockopt(LAcceptCtx^.AcceptSocket, SOL_SOCKET,
            CSO_UPDATE_ACCEPT_CONTEXT,
            PAnsiChar(@FListenSocket), SizeOf(FListenSocket));

          LOne := 1;
          setsockopt(LAcceptCtx^.AcceptSocket, IPPROTO_TCP, TCP_NODELAY,
            PAnsiChar(@LOne), SizeOf(LOne));
          setsockopt(LAcceptCtx^.AcceptSocket, SOL_SOCKET, SO_KEEPALIVE,
            PAnsiChar(@LOne), SizeOf(LOne));

          // SIO_KEEPALIVE_VALS - probe after 30s idle, retry every 5s
          LKA.OnOff := 1;
          LKA.KeepAliveTime := CKeepAliveTime;
          LKA.KeepAliveInterval := CKeepAliveInterval;
          LBytesRet := 0;
          WSAIoctl(LAcceptCtx^.AcceptSocket, CSIO_KEEPALIVE_VALS,
            @LKA, SizeOf(LKA), nil, 0, {$IFDEF FPC}@LBytesRet{$ELSE}LBytesRet{$ENDIF}, nil, nil);

          LLocalAddr := nil;
          LRemoteAddr := nil;
          LLocalLen := 0;
          LRemoteLen := 0;
          if FGetAcceptExSockaddrs <> nil then
          begin
            TGetAcceptExSockaddrsFunc(FGetAcceptExSockaddrs)(
              @LAcceptCtx^.AddrBuf[0], 0,
              SizeOf(TSockAddrIn) + 16, SizeOf(TSockAddrIn) + 16,
              LLocalAddr, LLocalLen, LRemoteAddr, LRemoteLen);
          end;

          if (LRemoteAddr <> nil) and (LRemoteLen >= SizeOf(TSockAddrIn)) then
          begin
            LRemoteIP := inet_ntoa(PSockAddrIn(LRemoteAddr)^.sin_addr);
            LRemotePort := ntohs(PSockAddrIn(LRemoteAddr)^.sin_port);
          end
          else
          begin
            LRemoteIP := '0.0.0.0';
            LRemotePort := 0;
          end;

          try
            FCallbacks.OnNewConn(NativeUInt(LAcceptCtx^.AcceptSocket),
              string(LRemoteIP) + ':' + IntToStr(LRemotePort));
          except
            closesocket(LAcceptCtx^.AcceptSocket);
          end;

          for LAcceptIdx := 0 to High(FAcceptCtxs) do
            if FAcceptCtxs[LAcceptIdx] = Pointer(LAcceptCtx) then
            begin
              _PostOneAccept(LAcceptIdx);
              Break;
            end;

          Continue;
        end;

        if LHdr^.Action = iaDisconnect then
        begin
          LDisCtx := PDisconnectCtx(LOvl);
          if LDisCtx^.Socket <> INVALID_SOCKET then
          begin
            if not FSocketPool.AddRecycled(LDisCtx^.Socket) then
              closesocket(LDisCtx^.Socket);
          end;
          Dispose(LDisCtx);
          Continue;
        end;

        LConn := TNativeConn(LHdr^.Conn);

        // Zero-byte recv: LBytes is always 0; do synchronous recv
        if LHdr^.Action = iaRecvZero then
        begin
          LConn.PendingRecvCtx := nil;
          Dispose(PRecvZeroCtx(LOvl));
          _OnRecvReady(LConn);
          LConn.Release;
          Continue;
        end;

        if LBytes = 0 then
        begin
          case LHdr^.Action of
            iaRecv: FreeMem(PRecvCtx(LOvl));
            iaSend:
            begin
              TBufferPool.Release(PSendCtx(LOvl)^.SendBuf);
              Dispose(PSendCtx(LOvl));
            end;
            iaSendV:
            begin
              TBufferPool.Release(PSendVCtx(LOvl)^.HeaderBuf);
              TBufferPool.Release(PSendVCtx(LOvl)^.BodyBuf);
              Dispose(PSendVCtx(LOvl));
            end;
          end;
          FCallbacks.OnConnError(LConn);
          LConn.Release;
          Continue;
        end;

        case LHdr^.Action of
          iaRecv:
          begin
            FCallbacks.OnRecv(LConn, @PRecvCtx(LOvl)^.Data[0], LBytes);
            FreeMem(PRecvCtx(LOvl));
            LConn.Release;
          end;
          iaSend:
          begin
            LSendCtx := PSendCtx(LOvl);
            Inc(LSendCtx^.SentBytes, Integer(LBytes));
            if LSendCtx^.SentBytes < LSendCtx^.ActualLen then
            begin
              // Partial send - resubmit for remaining bytes
              LSendCtx^.WsaBuf.buf := @LSendCtx^.SendBuf[LSendCtx^.SentBytes];
              LSendCtx^.WsaBuf.len := ULONG(LSendCtx^.ActualLen - LSendCtx^.SentBytes);
              FillChar(LSendCtx^.Ovl, SizeOf(TOverlapped), 0);
              LRes := WSASend(LConn.Socket, @LSendCtx^.WsaBuf, 1, LBytes, 0,
                PWSAOverlapped(@LSendCtx^.Ovl), nil);
              if LRes = 0 then
              begin
                // Sync completion of remainder - will come back as IOCP completion
                // (unless FILE_SKIP_COMPLETION_PORT_ON_SUCCESS, handled next iteration)
              end
              else if WSAGetLastError <> WSA_IO_PENDING then
              begin
                TBufferPool.Release(LSendCtx^.SendBuf);
                Dispose(LSendCtx);
                FCallbacks.OnConnError(LConn);
                LConn.Release;
              end;
            end
            else
            begin
              TBufferPool.Release(LSendCtx^.SendBuf);
              Dispose(LSendCtx);
              FCallbacks.OnSendComplete(LConn);
              LConn.Release;
            end;
          end;
          iaSendV:
          begin
            TBufferPool.Release(PSendVCtx(LOvl)^.HeaderBuf);
            TBufferPool.Release(PSendVCtx(LOvl)^.BodyBuf);
            Dispose(PSendVCtx(LOvl));
            FCallbacks.OnSendComplete(LConn);
            LConn.Release;
          end;
        end;
      except
        on E: Exception do
          Writeln(ErrOutput, '[iocp] WORKER_EX [', E.ClassName, ']: ', E.Message);
      end;
    end;

    if LSawShutdown then Exit;
  end;
  finally
    // L4: drenar TLC do worker no fim do loop - evita vazamento em graceful reload.
    // Same reasoning applies to the per-thread Date-header cache and defer-banner
    // string (both plain UnicodeString threadvars, lazily created the first time
    // this thread builds a response): a worker thread that built even one
    // response on this loop (SyncDispatch/backpressure/HTTP2 path) leaks them
    // otherwise, same as the buffer cache above.
    TBufferPool.FlushThreadCache;
    ResetThreadDateCache;
    ResetThreadDeferVars;
  end;
end;

{$ELSE}

interface
implementation  // empty stub on non-Windows

{$ENDIF MSWINDOWS}

end.
