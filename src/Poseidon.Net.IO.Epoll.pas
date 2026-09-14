unit Poseidon.Net.IO.Epoll;

// TEpollBackend - Linux epoll(7) backend.
//
// Shared-nothing per-core architecture.
// Each worker thread has its OWN epoll fd + listen socket (SO_REUSEPORT).
// The kernel distributes incoming connections across listen sockets via hash.
// Zero contention BETWEEN cores - no shared epoll fd, no dispatch queue.
//
// Accept and recv run inline on the owning core thread. Send does NOT: with
// SyncDispatch off (the Delphi default) the request pipeline runs on the
// request worker pool, so PostSend/PostSendV/_FlushSend are entered by a pool
// thread while the core thread can concurrently reach _FlushSend for the same
// connection via EPOLLOUT. All send state (PendingSend / PendingSendActual /
// SentBytes / SendBacklog) is therefore serialized on TNativeConn.Lock - the
// same discipline the io_uring backend applies. Callbacks are always invoked
// OUTSIDE that lock, because OnConnError -> _CloseConn can free the lock.

{$IFNDEF MSWINDOWS}

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  syncobjs,
  Poseidon.Compat.Posix,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Posix.SysSocket,
  Posix.NetinetIn,
  Posix.NetinetTcp,
  Posix.ArpaInet,
  Posix.Unistd,
  Posix.Errno,
  Posix.Signal,
  {$ENDIF}
  Poseidon.Net.IO,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer;

type
  // Named element type for the shutdown-pipe array: FPC rejects an inline
  // `array[0..1] of Integer` as a generic argument (`TArray<array...>`); the
  // named type compiles on both and is layout-identical.
  TShutdownPipe = array[0..1] of Integer;

  TEpollBackend = class(TInterfacedObject, IIOBackend)
  private
    FWorkers: TArray<TThread>;
    FListenSockets: TArray<Integer>;
    FEpollFds: TArray<Integer>;
    FShutdownPipes: TArray<TShutdownPipe>;
    FCallbacks: IIOCallbacks;
    FShutdown: Int64;  // 0=running, 1=shutdown; atomic via TInterlocked (Read requires Int64)
    procedure _CoreWorkerLoop(ACoreIdx: Integer);
    procedure _DoRecv(AConn: Pointer);
    procedure _FlushSend(AConn: Pointer; AFromCore: Boolean = False);
    function  _BeginSend(AConn: Pointer; const AData: TBytes;
      ALen: Integer): Boolean;
    function  _WritevOrQueue(AConn: Pointer;
      const AHeaders: TBytes; AHdrLen: Integer;
      const ABody: TBytes; ABodyLen: Integer): Integer;
    procedure _DrainSendLocked(AConn: Pointer; AFromCore: Boolean;
      var ABuf: TBytes; var AComplete: Boolean; var AFailed: Boolean;
      var AMore: Boolean);
    procedure _ArmSendReady(AConn: Pointer);
  public
    constructor Create;
    destructor Destroy; override;
    procedure SetInlineDispatch(AEnabled: Boolean);
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
    procedure SocketClose(AConn: Pointer; AFinalTeardown: Boolean = False);
  end;

implementation

uses
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.HttpServer;


const
  CRecvBufSize = 32768;
  CMaxEvents = 256;
  EPOLLIN = $00000001;
  EPOLLOUT = $00000004;
  EPOLLERR = $00000008;
  EPOLLHUP = $00000010;
  EPOLLRDHUP = $00002000;
  EPOLLONESHOT = Integer($40000000);
  EPOLL_CTL_ADD = 1;
  EPOLL_CTL_DEL = 2;
  EPOLL_CTL_MOD = 3;
  EPOLL_CLOEXEC = $80000;
  SO_REUSEPORT = 15;
  EAGAIN = 11;
  EINTR = 4;
  MSG_NOSIGNAL = $4000;
  SOCK_NONBLOCK = $800;
  SOCK_CLOEXEC = $80000;

  CTCP_FASTOPEN = 23;
  CTCP_DEFER_ACCEPT = 9;
  // SO_ZEROCOPY / MSG_ZEROCOPY removed - requires error queue polling
  // (MSG_ERRQUEUE) to avoid data corruption. SO_BUSY_POLL removed from default
  // path - burns CPU, should be opt-in for latency-critical scenarios.

  CListenSentinel = Pointer(1);

  // Outcome of the locked send-installation step, decided under LConn.Lock and
  // acted on by the caller AFTER the lock is released (the callbacks below can
  // reach _CloseConn, which frees LConn.Lock itself once the last ref drops).
  CSendQueued   = 0;  // appended to the backlog - a send was already in flight
  CSendComplete = 1;  // written in full inline - fire OnSendComplete
  CSendFailed   = 2;  // hard socket error - fire OnConnError
  CSendFlush    = 3;  // installed as the active send - caller drives _FlushSend

  // Headroom added when growing SendBacklog, so a burst of small out-of-band
  // sends does not realloc on every append.
  CBacklogSlack = 8192;

type
  epoll_data_t = record
    case Integer of
      0: (ptr: Pointer);
      1: (fd: Integer);
  end;
  epoll_event = packed record
    events: UInt32;
    data: epoll_data_t;
  end;

  iovec = record
    iov_base: Pointer;
    iov_len: NativeUInt;
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

threadvar
  GCurrentEpollFd: Integer;

type
  TCoreWorkerThread = class(TThread)
  private
    FBackend: TEpollBackend;
    FCoreIdx: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ABackend: TEpollBackend; ACoreIdx: Integer);
  end;

constructor TCoreWorkerThread.Create(ABackend: TEpollBackend; ACoreIdx: Integer);
begin
  inherited Create(True);
  FBackend := ABackend;
  FCoreIdx := ACoreIdx;
  FreeOnTerminate := False;
end;

procedure TCoreWorkerThread.Execute;
begin
  // L4: drenar TLC do worker no fim - evita vazamento em graceful reload.
  // Same for the per-thread Date-header cache / defer-banner (plain
  // UnicodeString threadvars, lazily created on this thread's first response):
  // leaked otherwise if this core thread ever builds a response directly
  // (SyncDispatch/backpressure/HTTP2 path).
  try
    FBackend._CoreWorkerLoop(FCoreIdx);
  finally
    TBufferPool.FlushThreadCache;
    ResetThreadDateCache;
    ResetThreadDeferVars;
  end;
end;


constructor TEpollBackend.Create;
begin
  inherited Create;
  FShutdown := 0;
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
    LOne: Integer;
  begin
    Result := _LinuxSocket(AF_INET, SOCK_STREAM or SOCK_NONBLOCK or SOCK_CLOEXEC, 0);
    if Result < 0 then
      raise Exception.Create('socket() failed: ' + IntToStr(GetLastError));

    LOne := 1;
    _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEADDR, @LOne, SizeOf(LOne));
    _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEPORT, @LOne, SizeOf(LOne));
    if AFastOpen then
      _LinuxSetsockopt(Result, IPPROTO_TCP, CTCP_FASTOPEN, @LOne, SizeOf(LOne));
    _LinuxSetsockopt(Result, IPPROTO_TCP, CTCP_DEFER_ACCEPT, @LOne, SizeOf(LOne));

    FillChar(LAddr, SizeOf(LAddr), 0);
    LAddr.sin_family := AF_INET;
    LAddr.sin_port := htons(APort);
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
  LEv: epoll_event;
  I: Integer;
  LCoreN: Integer;
begin
  FCallbacks := ACallbacks;
  FShutdown := 0;

  LCoreN := AWorkerCount;
  if LCoreN < 1 then LCoreN := 1;

  SetLength(FListenSockets, LCoreN);
  SetLength(FEpollFds, LCoreN);
  SetLength(FShutdownPipes, LCoreN);
  SetLength(FWorkers, LCoreN);

  for I := 0 to LCoreN - 1 do
  begin
    FListenSockets[I] := CreateListenSocket;

    if _LinuxPipe(@FShutdownPipes[I][0]) < 0 then
      raise Exception.Create('pipe() failed for core ' + IntToStr(I));

    FEpollFds[I] := epoll_create1(EPOLL_CLOEXEC);
    if FEpollFds[I] < 0 then
      raise Exception.Create('epoll_create1 failed for core ' + IntToStr(I));

    FillChar(LEv, SizeOf(LEv), 0);
    LEv.events := EPOLLIN;
    LEv.data.ptr := nil;
    epoll_ctl(FEpollFds[I], EPOLL_CTL_ADD, FShutdownPipes[I][0], @LEv);

    FillChar(LEv, SizeOf(LEv), 0);
    LEv.events := EPOLLIN;
    LEv.data.ptr := CListenSentinel;
    epoll_ctl(FEpollFds[I], EPOLL_CTL_ADD, FListenSockets[I], @LEv);

    FWorkers[I] := TCoreWorkerThread.Create(Self, I);
    FWorkers[I].Start;
  end;
end;

procedure TEpollBackend.SetInlineDispatch(AEnabled: Boolean);
begin
end;

procedure TEpollBackend.StopAccept;
begin
  // Listen sockets are closed in JoinWorkers after workers have exited,
  // avoiding race where a worker calls accept4 on a closed fd.
  TInterlocked.Exchange(FShutdown, 1);
end;

procedure TEpollBackend.ShutdownConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LSock: Integer;
begin
  // #173: skip if SocketClose already invalidated the fd (kernel may have
  // reused it for another accept4() connection).
  LSock := LConn.Socket;
  if LSock <> -1 then
    shutdown(LSock, SHUT_RDWR);
end;

procedure TEpollBackend.SignalWorkers;
var
  I: Integer;
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
  for I := 0 to High(FListenSockets) do
  begin
    if FListenSockets[I] >= 0 then
      _LinuxClose(FListenSockets[I]);
    FListenSockets[I] := -1;
  end;
  SetLength(FListenSockets, 0);
end;

procedure TEpollBackend.RegisterConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv: epoll_event;
begin
  LConn.OwnerEpollFd := GCurrentEpollFd;
  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events := EPOLLIN or EPOLLRDHUP or EPOLLONESHOT;
  LEv.data.ptr := AConn;
  epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_ADD, LConn.Socket, @LEv);
end;

procedure TEpollBackend.PostRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv: epoll_event;
begin
  FillChar(LEv, SizeOf(LEv), 0);
  LEv.events := EPOLLIN or EPOLLRDHUP or EPOLLONESHOT;
  LEv.data.ptr := AConn;
  epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
end;

// Installs AData as the connection's active send, or appends it to the backlog
// when one is already in flight. Returns True when the caller must drive
// _FlushSend, False when the bytes were copied into the backlog (the caller
// then owns AData and must return it to the pool).
function TEpollBackend._BeginSend(AConn: Pointer; const AData: TBytes;
  ALen: Integer): Boolean;
var
  LConn: TNativeConn absolute AConn;
  LNeed: Integer;
begin
  LConn.Lock.Enter;
  try
    if LConn.PendingSend = nil then
    begin
      LConn.PendingSend := AData;
      LConn.PendingSendActual := ALen;
      LConn.SentBytes := 0;
      Result := True;
      Exit;
    end;
    // A send is still draining: overwriting PendingSend here would drop the
    // remainder of the response already on the wire and leak its buffer.
    LNeed := LConn.SendBacklogLen + ALen;
    if LNeed > Length(LConn.SendBacklog) then
      SetLength(LConn.SendBacklog, LNeed + CBacklogSlack);
    Move(AData[0], LConn.SendBacklog[LConn.SendBacklogLen], ALen);
    LConn.SendBacklogLen := LNeed;
    Result := False;
  finally
    LConn.Lock.Leave;
  end;
end;

procedure TEpollBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
var
  LSendLen: Integer;
  LTmp: TBytes;
begin
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AData);

  if LSendLen = 0 then
  begin
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  if _BeginSend(AConn, AData, LSendLen) then
    _FlushSend(AConn)
  else
  begin
    LTmp := AData;
    TBufferPool.Release(LTmp);
  end;
end;

// Vectored send - writev() headers+body in one syscall. Everything that touches
// the connection's send state happens under LConn.Lock; the caller fires the
// resulting callback afterwards, outside the lock.
function TEpollBackend._WritevOrQueue(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer): Integer;
var
  LConn: TNativeConn absolute AConn;
  LVec: array[0..1] of iovec;
  LCount: Integer;
  LN: NativeInt;
  LTotal: Integer;
  LNeed: Integer;
  LConcat: TBytes;
begin
  Result := CSendQueued;
  LTotal := AHdrLen + ABodyLen;

  LConn.Lock.Enter;
  try
    // A send is still draining - writev() now would splice these bytes into the
    // middle of the response still on the wire. Backlog is the only safe path.
    if LConn.PendingSend <> nil then
    begin
      LNeed := LConn.SendBacklogLen + LTotal;
      if LNeed > Length(LConn.SendBacklog) then
        SetLength(LConn.SendBacklog, LNeed + CBacklogSlack);
      if AHdrLen > 0 then
        Move(AHeaders[0], LConn.SendBacklog[LConn.SendBacklogLen], AHdrLen);
      if ABodyLen > 0 then
        Move(ABody[0], LConn.SendBacklog[LConn.SendBacklogLen + AHdrLen], ABodyLen);
      LConn.SendBacklogLen := LNeed;
      Exit;
    end;

    LCount := 0;
    if AHdrLen > 0 then
    begin
      LVec[LCount].iov_base := @AHeaders[0];
      LVec[LCount].iov_len := AHdrLen;
      Inc(LCount);
    end;
    if ABodyLen > 0 then
    begin
      LVec[LCount].iov_base := @ABody[0];
      LVec[LCount].iov_len := ABodyLen;
      Inc(LCount);
    end;

    LN := _LinuxWritev(LConn.Socket, @LVec[0], LCount);
    if LN = LTotal then
    begin
      Result := CSendComplete;
      Exit;
    end;

    if (LN < 0) and (GetLastError <> EAGAIN) then
    begin
      Result := CSendFailed;
      Exit;
    end;
    if LN < 0 then LN := 0;

    LConcat := TBufferPool.Acquire(LTotal - Integer(LN));
    if LN < AHdrLen then
    begin
      Move(AHeaders[LN], LConcat[0], AHdrLen - Integer(LN));
      if ABodyLen > 0 then
        Move(ABody[0], LConcat[AHdrLen - Integer(LN)], ABodyLen);
    end
    else if LTotal - Integer(LN) > 0 then
      Move(ABody[Integer(LN) - AHdrLen], LConcat[0], LTotal - Integer(LN));

    LConn.PendingSend := LConcat;
    LConn.PendingSendActual := LTotal - Integer(LN);
    LConn.SentBytes := 0;
    Result := CSendFlush;
  finally
    LConn.Lock.Leave;
  end;
end;

procedure TEpollBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
var
  LTotal: Integer;
  LHLen: Integer;
  LBLen: Integer;
  LAction: Integer;
  LTmpH: TBytes;
  LTmpB: TBytes;
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

  LAction := _WritevOrQueue(AConn, AHeaders, LHLen, ABody, LBLen);

  // Every outcome consumes both buffers: sent inline, copied into the pending
  // remainder, or copied into the backlog.
  LTmpH := AHeaders; TBufferPool.Release(LTmpH);
  LTmpB := ABody;    TBufferPool.Release(LTmpB);

  case LAction of
    CSendComplete: FCallbacks.OnSendComplete(AConn);
    CSendFailed:   FCallbacks.OnConnError(AConn);
    CSendFlush:    _FlushSend(AConn);
  end;
end;

const
  // Contention on SocketOpGuard clears in nanoseconds (both guarded sections
  // below are one or two syscalls, nothing else) -- spin this many times
  // before yielding the CPU instead of reaching for a heavier primitive.
  CSocketGuardTightSpins = 1000;

// #234: acquires LConn.SocketOpGuard, blocking until free. Only ever called
// from SocketClose, which never runs on a core thread -- blocking here
// cannot stall any connection's I/O the way blocking in _ArmSendReady would.
procedure _AcquireSocketGuard(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LSpins: Integer;
begin
  LSpins := 0;
  while TInterlocked.CompareExchange(LConn.SocketOpGuard, 1, 0) <> 0 do
  begin
    Inc(LSpins);
    if LSpins > CSocketGuardTightSpins then
      TThread.Yield;
  end;
end;

procedure _ReleaseSocketGuard(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  TInterlocked.Exchange(LConn.SocketOpGuard, 0);
end;

// Never blocks. Returns False on contention -- the caller (_ArmSendReady,
// on the core thread) must skip its work safely rather than wait.
function _TryAcquireSocketGuard(AConn: Pointer): Boolean;
var
  LConn: TNativeConn absolute AConn;
begin
  Result := TInterlocked.CompareExchange(LConn.SocketOpGuard, 1, 0) = 0;
end;

procedure TEpollBackend.SocketClose(AConn: Pointer; AFinalTeardown: Boolean);
var
  LConn: TNativeConn absolute AConn;
  LSock: Integer;
begin
  // #234: excludes _ArmSendReady, which touches this same Socket/epoll_ctl
  // pair lock-free from the core thread -- without this, its stale
  // epoll_ctl(MOD) could land after this close() and silently re-point a
  // reused fd's epoll entry back at this (about-to-be-freed) connection.
  _AcquireSocketGuard(AConn);
  try
    // #173: invalidate the conn's fd copy before closing (kernel reuses fds).
    LSock := LConn.Socket;
    LConn.Socket := -1;
    epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_DEL, LSock, nil);
    shutdown(LSock, SHUT_WR);
    _LinuxClose(LSock);
  finally
    _ReleaseSocketGuard(AConn);
  end;
end;


// Drains the active send under LConn.Lock and reports what the caller must do
// once the lock is released.
//
// The lock is what makes this safe: the epoll core thread (EPOLLOUT, or the
// pending-send probe in _CoreWorkerLoop) and a request worker running the
// dispatch both reach the send path for the SAME connection. Unsynchronised,
// both could run the drain loop to completion and both return the SAME pooled
// buffer - which then sits in two thread caches at once and gets handed to two
// connections. glibc reports that as `double free or corruption`,
// `malloc(): unaligned tcache chunk detected` or `corrupted size vs. prev_size`.
//
// AMore signals that a backlogged send was promoted into PendingSend, so the
// caller loops instead of firing OnSendComplete mid-response.
//
// AFromCore marks the call as coming from the epoll core thread, which must
// NEVER block: a request worker holds LConn.Lock for the WHOLE dispatch, and a
// handler that blocks for seconds (DB, upstream web service) would otherwise
// freeze the core thread - and with it every other connection that core owns.
// The core thread therefore only TRIES the lock; on contention it re-arms
// EPOLLOUT and leaves the drain to the thread that holds the lock.
procedure TEpollBackend._DrainSendLocked(AConn: Pointer; AFromCore: Boolean;
  var ABuf: TBytes; var AComplete: Boolean; var AFailed: Boolean;
  var AMore: Boolean);
var
  LConn: TNativeConn absolute AConn;
  LRemain: Integer;
  LN: NativeInt;
  LEv: epoll_event;
  LTotalSend: Integer;
  LSendFlags: Integer;
  LNext: TBytes;
begin
  ABuf := nil;
  AComplete := False;
  AFailed := False;
  AMore := False;

  // #234: TryAddRef in the caller (_CoreWorkerLoop) closes the "refcount
  // already 0" window, but Helgrind still caught a live SIGSEGV here with a
  // held, non-zero reference -- something else is corrupting this specific
  // field under real concurrent load and the exact mechanism is still
  // unconfirmed. A nil Lock unambiguously means this connection cannot be
  // safely drained right now; bail out exactly like the lock-contention path
  // already does instead of dereferencing it.
  if not Assigned(LConn.Lock) then
  begin
    AFailed := True;
    Exit;
  end;

  if AFromCore then
  begin
    // TryEnter still succeeds for same-thread reentrancy; it only fails when
    // ANOTHER thread genuinely holds the lock.
    if not LConn.Lock.TryEnter then
    begin
      _ArmSendReady(AConn);
      Exit;
    end;
  end
  else
    LConn.Lock.Enter;
  try
    // Nothing to do: another thread already drained this send, or the socket is
    // gone (TNativeConn.Destroy returns any leftover PendingSend to the pool).
    if (LConn.PendingSend = nil) or (LConn.Closed <> 0) then Exit;

    LTotalSend := LConn.PendingSendActual;
    if LTotalSend = 0 then LTotalSend := Length(LConn.PendingSend);

    while LConn.SentBytes < LTotalSend do
    begin
      LRemain := LTotalSend - LConn.SentBytes;
      LSendFlags := MSG_NOSIGNAL;
      LN := _LinuxSend(LConn.Socket,
        @LConn.PendingSend[LConn.SentBytes], LRemain, LSendFlags);
      if LN > 0 then
        Inc(LConn.SentBytes, LN)
      else
      begin
        if GetLastError = EAGAIN then
        begin
          FillChar(LEv, SizeOf(LEv), 0);
          LEv.events := EPOLLOUT or EPOLLRDHUP or EPOLLONESHOT;
          LEv.data.ptr := AConn;
          epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
        end
        else
          AFailed := True;
        Exit;
      end;
    end;

    // Take the buffer out of the connection while still holding the lock, so
    // exactly one thread can ever return it to the pool.
    ABuf := LConn.PendingSend;
    LConn.PendingSend := nil;
    LConn.PendingSendActual := 0;
    LConn.SentBytes := 0;

    if LConn.SendBacklogLen > 0 then
    begin
      LNext := TBufferPool.Acquire(LConn.SendBacklogLen);
      Move(LConn.SendBacklog[0], LNext[0], LConn.SendBacklogLen);
      LConn.PendingSend := LNext;
      LConn.PendingSendActual := LConn.SendBacklogLen;
      LConn.SendBacklogLen := 0;
      AMore := True;
    end
    else
      AComplete := True;
  finally
    LConn.Lock.Leave;
  end;
end;

// Re-arms EPOLLOUT so a send this thread could not drain is retried later.
// Lock-free by design: it is called precisely when the lock is unavailable.
// A spurious wake is harmless - _FlushSend then finds PendingSend = nil.
// #234: TryAcquires SocketOpGuard against a concurrent SocketClose (e.g.
// TIdleSweepManager force-closing this same connection on another thread).
// On contention, skip entirely rather than wait - never block the core
// thread - the connection is being closed anyway, so a missed rearm is moot.
procedure TEpollBackend._ArmSendReady(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LEv: epoll_event;
begin
  if not _TryAcquireSocketGuard(AConn) then Exit;
  try
    if LConn.Socket = -1 then Exit;
    FillChar(LEv, SizeOf(LEv), 0);
    LEv.events := EPOLLOUT or EPOLLRDHUP or EPOLLONESHOT;
    LEv.data.ptr := AConn;
    epoll_ctl(LConn.OwnerEpollFd, EPOLL_CTL_MOD, LConn.Socket, @LEv);
  finally
    _ReleaseSocketGuard(AConn);
  end;
end;

procedure TEpollBackend._FlushSend(AConn: Pointer; AFromCore: Boolean);
var
  LBuf: TBytes;
  LComplete: Boolean;
  LFailed: Boolean;
  LMore: Boolean;
begin
  repeat
    _DrainSendLocked(AConn, AFromCore, LBuf, LComplete, LFailed, LMore);
    // Released outside the lock: this thread is the sole owner now.
    if LBuf <> nil then TBufferPool.Release(LBuf);
    if LFailed then
    begin
      FCallbacks.OnConnError(AConn);
      Exit;
    end;
  until not LMore;

  if LComplete then
    FCallbacks.OnSendComplete(AConn);
end;


procedure TEpollBackend._DoRecv(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LBuf: array[0..CRecvBufSize - 1] of Byte;
  LN: NativeInt;
begin
  LN := _LinuxRecv(LConn.Socket, @LBuf[0], CRecvBufSize, 0);
  if LN > 0 then
    FCallbacks.OnRecv(AConn, @LBuf[0], Cardinal(LN))
  else if LN = 0 then
    FCallbacks.OnConnError(AConn)
  else if GetLastError <> EAGAIN then
    FCallbacks.OnConnError(AConn);
end;

// Per-core worker loop - shared-nothing architecture.
// Each worker owns: listen socket + epoll fd + its connections.

procedure TEpollBackend._CoreWorkerLoop(ACoreIdx: Integer);
var
  LEvents:    array[0..CMaxEvents - 1] of epoll_event;
  LN, I: Integer;
  LConn: TNativeConn;
  LDone: Boolean;
  LDummy: Byte;
  LEpollFd: Integer;
  LListenFd: Integer;
  LNewFd: Integer;
  LAddr: sockaddr_in;
  LAddrLen: Cardinal;
  LIP: AnsiString;
  LOne: Integer;
begin
  LEpollFd := FEpollFds[ACoreIdx];
  LListenFd := FListenSockets[ACoreIdx];
  LDone := False;

  while not LDone do
  begin
    LN := epoll_wait(LEpollFd, @LEvents[0], CMaxEvents, -1);
    if LN < 0 then
    begin
      if GetLastError = EINTR then Continue;
      Break;
    end;

    for I := 0 to LN - 1 do
    begin
      if LEvents[I].data.ptr = nil then
      begin
        _LinuxRead(FShutdownPipes[ACoreIdx][0], @LDummy, 1);
        LDone := True;
        Break;
      end;

      if LEvents[I].data.ptr = CListenSentinel then
      begin
        while TInterlocked.Read(FShutdown) = 0 do
        begin
          FillChar(LAddr, SizeOf(LAddr), 0);
          LAddrLen := SizeOf(LAddr);
          LNewFd := _LinuxAccept4(LListenFd, @LAddr, @LAddrLen,
            SOCK_NONBLOCK or SOCK_CLOEXEC);
          if LNewFd < 0 then Break;  // EAGAIN or error - no more pending

          LOne := 1;
          _LinuxSetsockopt(LNewFd, IPPROTO_TCP, TCP_NODELAY, @LOne, SizeOf(LOne));
          _LinuxSetsockopt(LNewFd, SOL_SOCKET, SO_KEEPALIVE, @LOne, SizeOf(LOne));

          LIP := AnsiString(inet_ntoa(LAddr.sin_addr));
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

      LConn := TNativeConn(LEvents[I].data.ptr);
      // #234: LEvents[I].data.ptr is a weak pointer - the kernel's epoll
      // interest list holds it independent of this connection's Delphi-side
      // lifetime, so it can already be mid-Destroy (or fully freed) by the
      // time this event is dequeued. TryAddRef atomically refuses to
      // resurrect a connection whose refcount already hit 0 instead of
      // touching any of its fields (see TNativeConn.TryAddRef).
      if not LConn.TryAddRef then Continue;
      // Hold a ref for the whole event: _DoRecv / OnConnError can reach
      // _CloseConn, which drops the server ref (this backend takes none per
      // operation) and Destroys the connection - while the EPOLLOUT probe
      // below still reads LConn.PendingSend and _FlushSend still needs
      // LConn.Lock to exist.
      try
        try
          if (LEvents[I].events and (EPOLLERR or EPOLLHUP)) <> 0 then
            FCallbacks.OnConnError(LConn)
          else if ((LEvents[I].events and EPOLLRDHUP) <> 0)
               and (LConn.PendingSend = nil) then
            // Peer half-closed its write side (will send us no more data) and we
            // have nothing left to flush -- safe to treat as connection-done.
            // If a send IS still pending, RDHUP alone must NOT abort it: RDHUP
            // says nothing about whether the peer stopped READING, and this fd
            // can be armed for EPOLLOUT+EPOLLRDHUP together (see the EAGAIN
            // re-arm below) -- killing the connection here would cut off a
            // response that was still being sent, surfacing as a truncated
            // read on the client.
            FCallbacks.OnConnError(LConn)
          else
          begin
            if (LEvents[I].events and EPOLLIN) <> 0 then
              _DoRecv(LConn);
            if ((LEvents[I].events and EPOLLOUT) <> 0) or (LConn.PendingSend <> nil) then
              _FlushSend(LConn, True);  // core thread: never block on the lock
          end;
        except
          on E: Exception do
            Writeln(ErrOutput, '[epoll] CORE', ACoreIdx, '_EX [',
              E.ClassName, ']: ', E.Message);
        end;
      finally
        LConn.Release;
      end;
    end;
  end;
end;

initialization
  // #213: a network server must never be killed by SIGPIPE when it writes to a
  // socket whose peer already closed/reset the connection - h2spec and abusive
  // clients trigger this constantly. MSG_NOSIGNAL guards the epoll send loop,
  // but not writev() nor OpenSSL/libc internals, so ignore SIGPIPE process-wide
  // as the authoritative guard. This unit is always in the Linux `uses` graph
  // (HttpServer references both the epoll and io_uring backends), so this runs
  // regardless of which backend is selected at runtime.
  signal(SIGPIPE, TSignalHandler(SIG_IGN));

{$ELSE}

interface
implementation  // empty stub on Windows

{$ENDIF}

end.
