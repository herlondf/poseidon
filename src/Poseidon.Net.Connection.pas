unit Poseidon.Net.Connection;

// TNativeConn holds per-connection state and outlives any single owner:
//   Create              -> FRefCount = 1, the server's ref
//   PostRecv / PostSend -> AddRef, one ref per in-flight kernel op
//   completion          -> Release, after the callback runs
//   _CloseConn          -> Release, dropping the server ref
// A close while ops are still in flight does not free the object; the last
// Release does.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  syncobjs,
    {$IFDEF MSWINDOWS}
  WinSock2,
    {$ENDIF}
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
    {$IFDEF MSWINDOWS}
  Winapi.Winsock2,
    {$ENDIF}
  {$ENDIF}
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.HTTP2,
  Poseidon.Net.WebSocket;

const
  CCMHttp = 0;
  CCMWebSocket = 1;

type
  TNativeConn = class
  private
    FRefCount: Integer;
    FPadRef: array[0..14] of Integer; // cache-line isolation for FRefCount
  public
{$IFDEF MSWINDOWS}
    Socket: TSocket;
    RioRQ: Pointer;
{$ELSE}
    Socket: Integer;
{$ENDIF}
    RemoteAddr: string;
    // #213: serializes SSL object, AccumBuf and H2Conn across the IO thread and
    // the request worker pool. Recursive on purpose: _ProcessRecvSSL reaches
    // _EncryptAndSend during handshake and must not deadlock on itself.
    Lock: TCriticalSection;
    AccumBuf: TBytes;
    AccumLen: Integer;
    KeepAlive: Boolean;
    // Set inside _CloseConn so a deferred completion arriving later skips the
    // send. The responder's AddRef keeps the object alive, but the fd is gone.
    Closed: Integer;
    LastActivityTick: UInt64;
    // #224: stamped by TIdleSweepManager at ShutdownConn (0 = not shut down).
    // Still open on a later sweep past the grace period means the recv-error
    // completion never arrived; force the close rather than leak the fd, which
    // was seen stuck in FIN_WAIT2 with no kernel timeout.
    ShutdownRequestedTick: UInt64;
    // #254 (Slowloris): stamped once at connection creation, NEVER reset by
    // partial activity (unlike LastActivityTick, which resets on every byte -
    // exactly what let Slowloris hold a connection open forever by trickling
    // one byte every few seconds). Scoped to the first request only: once
    // HeadersEverCompleted flips true, this deadline no longer applies.
    HeaderDeadlineTick: UInt64;
    // #254: true once ParseHTTP1Request/ParseHTTP1Lightweight has ever
    // successfully parsed a full request line + headers on this connection.
    // A connection that reaches this point has proven it is not a
    // never-finishes-headers Slowloris client; the header deadline above
    // stops applying, and the connection falls back to the normal
    // IdleTimeoutMs behavior for the rest of its keep-alive life.
    HeadersEverCompleted: Boolean;
    // IOCP only: the just-posted zero-byte-recv context (PRecvZeroCtx in
    // Poseidon.Net.IO.IOCP.pas), non-nil only between PostRecv posting it and
    // its IOCP completion being dequeued (which Disposes it and clears this
    // back to nil, whether that happens through the normal worker loop or
    // through DrainCompletions at final teardown, see Poseidon.Net.IO.IOCP.pas,
    // #leak-conn-ctx). SocketClose only ever acts on this field itself when
    // called with AFinalTeardown = True (Stop(), after JoinWorkers, when no
    // worker thread remains to dequeue it normally); every other call site
    // leaves it alone and trusts the still-running worker loop, the only
    // safe single owner of that Dispose while workers are alive. Untyped
    // (Pointer) so this cross-platform unit need not know the context type.
    PendingRecvCtx: Pointer;
    InFlightPool: Integer;
    FPadInflight: array[0..14] of Integer; // cache-line isolation for InFlightPool
    SSLHandle: Pointer;
    SSLReadBio: Pointer;
    SSLWriteBio: Pointer;
    SSLHandshook: Boolean;
    WSMode: Byte;
    WSPath: string;
    WSConn: IPoseidonWSConn;
    WSDeflate: Boolean;
    H2Conn: TH2Conn;
    PPParsed: Boolean;
{$IFNDEF MSWINDOWS}
    PendingSend: TBytes;
    PendingSendActual: Integer;
    SentBytes: Integer;
    // #229: consecutive EAGAIN resubmits for the current send, reset on each new
    // PostSend. With CSO_SNDTIMEO bounding each attempt, this caps a permanently
    // stalled peer at a finite number of retries. See CMaxSendEAGAINRetries in
    // Poseidon.Net.IO.IOUring.
    SendEAGAINRetries: Integer;
    OwnerEpollFd: Integer;
    // #234: orders close(fd) against epoll_ctl(MOD). Without it, _ArmSendReady's
    // MOD can land after SocketClose's close, and if the kernel already reused
    // that fd number on the same epfd, the stale MOD points the new connection's
    // epoll entry at this freed object; the next event for that fd then reads
    // freed memory. 0 = free, 1 = held. SocketClose spins to acquire (two
    // syscalls, never on a core thread); _ArmSendReady only tries, because it
    // runs on the core thread and must never block. Skipping the rearm is safe:
    // the send retries on the next event.
    SocketOpGuard: Integer;
    // io_uring ring this connection is pinned to, so its SQEs always reach the
    // ring whose completion thread owns it. Same idea as OwnerEpollFd above;
    // unused by the epoll backend.
    OwnerRingIdx: Integer;
    // #11: io_uring does not order independent SEND SQEs, so several frames from
    // one dispatch interleave on the wire and TLS fails with 'bad record MAC'.
    // One send in flight per connection; the rest queue in SendBacklog under
    // Lock. The epoll backend shares the backlog (PendingSend <> nil marks a send
    // in flight); SendInFlight itself is io_uring-only.
    SendInFlight: Boolean;
    SendBacklog: TBytes;
    SendBacklogLen: Integer;
    // #230: two in-flight recvs on one socket can complete out of submission
    // order, and _ProcessRecvPlain appends in completion order, which reorders
    // bytes relative to the wire and desyncs the WebSocket parser under
    // small-fragment load. One recv in flight per connection, guarded by Lock.
    RecvInFlight: Boolean;
{$ENDIF}
    // NativeUInt so callers need no {$IFDEF}; cast internally per platform.
    constructor Create(ASocket: NativeUInt; const AAddr: string);
    destructor Destroy; override;

    // Never call Free directly; Release owns the teardown.
    procedure AddRef;
    procedure Release;
    // Shutdown-only: frees the connection without waiting for FRefCount to
    // reach 0 on its own. An idle keep-alive connection normally has an
    // outstanding WSARecv/io_uring recv holding its own ref (see class
    // comment); ShutdownConn's socket-level shutdown() does not synchronously
    // cancel that op, so if its completion has not landed by the time the
    // server joins its IO worker threads, that ref is never released and the
    // connection (and its Lock/AccumBuf) leaks. Callable ONLY after the
    // caller has positively confirmed no worker thread can still be mid-
    // callback for this connection (i.e. TPoseidonNativeServer.Stop, after
    // FRequestPool.Shutdown reported a clean drain AND FIOBackend.JoinWorkers
    // has returned): at that point no further completion will ever be
    // delivered for it, so any un-released ref never will be either, and
    // waiting for it would leak forever instead of freeing it. Calling this
    // while a worker could still be running is a use-after-free.
    procedure ForceRelease;
    // #234: for a caller holding only a raw pointer it does not own, such as the
    // epoll loop's LEvents[I].data.ptr. See the body for why AddRef is unsafe.
    function TryAddRef: Boolean;
  end;

implementation

procedure TNativeConn.AddRef;
begin
  TInterlocked.Increment(FRefCount);
end;

function TNativeConn.TryAddRef: Boolean;
var
  LCurrent, LPrev: Integer;
begin
  // #234: AddRef assumes the caller already owns a reference. The epoll loop
  // does not: the kernel's interest list holds the pointer independently of the
  // Delphi refcount, so the connection can reach 0 and enter Destroy (which nils
  // Lock and AccumBuf while the memory is still mapped) on one thread while the
  // core thread already has a stale event queued for it. A plain AddRef there
  // resurrects the dying object and the caller dereferences fields Destroy
  // already nil'd, which Helgrind confirmed as a nil Lock SIGSEGV under real
  // crash-loop traffic. CAS-refusing at 0 makes "still alive" and "take a ref"
  // one atomic step. On False the caller must skip the event and touch nothing.
  LCurrent := TInterlocked.CompareExchange(FRefCount, 0, 0);
  while LCurrent > 0 do
  begin
    LPrev := TInterlocked.CompareExchange(FRefCount, LCurrent + 1, LCurrent);
    if LPrev = LCurrent then
      Exit(True);
    LCurrent := LPrev;
  end;
  Result := False;
end;

procedure TNativeConn.ForceRelease;
begin
  FRefCount := 0;
  Self.Free;
end;

procedure TNativeConn.Release;
var
  LNew: Integer;
begin
  LNew := TInterlocked.Decrement(FRefCount);
  if LNew = 0 then
    Self.Free
  else if LNew < 0 then
    // #234: an extra Release somewhere. The object may already be mid-Destroy,
    // so touching any field would itself be a use-after-free and calling Free
    // would double-free. Logging just the pointer and count turns a delayed,
    // unattributable glibc abort into an immediate signal at the guilty call.
    Writeln(ErrOutput, '[poseidon][FATAL] TNativeConn.Release: refcount ' +
      'underflow to ' + IntToStr(LNew) + ' at 0x' +
      IntToHex(NativeUInt(Pointer(Self)), SizeOf(Pointer) * 2));
end;

constructor TNativeConn.Create(ASocket: NativeUInt; const AAddr: string);
begin
{$IFDEF MSWINDOWS}
  Socket := TSocket(ASocket);
  RioRQ := nil;
{$ELSE}
  Socket := Integer(ASocket);
{$ENDIF}
  RemoteAddr := AAddr;
  FRefCount := 1;
  Lock := TCriticalSection.Create;
  AccumBuf := TBufferPool.Acquire;
  AccumLen := 0;
  KeepAlive := False;
  Closed := 0;
  LastActivityTick := TThread.GetTickCount64;
  ShutdownRequestedTick := 0;
  HeaderDeadlineTick := LastActivityTick;
  HeadersEverCompleted := False;
  PendingRecvCtx := nil;
  InFlightPool := 0;
  SSLHandle := nil;
  SSLReadBio := nil;
  SSLWriteBio := nil;
  SSLHandshook := False;
  WSMode := CCMHttp;
  WSPath := '';
  WSConn := nil;
  WSDeflate := False;
  H2Conn := nil;
  PPParsed := False;
{$IFNDEF MSWINDOWS}
  OwnerEpollFd := -1;
  OwnerRingIdx := 0;  // valid default ring; overwritten by RegisterConn
  SocketOpGuard := 0;
{$ENDIF}
end;

destructor TNativeConn.Destroy;
begin
  if AccumBuf <> nil then TBufferPool.Release(AccumBuf);
{$IFNDEF MSWINDOWS}
  if PendingSend <> nil then TBufferPool.Release(PendingSend);
{$ENDIF}
  FreeAndNil(H2Conn);
  // Refcount is 0 here, so no other thread holds this connection and the lock
  // is uncontended. Free it last.
  FreeAndNil(Lock);
  inherited Destroy;
end;

end.
