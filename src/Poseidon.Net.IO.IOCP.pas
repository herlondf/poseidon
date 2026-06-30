unit Poseidon.Net.IO.IOCP;

// TIOCPBackend — Windows IOCP (I/O Completion Ports) backend.
// R-1: extracted from Poseidon.Net.HttpServer.  All platform-specific Windows
// socket code lives here; HttpServer.pas now references this unit only at
// construction time via a single {$IFDEF MSWINDOWS}.

{$IFDEF MSWINDOWS}

interface

uses
  System.SysUtils,
  System.Classes,
  Winapi.Windows,
  Winapi.Winsock2,
  Poseidon.Net.IO,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer;

type
  TIOCPBackend = class(TInterfacedObject, IIOBackend)
  private
    FIocp:        THandle;
    FListenSocket: TSocket;
    FWorkers:     TArray<TThread>;
    FAcceptThread: TThread;
    FCallbacks:   IIOCallbacks;
    procedure _Accept;
    procedure _WorkerLoop;
  public
    constructor Create;
    destructor  Destroy; override;
    // IIOBackend
    procedure StartListening(const AHost: string; APort: Integer;
      AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks);
    procedure StopAccept;
    procedure ShutdownConn(AConn: Pointer);
    procedure SignalWorkers;
    procedure JoinWorkers;
    procedure RegisterConn(AConn: Pointer);
    procedure PostRecv(AConn: Pointer);
    procedure PostSend(AConn: Pointer; const AData: TBytes; AActualLen: Integer);
    procedure SocketClose(AConn: Pointer);
  end;

implementation

// ---------------------------------------------------------------------------
// IOCP kernel imports
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// IOCP context types
// ---------------------------------------------------------------------------

const
  RECV_BUF_SIZE = 32768;

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

// ---------------------------------------------------------------------------
// TIOCPBackend
// ---------------------------------------------------------------------------

constructor TIOCPBackend.Create;
begin
  inherited Create;
  FIocp         := 0;
  FListenSocket := INVALID_SOCKET;
end;

destructor TIOCPBackend.Destroy;
begin
  inherited Destroy;
end;

procedure TIOCPBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks);
var
  LAddr:  TSockAddrIn;
  LOne:   Integer;
  LWsaData: TWSAData;
  I:      Integer;
begin
  FCallbacks := ACallbacks;

  if WSAStartup($0202, LWsaData) <> 0 then
    raise Exception.Create('WSAStartup failed');

  FIocp := _IocpCreate(INVALID_HANDLE_VALUE, 0, 0, 0);
  if FIocp = 0 then RaiseLastOSError;

  FListenSocket := WSASocket(AF_INET, SOCK_STREAM, IPPROTO_TCP, nil, 0,
    WSA_FLAG_OVERLAPPED);
  if FListenSocket = INVALID_SOCKET then RaiseLastOSError;

  LOne := 1;
  setsockopt(FListenSocket, SOL_SOCKET, SO_REUSEADDR,
    PAnsiChar(@LOne), SizeOf(LOne));

  // TCP_FASTOPEN (RFC 7413) — opt-in; Windows 10 1607+
  if AFastOpen then
    setsockopt(FListenSocket, IPPROTO_TCP, 15 {TCP_FASTOPEN},
      PAnsiChar(@LOne), SizeOf(LOne));
  // Failure is silently ignored on older Windows

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

  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
    FWorkers[I] := TThread.CreateAnonymousThread(procedure begin _WorkerLoop; end);
  for I := 0 to AWorkerCount - 1 do
  begin
    FWorkers[I].FreeOnTerminate := False;
    FWorkers[I].Start;
  end;

  FAcceptThread := TThread.CreateAnonymousThread(procedure begin _Accept; end);
  FAcceptThread.FreeOnTerminate := False;
  FAcceptThread.Start;
end;

procedure TIOCPBackend.StopAccept;
begin
  closesocket(FListenSocket);
  FListenSocket := INVALID_SOCKET;
  if FAcceptThread <> nil then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;
end;

procedure TIOCPBackend.ShutdownConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  shutdown(LConn.Socket, SD_BOTH);
end;

procedure TIOCPBackend.SignalWorkers;
var
  I: Integer;
begin
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
  if FIocp <> 0 then
  begin
    CloseHandle(FIocp);
    FIocp := 0;
  end;
  WSACleanup;
end;

procedure TIOCPBackend.RegisterConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  if _IocpCreate(THandle(LConn.Socket), FIocp, 0, 0) = 0 then
  begin
    // Association failed — caller (_OnNewSocket) will close the conn
    raise Exception.Create('IOCP associate failed');
  end;
  // PostRecv is now called explicitly by _OnNewSocket after RegisterConn,
  // keeping the responsibility at the server level (same contract as io_uring/epoll).
end;

procedure TIOCPBackend.PostRecv(AConn: Pointer);
var
  LConn:  TNativeConn absolute AConn;
  LCtx:   PRecvCtx;
  LFlags: DWORD;
  LBytes: DWORD;
  LRes:   Integer;
begin
  LCtx := AllocMem(SizeOf(TRecvCtx));
  LCtx^.Action     := iaRecv;
  LCtx^.Conn       := AConn;
  LCtx^.WsaBuf.len := RECV_BUF_SIZE;
  LCtx^.WsaBuf.buf := @LCtx^.Data[0];
  LFlags := 0;
  LBytes := 0;

  LConn.AddRef;  // #43: keep conn alive while this IOCP recv is in-flight
  LRes := WSARecv(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, LFlags,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if (LRes = SOCKET_ERROR) and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    LConn.Release;  // #43: op never posted — drop the ref we just took
    FreeMem(LCtx);
    FCallbacks.OnConnError(AConn);
  end;
end;

procedure TIOCPBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
var
  LConn:    TNativeConn absolute AConn;
  LCtx:     PSendCtx;
  LBytes:   DWORD;
  LRes:     Integer;
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
  LCtx^.Action     := iaSend;
  LCtx^.Conn       := AConn;
  LCtx^.SendBuf    := AData;
  LCtx^.ActualLen  := AActualLen;
  LCtx^.WsaBuf.len := ULONG(LSendLen);
  LCtx^.WsaBuf.buf := @LCtx^.SendBuf[0];
  LBytes := 0;

  LConn.AddRef;  // #43: keep conn alive while this IOCP send is in-flight
  LRes := WSASend(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, 0,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if (LRes = SOCKET_ERROR) and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    Writeln(ErrOutput, '[iocp] WSASend failed: WSAError=', WSAGetLastError,
      ' conn=', NativeUInt(AConn));
    LConn.Release;  // #43: op never posted — drop the ref we just took
    TBufferPool.Release(LCtx^.SendBuf);
    Dispose(LCtx);
    FCallbacks.OnConnError(AConn);
  end;
end;

procedure TIOCPBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  // R-6: TCP half-close — FIN before RST so the client receives the last bytes
  shutdown(LConn.Socket, SD_SEND);
  closesocket(LConn.Socket);
end;

// ---------------------------------------------------------------------------
// Accept thread
// ---------------------------------------------------------------------------

procedure TIOCPBackend._Accept;
var
  LClient:   TSocket;
  LAddr:     TSockAddrIn;
  LAddrLen:  Integer;
  LRemoteIP: AnsiString;
  LOne:      Integer;
begin
  while True do
  begin
    FillChar(LAddr, SizeOf(LAddr), 0);
    LAddrLen := SizeOf(LAddr);
    LClient := _WsaAccept(FListenSocket, @LAddr, @LAddrLen);
    if LClient = INVALID_SOCKET then Break;

    // Apply per-connection socket options before handing off to server
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

// ---------------------------------------------------------------------------
// Worker loop
// ---------------------------------------------------------------------------

procedure TIOCPBackend._WorkerLoop;
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
            TBufferPool.Release(PSendCtx(LOvl)^.SendBuf);
            Dispose(PSendCtx(LOvl));
          end;
        end;
        FCallbacks.OnConnError(LConn);
        LConn.Release;  // #43: drop IOCP-op ref (AddRef was in PostRecv/PostSend)
        Continue;
      end;

      case LHdr^.Action of
        iaRecv:
        begin
          FCallbacks.OnRecv(LConn, @PRecvCtx(LOvl)^.Data[0], LBytes);
          FreeMem(PRecvCtx(LOvl));
          LConn.Release;  // #43: drop IOCP recv op ref
        end;
        iaSend:
        begin
          TBufferPool.Release(PSendCtx(LOvl)^.SendBuf);
          Dispose(PSendCtx(LOvl));
          FCallbacks.OnSendComplete(LConn);
          LConn.Release;  // #43: drop IOCP send op ref
        end;
      end;
    except
      on E: Exception do
        Writeln(ErrOutput, '[iocp] WORKER_EX [', E.ClassName, ']: ', E.Message);
    end;
  end;
end;

{$ELSE}

interface
implementation  // empty stub on non-Windows

{$ENDIF MSWINDOWS}

end.
