unit Poseidon.Net.IO.Epoll;

// TEpollBackend — Linux epoll(7) backend.
//
// #66: Shared-nothing per-core architecture.
// Each worker thread has its OWN epoll fd + listen socket (SO_REUSEPORT).
// Accept, recv, dispatch, and send all happen inline on the same thread.
// The kernel distributes incoming connections across listen sockets via hash.
// Zero contention between workers — no shared epoll fd, no dispatch queue.

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
    FWorkers:       TArray<TThread>;
    FListenSockets: TArray<Integer>;
    FEpollFds:      TArray<Integer>;      // #66: per-core epoll fds
    FShutdownPipes: TArray<array[0..1] of Integer>;
    FCallbacks:     IIOCallbacks;
    FShutdown:      Boolean;
    procedure _CoreWorkerLoop(ACoreIdx: Integer);
    procedure _DoRecv(AConn: Pointer);
    procedure _FlushSend(AConn: Pointer);
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
// epoll syscalls and types
// ---------------------------------------------------------------------------

const
  RECV_BUF_SIZE = 32768;
  MAX_EVENTS    = 256;
  EPOLLIN      = $00000001;
  EPOLLOUT     = $00000004;
  EPOLLERR     = $00000008;
  EPOLLHUP     = $00000010;
  EPOLLONESHOT = Integer($40000000);
  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  EPOLL_CTL_MOD = 3;
  EPOLL_CLOEXEC = $80000;
  SO_REUSEPORT  = 15;
  EAGAIN        = 11;
  EINTR         = 4;
  MSG_NOSIGNAL  = $4000;
  SOCK_NONBLOCK = $800;
  SOCK_CLOEXEC  = $80000;

  // Sentinel pointer for listen socket events
  LISTEN_SENTINEL = Pointer(1);

type
  epoll_data_t = record
    case Integer of
      0: (ptr: Pointer);
      1: (fd:  Integer);
  end;
  epoll_event = packed record
    events: UInt32;
    data:   epoll_data_t;
  end;

  // #61: Vectored I/O
  iovec = record
    iov_base: Pointer;
    iov_len:  NativeUInt;
  end;

function epoll_create1(flags: Integer): Integer; cdecl;
  external 'libc.so.6' name 'epoll_create1';
function epoll_ctl(epfd, op, fd: Integer; event: Pointer): Integer; cdecl;
  external 'libc.so.6' name 'epoll_ctl';
function epoll_wait(epfd: Integer; events: Pointer; maxevents, timeout: Integer): Integer; cdecl;
  external 'libc.so.6' name 'epoll_wait';

function _LinuxAccept4(sockfd: Integer; addr: Pointer; addrlen: Pointer;
  flags: Integer): Integer; cdecl; external 'libc.so.6' name 'accept4';
function _LinuxPipe(pipefd: PInteger): Integer; cdecl;
  external 'libc.so.6' name 'pipe';
function _LinuxRead(fd: Integer; buf: Pointer; count: NativeUInt): NativeInt; cdecl;
  external 'libc.so.6' name 'read';
function _LinuxWrite(fd: Integer; buf: Pointer; count: NativeUInt): NativeInt; cdecl;
  external 'libc.so.6' name 'write';
function _LinuxClose(fd: Integer): Integer; cdecl;
  external 'libc.so.6' name 'close';
function _LinuxSocket(domain, typ, protocol: Integer): Integer; cdecl;
  external 'libc.so.6' name 'socket';
function _LinuxBind(sockfd: Integer; addr: Pointer; addrlen: UInt32): Integer; cdecl;
  external 'libc.so.6' name 'bind';
function _LinuxListen(sockfd, backlog: Integer): Integer; cdecl;
  external 'libc.so.6' name 'listen';
function _LinuxSetsockopt(sockfd, level, optname: Integer; optval: Pointer; optlen: UInt32): Integer; cdecl;
  external 'libc.so.6' name 'setsockopt';
function _LinuxRecv(sockfd: Integer; buf: Pointer; len: NativeUInt; flags: Integer): NativeInt; cdecl;
  external 'libc.so.6' name 'recv';
function _LinuxSend(sockfd: Integer; buf: Pointer; len: NativeUInt; flags: Integer): NativeInt; cdecl;
  external 'libc.so.6' name 'send';
function _LinuxWritev(fd: Integer; iov: Pointer; iovcnt: Integer): NativeInt; cdecl;
  external 'libc.so.6' name 'writev';

// #66: threadvar so _OnNewSocket can set OwnerEpollFd on new connections
threadvar
  GCurrentEpollFd: Integer;

type
  // #66: helper thread class to capture core index by value (avoids closure bug)
  TCoreWorkerThread = class(TThread)
  private
    FBackend:  TEpollBackend;
    FCoreIdx:  Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ABackend: TEpollBackend; ACoreIdx: Integer);
  end;

constructor TCoreWorkerThread.Create(ABackend: TEpollBackend; ACoreIdx: Integer);
begin
  inherited Create(True);  // create suspended
  FBackend  := ABackend;
  FCoreIdx  := ACoreIdx;
  FreeOnTerminate := False;
end;

procedure TCoreWorkerThread.Execute;
begin
  FBackend._CoreWorkerLoop(FCoreIdx);
end;

// ---------------------------------------------------------------------------
// TEpollBackend
// ---------------------------------------------------------------------------

constructor TEpollBackend.Create;
begin
  inherited Create;
  FShutdown := False;
end;

destructor TEpollBackend.Destroy;
begin
  inherited Destroy;
end;

procedure TEpollBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);

  function CreateListenSocket: Integer;
  var
    LAddr: sockaddr_in;
    LOne:  Integer;
  begin
    // #66: SOCK_NONBLOCK required — accept loop must not block the worker
    Result := _LinuxSocket(AF_INET, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0);
    if Result < 0 then
      raise Exception.Create('socket() failed: ' + IntToStr(GetLastError));

    LOne := 1;
    _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEADDR, @LOne, SizeOf(LOne));
    _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEPORT, @LOne, SizeOf(LOne));
    if AFastOpen then
      _LinuxSetsockopt(Result, IPPROTO_TCP, 23 {TCP_FASTOPEN}, @LOne, SizeOf(LOne));
    _LinuxSetsockopt(Result, IPPROTO_TCP, 9 {TCP_DEFER_ACCEPT}, @LOne, SizeOf(LOne));

    FillChar(LAddr, SizeOf(LAddr), 0);
    LAddr.sin_family := AF_INET;
    LAddr.sin_port   := htons(APort);
    if (AHost = '0.0.0.0') or (AHost = '') then
      LAddr.sin_addr.s_addr := INADDR_ANY
    else
      LAddr.sin_addr.s_addr := inet_addr(MarshaledAString(AnsiString(AHost)));

    if _LinuxBind(Result, @LAddr, SizeOf(LAddr)) < 0 then
      raise Exception.Create('bind() failed: ' + IntToStr(GetLastError));
    if _LinuxListen(Result, SOMAXCONN) < 0 then
      raise Exception.Create('listen() failed: ' + IntToStr(GetLastError));
  end;

var
  LEv:      epoll_event;
  I:        Integer;
  LCoreN:   Integer;
begin
  FCallbacks := ACallbacks;
  FShutdown  := False;

  // #66: N cores, each with its own epoll + listen socket
  LCoreN := AWorkerCount;
  if LCoreN < 1 then LCoreN := 1;

  SetLength(FListenSockets, LCoreN);
  SetLength(FEpollFds, LCoreN);
  SetLength(FShutdownPipes, LCoreN);
  SetLength(FWorkers, LCoreN);

  for I := 0 to LCoreN - 1 do
  begin
    // Create listen socket with SO_REUSEPORT
    FListenSockets[I] := CreateListenSocket;

    // Create per-core shutdown pipe
    if _LinuxPipe(@FShutdownPipes[I][0]) < 0 then
      raise Exception.Create('pipe() failed for core ' + IntToStr(I));

    // Create per-core epoll
    FEpollFds[I] := epoll_create1(EPOLL_CLOEXEC);
    if FEpollFds[I] < 0 then
      raise Exception.Create('epoll_create1 failed for core ' + IntToStr(I));

    // Register shutdown pipe with epoll
    FillChar(LEv, SizeOf(LEv), 0);
    LEv.events   := EPOLLIN;
    LEv.data.ptr := nil;  // shutdown sentinel
    epoll_ctl(FEpollFds[I], EPOLL_CTL_ADD, FShutdownPipes[I][0], @LEv);

    // Register listen socket with epoll — accept via epoll, not separate thread
    FillChar(LEv, SizeOf(LEv), 0);
    LEv.events   := EPOLLIN;
    LEv.data.ptr := LISTEN_SENTINEL;
    epoll_ctl(FEpollFds[I], EPOLL_CTL_ADD, FListenSockets[I], @LEv);

    // #66: use TCoreWorkerThread — captures core index by value (no closure bug)
    FWorkers[I] := TCoreWorkerThread.Create(Self, I);
    FWorkers[I].Start;
  end;
end;

procedure TEpollBackend.StopAccept;
var
  I: Integer;
begin
  FShutdown := True;
  for I := 0 to High(FListenSockets) do
  begin
    if FListenSockets[I] >= 0 then
      _LinuxClose(FListenSockets[I]);
    FListenSockets[I] := -1;
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
    _LinuxWrite(FShutdownPipes[I][1], @LDummy, 1);
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
  for I := 0 to High(FEpollFds) do
  begin
    if FEpollFds[I] >= 0 then _LinuxClose(FEpollFds[I]);
    if FShutdownPipes[I][0] >= 0 then _LinuxClose(FShutdownPipes[I][0]);
    if FShutdownPipes[I][1] >= 0 then _LinuxClose(FShutdownPipes[I][1]);
  end;
  SetLength(FEpollFds, 0);
  SetLength(FShutdownPipes, 0);
end;

// #66: RegisterConn sets OwnerEpollFd from the calling thread's GCurrentEpollFd
procedure TEpollBackend.RegisterConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv:   epoll_event;
begin
  // #66: assign connection to the epoll of the thread that accepted it
  LConn.OwnerEpollFd := GCurrentEpollFd;
  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events   := EPOLLIN or EPOLLONESHOT;
  LEv.data.ptr := AConn;
  epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_ADD, LConn.Socket, @LEv);
end;

// #66: PostRecv uses the connection's OwnerEpollFd
procedure TEpollBackend.PostRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv:   epoll_event;
begin
  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events   := EPOLLIN or EPOLLONESHOT;
  LEv.data.ptr := AConn;
  epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
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

// #61: Vectored send — writev() headers+body in one syscall
procedure TEpollBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
var
  LConn:    TNativeConn absolute AConn;
  LVec:     array[0..1] of iovec;
  LCount:   Integer;
  LN:       NativeInt;
  LTotal:   Integer;
  LHLen:    Integer;
  LBLen:    Integer;
  LConcat:  TBytes;
  LTmpH:    TBytes;
  LTmpB:    TBytes;
begin
  LHLen := AHdrLen;
  if LHLen = 0 then LHLen := Length(AHeaders);
  LBLen := ABodyLen;
  if LBLen = 0 then LBLen := Length(ABody);
  LTotal := LHLen + LBLen;

  if LTotal = 0 then
  begin
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  LCount := 0;
  if LHLen > 0 then
  begin
    LVec[LCount].iov_base := @AHeaders[0];
    LVec[LCount].iov_len  := LHLen;
    Inc(LCount);
  end;
  if LBLen > 0 then
  begin
    LVec[LCount].iov_base := @ABody[0];
    LVec[LCount].iov_len  := LBLen;
    Inc(LCount);
  end;

  LN := _LinuxWritev(LConn.Socket, @LVec[0], LCount);
  if LN = LTotal then
  begin
    LTmpH := AHeaders; TBufferPool.Release(LTmpH);
    LTmpB := ABody;    TBufferPool.Release(LTmpB);
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  if (LN < 0) and (GetLastError <> EAGAIN) then
  begin
    LTmpH := AHeaders; TBufferPool.Release(LTmpH);
    LTmpB := ABody;    TBufferPool.Release(LTmpB);
    FCallbacks.OnConnError(AConn);
    Exit;
  end;
  if LN < 0 then LN := 0;

  LConcat := TBufferPool.Acquire(LTotal - Integer(LN));
  if LN < LHLen then
  begin
    Move(AHeaders[LN], LConcat[0], LHLen - Integer(LN));
    if LBLen > 0 then
      Move(ABody[0], LConcat[LHLen - Integer(LN)], LBLen);
  end
  else if LTotal - Integer(LN) > 0 then
    Move(ABody[Integer(LN) - LHLen], LConcat[0], LTotal - Integer(LN));

  LTmpH := AHeaders; TBufferPool.Release(LTmpH);
  LTmpB := ABody;    TBufferPool.Release(LTmpB);

  LConn.PendingSend       := LConcat;
  LConn.PendingSendActual := LTotal - Integer(LN);
  LConn.SentBytes         := 0;
  _FlushSend(AConn);
end;

procedure TEpollBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_DEL, LConn.Socket, nil);
  shutdown(LConn.Socket, SHUT_WR);
  _LinuxClose(LConn.Socket);
end;

// ---------------------------------------------------------------------------
// Internal: non-blocking send loop — uses connection's OwnerEpollFd
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
        FillChar(LEv, SizeOf(LEv), 0);
        LEv.events   := EPOLLOUT or EPOLLONESHOT;
        LEv.data.ptr := AConn;
        epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
      end
      else
        FCallbacks.OnConnError(AConn);
      Exit;
    end;
  end;

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
    FCallbacks.OnConnError(AConn)
  else if GetLastError <> EAGAIN then
    FCallbacks.OnConnError(AConn);
end;

// ---------------------------------------------------------------------------
// #66: Per-core worker loop — shared-nothing architecture
// Each worker owns: listen socket + epoll fd + its connections.
// Accept, recv, dispatch, and send all happen inline on the same thread.
// ---------------------------------------------------------------------------

procedure TEpollBackend._CoreWorkerLoop(ACoreIdx: Integer);
var
  LEvents:    array[0..MAX_EVENTS - 1] of epoll_event;
  LN, I:      Integer;
  LConn:      TNativeConn;
  LDone:      Boolean;
  LDummy:     Byte;
  LEpollFd:   Integer;
  LListenFd:  Integer;
  LNewFd:     Integer;
  LAddr:      sockaddr_in;
  LAddrLen:   Cardinal;
  LIP:        AnsiString;
  LOne:       Integer;
begin
  LEpollFd  := FEpollFds[ACoreIdx];
  LListenFd := FListenSockets[ACoreIdx];
  LDone     := False;

  while not LDone do
  begin
    LN := epoll_wait(LEpollFd, @LEvents[0], MAX_EVENTS, -1);
    if LN < 0 then
    begin
      if GetLastError = EINTR then Continue;
      Break;
    end;

    for I := 0 to LN - 1 do
    begin
      // Shutdown sentinel
      if LEvents[I].data.ptr = nil then
      begin
        _LinuxRead(FShutdownPipes[ACoreIdx][0], @LDummy, 1);
        LDone := True;
        Break;
      end;

      // #66: Listen socket ready — accept new connections inline
      if LEvents[I].data.ptr = LISTEN_SENTINEL then
      begin
        while not FShutdown do
        begin
          FillChar(LAddr, SizeOf(LAddr), 0);
          LAddrLen := SizeOf(LAddr);
          LNewFd := _LinuxAccept4(LListenFd, @LAddr, @LAddrLen,
            SOCK_NONBLOCK or SOCK_CLOEXEC);
          if LNewFd < 0 then Break;  // EAGAIN or error — no more pending

          LOne := 1;
          _LinuxSetsockopt(LNewFd, IPPROTO_TCP, TCP_NODELAY, @LOne, SizeOf(LOne));
          _LinuxSetsockopt(LNewFd, SOL_SOCKET, SO_KEEPALIVE, @LOne, SizeOf(LOne));

          LIP := AnsiString(inet_ntoa(LAddr.sin_addr));
          // #66: set threadvar BEFORE OnNewConn so RegisterConn uses this core's epoll
          GCurrentEpollFd := LEpollFd;
          try
            FCallbacks.OnNewConn(NativeUInt(LNewFd),
              string(LIP) + ':' + IntToStr(ntohs(LAddr.sin_port)));
          except
            _LinuxClose(LNewFd);
          end;
        end;
        Continue;
      end;

      // Client socket event
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
          Writeln(ErrOutput, '[epoll] CORE', ACoreIdx, '_EX [',
            E.ClassName, ']: ', E.Message);
      end;
    end;
  end;
end;

{$ELSE}

interface
implementation  // empty stub on Windows

{$ENDIF}

end.
