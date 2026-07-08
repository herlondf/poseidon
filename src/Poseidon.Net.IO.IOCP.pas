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
    FCallbacks: IIOCallbacks;
    FShutdown: Boolean;
    FAcceptEx: Pointer;
    FGetAcceptExSockaddrs: Pointer;
    FAcceptCtxs: array of Pointer;  // PAcceptCtx, allocated in StartListening
    FDisconnectEx: Pointer;
    procedure _LoadExtensions;
    procedure _PostOneAccept(AIdx: Integer);
    procedure _WorkerLoop;
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

// ---------------------------------------------------------------------------
// IOCP kernel imports
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// IOCP context types
// ---------------------------------------------------------------------------

const
  CTCP_FASTOPEN = 15;
  CSO_UPDATE_ACCEPT_CONTEXT = $700B;
  CRecvBufSize = 32768;
  CIocpBatchSize = 64;
  CAcceptPoolSize = 16;
  CAddrBufSize = (SizeOf(TSockAddrIn) + 16) * 2;
  CTF_REUSE_SOCKET = $02;

type
  TIocpAction = (iaRecv, iaSend, iaSendV, iaAccept, iaDisconnect);

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

// ---------------------------------------------------------------------------
// TIOCPBackend
// ---------------------------------------------------------------------------

constructor TIOCPBackend.Create;
begin
  inherited Create;
  FIocp := 0;
  FListenSocket := INVALID_SOCKET;
  FShutdown := False;
  FAcceptEx := nil;
  FGetAcceptExSockaddrs := nil;
  FDisconnectEx := nil;
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
  inherited Destroy;
end;

procedure TIOCPBackend._LoadExtensions;
var
  LBytes: DWORD;
  LGuid: TGUID;
begin
  LBytes := 0;
  LGuid := WSAID_ACCEPTEX;
  WSAIoctl(FListenSocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FAcceptEx, SizeOf(FAcceptEx), @LBytes, nil, nil);

  LGuid := WSAID_GETACCEPTEXSOCKADDRS;
  WSAIoctl(FListenSocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FGetAcceptExSockaddrs, SizeOf(FGetAcceptExSockaddrs),
    @LBytes, nil, nil);

  LGuid := StringToGUID('{7FDA2E11-8630-436F-A031-F536A6EEC157}');
  WSAIoctl(FListenSocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FDisconnectEx, SizeOf(FDisconnectEx),
    @LBytes, nil, nil);
end;

procedure TIOCPBackend._PostOneAccept(AIdx: Integer);
var
  LCtx: PAcceptCtx;
  LAcceptSocket: TSocket;
  LBytes: DWORD;
begin
  LAcceptSocket := TSocketPool.Acquire;
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
    end;
  end;
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
  _LoadExtensions;

  if _IocpCreate(THandle(FListenSocket), FIocp, 0, 0) = 0 then
    raise Exception.Create('IOCP associate listen socket failed');

  SetLength(FWorkers, AWorkerCount);
  for I := 0 to AWorkerCount - 1 do
    FWorkers[I] := TThread.CreateAnonymousThread(procedure begin _WorkerLoop; end);
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

procedure TIOCPBackend.StopAccept;
begin
  FShutdown := True;
  closesocket(FListenSocket);
  FListenSocket := INVALID_SOCKET;
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
  FShutdown := True;
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
  // FILE_SKIP_COMPLETION_PORT_ON_SUCCESS — synchronous completion
  // is inline on the calling thread, avoids kernel-to-user transition
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
  LCtx^.Action := iaRecv;
  LCtx^.Conn := AConn;
  LCtx^.WsaBuf.len := CRecvBufSize;
  LCtx^.WsaBuf.buf := @LCtx^.Data[0];
  LFlags := 0;
  LBytes := 0;

  LConn.AddRef;
  LRes := WSARecv(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, LFlags,
    PWSAOverlapped(@LCtx^.Ovl), nil);

  if LRes = 0 then
  begin
    // FILE_SKIP_COMPLETION_PORT_ON_SUCCESS — synchronous completion,
    // no IOCP packet will be posted
    if LBytes = 0 then
    begin
      LConn.Release;
      FreeMem(LCtx);
      FCallbacks.OnConnError(AConn);
    end
    else
    begin
      FCallbacks.OnRecv(LConn, @LCtx^.Data[0], LBytes);
      FreeMem(LCtx);
      LConn.Release;
    end;
  end
  else if WSAGetLastError <> WSA_IO_PENDING then
  begin
    LConn.Release;
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
    if Integer(LBytes) < LSendLen then
    begin
      LCtx^.SentBytes := Integer(LBytes);
      LCtx^.WsaBuf.buf := @LCtx^.SendBuf[LBytes];
      LCtx^.WsaBuf.len := ULONG(LSendLen - Integer(LBytes));
      FillChar(LCtx^.Ovl, SizeOf(TOverlapped), 0);
      LRes := WSASend(LConn.Socket, @LCtx^.WsaBuf, 1, LBytes, 0,
        PWSAOverlapped(@LCtx^.Ovl), nil);
      if (LRes <> 0) and (WSAGetLastError <> WSA_IO_PENDING) then
      begin
        LConn.Release;
        TBufferPool.Release(LCtx^.SendBuf);
        Dispose(LCtx);
        FCallbacks.OnConnError(AConn);
      end;
      // else: will complete via IOCP or next sync check
    end
    else
    begin
      TBufferPool.Release(LCtx^.SendBuf);
      Dispose(LCtx);
      FCallbacks.OnSendComplete(LConn);
      LConn.Release;
    end;
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

procedure TIOCPBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LCtx: PDisconnectCtx;
begin
  // TCP half-close — FIN before RST so the client receives the last bytes
  shutdown(LConn.Socket, SD_SEND);

  if FDisconnectEx <> nil then
  begin
    New(LCtx);
    FillChar(LCtx^, SizeOf(TDisconnectCtx), 0);
    LCtx^.Action := iaDisconnect;
    LCtx^.Socket := LConn.Socket;

    if not TDisconnectExFunc(FDisconnectEx)(LConn.Socket,
      POverlapped(@LCtx^.Ovl), CTF_REUSE_SOCKET, 0) then
    begin
      if WSAGetLastError = WSA_IO_PENDING then
        Exit;  // will complete via IOCP
      // DisconnectEx failed — fall through to closesocket
      Dispose(LCtx);
    end
    else
      Exit;  // completed synchronously — will get IOCP completion
  end;

  closesocket(LConn.Socket);
end;

// ---------------------------------------------------------------------------
// Worker loop
// ---------------------------------------------------------------------------

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
  LOne: Integer;
  LAcceptIdx: Integer;
  LRes: Integer;
begin
  while True do
  begin
    if not _IocpGetEx(FIocp, @LEntries[0], CIocpBatchSize, @LCount,
      INFINITE, False) then
      Break;

    for I := 0 to Integer(LCount) - 1 do
    begin
      LOvl := LEntries[I].lpOverlapped;
      LBytes := LEntries[I].dwNumberOfBytesTransferred;

      if LOvl = nil then
        Exit;

      try
        LHdr := PIocpHdr(LOvl);

        if LHdr^.Action = iaAccept then
        begin
          LAcceptCtx := PAcceptCtx(LOvl);

          if FShutdown or (LAcceptCtx^.AcceptSocket = INVALID_SOCKET) then
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
            LRemoteIP := inet_ntoa(PSockAddrIn(LRemoteAddr)^.sin_addr)
          else
            LRemoteIP := '0.0.0.0';

          try
            FCallbacks.OnNewConn(NativeUInt(LAcceptCtx^.AcceptSocket),
              string(LRemoteIP) + ':' +
              IntToStr(ntohs(PSockAddrIn(LRemoteAddr)^.sin_port)));
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
            if not TSocketPool.AddRecycled(LDisCtx^.Socket) then
              closesocket(LDisCtx^.Socket);
          end;
          Dispose(LDisCtx);
          Continue;
        end;

        LConn := TNativeConn(LHdr^.Conn);

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
              // Partial send — resubmit for remaining bytes
              LSendCtx^.WsaBuf.buf := @LSendCtx^.SendBuf[LSendCtx^.SentBytes];
              LSendCtx^.WsaBuf.len := ULONG(LSendCtx^.ActualLen - LSendCtx^.SentBytes);
              FillChar(LSendCtx^.Ovl, SizeOf(TOverlapped), 0);
              LRes := WSASend(LConn.Socket, @LSendCtx^.WsaBuf, 1, LBytes, 0,
                PWSAOverlapped(@LSendCtx^.Ovl), nil);
              if LRes = 0 then
              begin
                // Sync completion of remainder — will come back as IOCP completion
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
  end;
end;

{$ELSE}

interface
implementation  // empty stub on non-Windows

{$ENDIF MSWINDOWS}

end.
