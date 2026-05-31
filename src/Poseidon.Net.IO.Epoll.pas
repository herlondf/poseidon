unit Poseidon.Net.IO.Epoll;

// TEpollBackend — Linux epoll(7) backend.
// R-1: extracted from Poseidon.Net.HttpServer.  All platform-specific Linux
// socket code lives here; HttpServer.pas now references this unit only at
// construction time via a single {$IFNDEF MSWINDOWS}.

{$IFNDEF MSWINDOWS}

interface

uses
  System.SysUtils,
  System.Classes,
  Posix.SysSocket,
  Posix.NetinetIn,
  Posix.NetinetTcp,
  Posix.ArpaInet,
  Posix.Unistd,
  Posix.Errno,
  Poseidon.Net.IO,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer;

type
  TEpollBackend = class(TInterfacedObject, IIOBackend)
  private
    FEpollFd:      Integer;
    FShutdownPipe: array[0..1] of Integer;
    FListenSocket: Integer;
    FWorkers:      TArray<TThread>;
    FAcceptThread: TThread;
    FCallbacks:    IIOCallbacks;
    procedure _Accept;
    procedure _WorkerLoop;
    procedure _DoRecv(AConn: Pointer);
    procedure _FlushSend(AConn: Pointer);
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
// epoll syscalls and types
// ---------------------------------------------------------------------------

const
  RECV_BUF_SIZE = 32768;
  MAX_EVENTS    = 256;
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
  EPOLL_CLOEXEC = $80000;
  // setsockopt
  SO_REUSEPORT  = 15;

type
  epoll_data_t = record
    case Integer of
      0: (ptr: Pointer);
      1: (fd:  Integer);
      2: (u32: UInt32);
      3: (u64: UInt64);
  end;
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
// TEpollBackend
// ---------------------------------------------------------------------------

constructor TEpollBackend.Create;
begin
  inherited Create;
  FEpollFd         := -1;
  FListenSocket    := -1;
  FShutdownPipe[0] := -1;
  FShutdownPipe[1] := -1;
end;

destructor TEpollBackend.Destroy;
begin
  inherited Destroy;
end;

procedure TEpollBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks);
var
  LAddr:  sockaddr_in;
  LOne:   Integer;
  LEv:    epoll_event;
  LPipe:  array[0..1] of Integer;
  I:      Integer;
begin
  FCallbacks := ACallbacks;

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

  FListenSocket := _LinuxSocket(AF_INET, SOCK_STREAM or SOCK_CLOEXEC, 0);
  if FListenSocket < 0 then
    raise Exception.Create('socket() failed: ' + IntToStr(GetLastError));

  LOne := 1;
  _LinuxSetsockopt(FListenSocket, SOL_SOCKET, SO_REUSEADDR, @LOne, SizeOf(LOne));
  _LinuxSetsockopt(FListenSocket, SOL_SOCKET, SO_REUSEPORT, @LOne, SizeOf(LOne));

  // TCP_FASTOPEN — requires /proc/sys/net/ipv4/tcp_fastopen to have bit 2 set
  if AFastOpen then
    _LinuxSetsockopt(FListenSocket, IPPROTO_TCP, 23 {TCP_FASTOPEN}, @LOne, SizeOf(LOne));

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port   := htons(APort);
  if (AHost = '0.0.0.0') or (AHost = '') then
    LAddr.sin_addr.s_addr := INADDR_ANY
  else
    LAddr.sin_addr.s_addr := inet_addr(MarshaledAString(AnsiString(AHost)));

  if _LinuxBind(FListenSocket, @LAddr, SizeOf(LAddr)) < 0 then
    raise Exception.Create('bind() failed: ' + IntToStr(GetLastError));

  if _LinuxListen(FListenSocket, SOMAXCONN) < 0 then
    raise Exception.Create('listen() failed: ' + IntToStr(GetLastError));

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

procedure TEpollBackend.StopAccept;
begin
  _LinuxClose(FListenSocket);
  FListenSocket := -1;
  if FAcceptThread <> nil then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;
end;

procedure TEpollBackend.ShutdownConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  shutdown(LConn.Socket, SHUT_RDWR);
end;

procedure TEpollBackend.SignalWorkers;
var
  I:      Integer;
  LDummy: Byte;
begin
  LDummy := 0;
  for I := 0 to High(FWorkers) do
    _LinuxWrite(FShutdownPipe[1], @LDummy, 1);
end;

procedure TEpollBackend.JoinWorkers;
var
  I: Integer;
begin
  for I := 0 to High(FWorkers) do
  begin
    FWorkers[I].WaitFor;
    FWorkers[I].Free;
  end;
  SetLength(FWorkers, 0);
  if FEpollFd >= 0 then
  begin
    _LinuxClose(FEpollFd);
    FEpollFd := -1;
  end;
  if FShutdownPipe[0] >= 0 then _LinuxClose(FShutdownPipe[0]);
  if FShutdownPipe[1] >= 0 then _LinuxClose(FShutdownPipe[1]);
  FShutdownPipe[0] := -1;
  FShutdownPipe[1] := -1;
end;

procedure TEpollBackend.RegisterConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv:   epoll_event;
begin
  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events   := EPOLLIN or EPOLLONESHOT;
  LEv.data.ptr := AConn;
  epoll_ctl(FEpollFd, EPOLL_CTL_ADD, LConn.Socket, @LEv);
end;

procedure TEpollBackend.PostRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv:   epoll_event;
begin
  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events   := EPOLLIN or EPOLLONESHOT;
  LEv.data.ptr := AConn;
  epoll_ctl(FEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
end;

procedure TEpollBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
var
  LConn:    TNativeConn absolute AConn;
  LSendLen: Integer;
begin
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AData);

  if LSendLen = 0 then
  begin
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  LConn.PendingSend       := AData;
  LConn.PendingSendActual := AActualLen;
  LConn.SentBytes         := 0;
  _FlushSend(AConn);
end;

procedure TEpollBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  epoll_ctl(FEpollFd, EPOLL_CTL_DEL, LConn.Socket, nil);
  // R-6: TCP half-close — FIN before RST so the client receives the last bytes
  shutdown(LConn.Socket, SHUT_WR);
  _LinuxClose(LConn.Socket);
end;

// ---------------------------------------------------------------------------
// Internal: non-blocking send loop
// ---------------------------------------------------------------------------

procedure TEpollBackend._FlushSend(AConn: Pointer);
var
  LConn:      TNativeConn absolute AConn;
  LRemain:    Integer;
  LN:         NativeInt;
  LEv:        epoll_event;
  LTotalSend: Integer;
begin
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
        // Kernel send buffer full — resume when EPOLLOUT fires
        FillChar(LEv, SizeOf(LEv), 0);
        LEv.events   := EPOLLOUT or EPOLLONESHOT;
        LEv.data.ptr := AConn;
        epoll_ctl(FEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
      end
      else
        FCallbacks.OnConnError(AConn);
      Exit;
    end;
  end;

  // All bytes sent — P-4: return pool buffer (no-op for non-pool buffers)
  TBufferPool.Release(LConn.PendingSend);
  LConn.PendingSendActual := 0;
  FCallbacks.OnSendComplete(AConn);
end;

// ---------------------------------------------------------------------------
// Internal: read one chunk
// ---------------------------------------------------------------------------

procedure TEpollBackend._DoRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LBuf:  array[0..RECV_BUF_SIZE - 1] of Byte;
  LN:    NativeInt;
begin
  LN := _LinuxRecv(LConn.Socket, @LBuf[0], RECV_BUF_SIZE, 0);
  if LN > 0 then
    FCallbacks.OnRecv(AConn, @LBuf[0], Cardinal(LN))
  else if LN = 0 then
    FCallbacks.OnConnError(AConn)  // graceful FIN
  else if GetLastError <> EAGAIN then
    FCallbacks.OnConnError(AConn);
  // EAGAIN: EPOLLONESHOT stays disarmed until PostRecv re-arms it
end;

// ---------------------------------------------------------------------------
// Accept thread
// ---------------------------------------------------------------------------

procedure TEpollBackend._Accept;
var
  LFd:      Integer;
  LAddr:    sockaddr_in;
  LAddrLen: Cardinal;
  LIP:      AnsiString;
  LOne:     Integer;
begin
  while True do
  begin
    FillChar(LAddr, SizeOf(LAddr), 0);
    LAddrLen := SizeOf(LAddr);
    LFd := _LinuxAccept4(FListenSocket, @LAddr, @LAddrLen,
      SOCK_NONBLOCK or SOCK_CLOEXEC);
    if LFd < 0 then
    begin
      if GetLastError = EINTR then Continue;
      Break;
    end;

    // Apply per-connection socket options before handing off to server
    LOne := 1;
    _LinuxSetsockopt(LFd, IPPROTO_TCP, TCP_NODELAY, @LOne, SizeOf(LOne));
    _LinuxSetsockopt(LFd, SOL_SOCKET, SO_KEEPALIVE, @LOne, SizeOf(LOne));

    LIP := AnsiString(inet_ntoa(LAddr.sin_addr));
    try
      FCallbacks.OnNewConn(NativeUInt(LFd),
        string(LIP) + ':' + IntToStr(ntohs(LAddr.sin_port)));
    except
      _LinuxClose(LFd);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Worker loop
// ---------------------------------------------------------------------------

procedure TEpollBackend._WorkerLoop;
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
        // Shutdown sentinel: consume one byte so level-triggered fires once per worker
        _LinuxRead(FShutdownPipe[0], @LDummy, 1);
        LDone := True;
        Break;
      end;

      LConn := TNativeConn(LEvents[I].data.ptr);
      try
        if (LEvents[I].events and (EPOLLERR or EPOLLHUP)) <> 0 then
          FCallbacks.OnConnError(LConn)
        else
        begin
          if (LEvents[I].events and EPOLLIN) <> 0 then
            _DoRecv(LConn);
          if (LEvents[I].events and EPOLLOUT) <> 0 then
            _FlushSend(LConn);
        end;
      except
        on E: Exception do
          Writeln(ErrOutput, '[epoll] WORKER_EX [', E.ClassName, ']: ', E.Message);
      end;
    end;
  end;
end;

{$ELSE}

interface
implementation  // empty stub on Windows

{$ENDIF}

end.
