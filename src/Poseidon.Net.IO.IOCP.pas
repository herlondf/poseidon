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
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.Pool.Socket;

type
  TIOCPBackend = class(TInterfacedObject, IIOBackend)
  private
    FIocp: THandle;
    FListenSocket: TSocket;
    FWorkers: TArray<TThread>;
    FAcceptThread: TThread;
    FCallbacks: IIOCallbacks;
    procedure _Accept;
    procedure _WorkerLoop;
  public
    constructor Create;
    destructor  Destroy; override;
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

// #68: skip IOCP completion when WSASend/WSARecv completes synchronously
function _SetFileCompletionNotificationModes(FileHandle: THandle;
  Flags: Byte): BOOL; stdcall;
  external 'kernel32.dll' name 'SetFileCompletionNotificationModes';

const
  FILE_SKIP_COMPLETION_PORT_ON_SUCCESS = $01;
  FILE_SKIP_SET_EVENT_ON_HANDLE        = $02;

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
  CRecvBufSize = 32768;

type
  TIocpAction = (iaRecv, iaSend, iaSendV);

  PRecvCtx = ^TRecvCtx;
  TRecvCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Conn: Pointer;
    WsaBuf: TWsaBuf;
    Data: array[0..CRecvBufSize - 1] of Byte;
  end;

  PSendCtx = ^TSendCtx;
  TSendCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Conn: Pointer;
    WsaBuf: TWsaBuf;
    SendBuf: TBytes;
    ActualLen: Integer;             // P-4: bytes to send; 0 = use Length(SendBuf)
  end;

  // #61: Vectored send context — 2 WSABUFs for headers + body
  PSendVCtx = ^TSendVCtx;
  TSendVCtx = record
    Ovl: TOverlapped;               // MUST be first
    Action: TIocpAction;
    Conn: Pointer;
    WsaBufs: array[0..1] of TWsaBuf;
    HeaderBuf: TBytes;
    BodyBuf: TBytes;
  end;

  PIocpHdr = ^TIocpHdr;
  TIocpHdr = record
    Ovl: TOverlapped;
    Action: TIocpAction;
    Conn: Pointer;
  end;

// ---------------------------------------------------------------------------
// TIOCPBackend
// ---------------------------------------------------------------------------

constructor TIOCPBackend.Create;
begin
  inherited Create;
  FIocp := 0;
  FListenSocket := INVALID_SOCKET;
end;

destructor TIOCPBackend.Destroy;
begin
  inherited Destroy;
end;

procedure TIOCPBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);
var
  LAddr: TSockAddrIn;
  LOne: Integer;
  LWsaData: TWSAData;
  I: Integer;
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

  // #77: load DisconnectEx from the listen socket for socket recycling
  TSocketPool.LoadDisconnectEx(FListenSocket);

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
    raise Exception.Create('IOCP associate failed');
  // #68: skip IOCP completion packet when WSASend/WSARecv completes synchronously.
  // Result is inline on the calling thread — avoids kernel→user transition.
  _SetFileCompletionNotificationModes(THandle(LConn.Socket),
    FILE_SKIP_COMPLETION_PORT_ON_SUCCESS or FILE_SKIP_SET_EVENT_ON_HANDLE);
end;

procedure TIOCPBackend.PostRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LCtx: PRecvCtx;
  LFlags: DWORD;
  LBytes: DWORD;
  LRes: Integer;
begin
  LCtx := AllocMem(SizeOf(TRecvCtx));
  LCtx^.Action     := iaRecv;
  LCtx^.Conn       := AConn;
  LCtx^.WsaBuf.len := CRecvBufSize;
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

// #61: Vectored send — WSASend with 2 WSABUFs (headers + body)
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
  LCtx^.Action    := iaSendV;
  LCtx^.Conn      := AConn;
  LCtx^.HeaderBuf := AHeaders;
  LCtx^.BodyBuf   := ABody;

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

  if (LRes = SOCKET_ERROR) and (WSAGetLastError <> WSA_IO_PENDING) then
  begin
    LConn.Release;
    TBufferPool.Release(LCtx^.HeaderBuf);
    TBufferPool.Release(LCtx^.BodyBuf);
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
  // #77: try to recycle via DisconnectEx + TF_REUSE_SOCKET instead of closesocket
  if not TSocketPool.Recycle(LConn.Socket) then
    closesocket(LConn.Socket);
end;

// ---------------------------------------------------------------------------
// Accept thread
// ---------------------------------------------------------------------------

procedure TIOCPBackend._Accept;
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
      // #77: try to recycle failed socket instead of closing
      if not TSocketPool.Recycle(LClient) then
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
  LKey: NativeUInt;
  LOvl: Pointer;
  LHdr: PIocpHdr;
  LConn: TNativeConn;
  LOK: BOOL;
begin
  while True do
  begin
    LOvl := nil;
    LBytes := 0;
    LKey := 0;
    LOK := _IocpGet(FIocp, @LBytes, @LKey, @LOvl, INFINITE);

    if LOvl = nil then Break;

    try
      LHdr := PIocpHdr(LOvl);
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
          TBufferPool.Release(PSendCtx(LOvl)^.SendBuf);
          Dispose(PSendCtx(LOvl));
          FCallbacks.OnSendComplete(LConn);
          LConn.Release;
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
end;

{$ELSE}

interface
implementation  // empty stub on non-Windows

{$ENDIF MSWINDOWS}

end.
