unit Poseidon.Net.IO.IOUring;

// TIOUringBackend — Linux io_uring backend.
//
// Requires Linux kernel 5.1+ (io_uring_setup / syscall 425).
// Constructor raises ENotSupportedException if the syscall is unavailable
// (ENOSYS — kernel < 5.1) or forbidden (EPERM — seccomp sandbox), so
// TPoseidonNativeServer falls back to TEpollBackend at runtime with zero
// per-request overhead (the FIOBackend vtable pointer is set once at Create).
//
// Architecture:
//   Accept thread     — plain accept4() loop, identical to TEpollBackend.
//   Completion thread — single thread: io_uring_enter(IORING_ENTER_GETEVENTS)
//                       then drains all available CQEs and dispatches
//                       OnRecv / OnSendComplete / OnConnError directly.
//   Submission        — PostRecv / PostSend write SQEs under FSQLock then
//                       notify the kernel via io_uring_enter(to_submit=1).
//
// user_data encoding in SQEs / CQEs:
//   Recv:     UInt64(PRecvCtx)              — bit 0 = 0 (heap-allocated, 8-byte aligned)
//   Send:     UInt64(TNativeConn) or $1     — bit 0 = 1
//   Shutdown: UD_SHUTDOWN = $FFFFFFFFFFFFFFFF

{$IFNDEF MSWINDOWS}

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Posix.SysSocket,
  Posix.NetinetIn,
  Posix.NetinetTcp,
  Posix.ArpaInet,
  Posix.Unistd,
  Posix.Errno,
  Posix.SysMman,
  Poseidon.Net.IO,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer;

type
  TIOUringBackend = class(TInterfacedObject, IIOBackend)
  private
    FRingFd:       Integer;
    // mmap'd ring regions
    FSQRing:       Pointer;
    FCQRing:       Pointer;
    FSQEs:         Pointer;
    FSQRingSize:   NativeUInt;
    FCQRingSize:   NativeUInt;
    FSQEsSize:     NativeUInt;
    // resolved pointers into the SQ ring
    FPSQHead:      PUInt32;
    FPSQTail:      PUInt32;
    FPSQMask:      PUInt32;
    // resolved pointers into the CQ ring
    FPCQHead:      PUInt32;
    FPCQTail:      PUInt32;
    FPCQMask:      PUInt32;
    FPCQEs:        Pointer;   // base of CQE array
    // threads
    FAcceptThread: TThread;
    FCompThread:   TThread;
    // infrastructure
    FCallbacks:    IIOCallbacks;
    FListenSocket: Integer;
    FSQLock:       TCriticalSection;
    FShutdown:     Boolean;
    // helpers
    procedure _Accept;
    procedure _CompletionLoop;
    function  _SubmitSQE(AOpcode: Byte; AFd: Integer; ABuf: Pointer;
      ALen: UInt32; AUserData: UInt64): Boolean;
    procedure _ProcessCQE(AUserData: UInt64; ARes: Int32);
    procedure _ResubmitSend(AConn: TNativeConn);
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
// io_uring constants and types
// ---------------------------------------------------------------------------

const
  // Linux x86-64 syscall numbers
  NR_IO_URING_SETUP = NativeInt(425);
  NR_IO_URING_ENTER = NativeInt(426);

  // io_uring_enter flags
  IORING_ENTER_GETEVENTS = UInt32(1);

  // io_uring feature flags (returned in params.features)
  IORING_FEAT_SINGLE_MMAP = UInt32($0001);

  // SQE opcodes
  IORING_OP_NOP  = Byte(0);
  IORING_OP_RECV = Byte(22);
  IORING_OP_SEND = Byte(23);

  // mmap file offsets for the three ring regions
  IORING_OFF_SQ_RING = Int64(0);
  IORING_OFF_CQ_RING = Int64($8000000);
  IORING_OFF_SQES    = Int64($10000000);

  // user_data sentinels / tag bits
  UD_TAG_SEND  = UInt64(1);                    // bit 0 = send completion
  UD_SHUTDOWN  = UInt64($FFFFFFFFFFFFFFFF);    // NOP shutdown sentinel

  RECV_BUF_SIZE = 32768;
  RING_ENTRIES  = 512;

  // Linux setsockopt level/option constants not in the RTL
  SO_REUSEPORT = 15;

type
  // io_uring_setup params: offsets within the SQ ring mmap
  TIOSQRingOffsets = packed record
    head:         UInt32;
    tail:         UInt32;
    ring_mask:    UInt32;
    ring_entries: UInt32;
    flags:        UInt32;
    dropped:      UInt32;
    array_:       UInt32;
    resv1:        UInt32;
    user_addr:    UInt64;
  end;

  // io_uring_setup params: offsets within the CQ ring mmap
  TIOCQRingOffsets = packed record
    head:         UInt32;
    tail:         UInt32;
    ring_mask:    UInt32;
    ring_entries: UInt32;
    overflow:     UInt32;
    cqes:         UInt32;
    flags:        UInt32;
    resv1:        UInt32;
    user_addr:    UInt64;
  end;

  // Passed to io_uring_setup; filled in by the kernel with ring geometry
  TIOUringParams = packed record
    sq_entries:     UInt32;
    cq_entries:     UInt32;
    flags:          UInt32;
    sq_thread_cpu:  UInt32;
    sq_thread_idle: UInt32;
    features:       UInt32;
    wq_fd:          UInt32;
    resv:           array[0..2] of UInt32;
    sq_off:         TIOSQRingOffsets;
    cq_off:         TIOCQRingOffsets;
  end;

  // Submission Queue Entry — 64 bytes
  PIOUringSQE = ^TIOUringSQE;
  TIOUringSQE = packed record
    opcode:       Byte;
    flags:        Byte;
    ioprio:       UInt16;
    fd:           Int32;
    off:          UInt64;
    addr:         UInt64;
    len:          UInt32;
    op_flags:     UInt32;
    user_data:    UInt64;
    buf_index:    UInt16;
    personality:  UInt16;
    splice_fd_in: Int32;
    addr3:        UInt64;
    _pad2:        UInt64;
  end;

  // Completion Queue Entry — 16 bytes
  PIOUringCQE = ^TIOUringCQE;
  TIOUringCQE = packed record
    user_data: UInt64;
    res:       Int32;
    flags:     UInt32;
  end;

  // Heap-allocated recv context: stable buffer for in-flight IORING_OP_RECV.
  // Allocated in PostRecv; freed after the CQE is processed.
  PRecvCtx = ^TRecvCtx;
  TRecvCtx = record
    Conn: TNativeConn;
    Buf:  array[0..RECV_BUF_SIZE - 1] of Byte;
  end;

// ---------------------------------------------------------------------------
// Syscall wrappers
// ---------------------------------------------------------------------------

// libc's variadic syscall(2) — used for io_uring syscalls not yet in the RTL.
function _csyscall(number: NativeInt): NativeInt; cdecl;
  external 'c' name 'syscall'; varargs;

function _io_uring_setup(AEntries: UInt32; AParams: Pointer): Integer; inline;
begin
  Result := Integer(_csyscall(NR_IO_URING_SETUP, AEntries, AParams));
end;

// to_submit, min_complete, flags; last two args (sigmask, sigsetsize) = nil, 0.
function _io_uring_enter(AFd: Integer; AToSubmit: UInt32;
  AMinComplete: UInt32; AFlags: UInt32): Integer; inline;
begin
  Result := Integer(_csyscall(NR_IO_URING_ENTER,
    AFd, AToSubmit, AMinComplete, AFlags, nil, NativeInt(0)));
end;

// ---------------------------------------------------------------------------
// libc helpers (same set as TEpollBackend — duplicated to avoid cross-coupling)
// ---------------------------------------------------------------------------

function _LinuxAccept4(sockfd: Integer; addr: Pointer; addrlen: Pointer;
  flags: Integer): Integer; cdecl; external 'c' name 'accept4';
function _LinuxClose(fd: Integer): Integer; cdecl; external 'c' name 'close';
function _LinuxSocket(domain, typ, protocol: Integer): Integer; cdecl;
  external 'c' name 'socket';
function _LinuxBind(sockfd: Integer; addr: Pointer; addrlen: UInt32): Integer; cdecl;
  external 'c' name 'bind';
function _LinuxListen(sockfd, backlog: Integer): Integer; cdecl;
  external 'c' name 'listen';
function _LinuxSetsockopt(sockfd, level, optname: Integer; optval: Pointer;
  optlen: UInt32): Integer; cdecl; external 'c' name 'setsockopt';

function _LinuxMmap(addr: Pointer; length: NativeUInt; prot, flags, fd: Integer;
  offset: Int64): Pointer; cdecl; external 'c' name 'mmap';
function _LinuxMunmap(addr: Pointer; length: NativeUInt): Integer; cdecl;
  external 'c' name 'munmap';

// ---------------------------------------------------------------------------
// TIOUringBackend — constructor / destructor
// ---------------------------------------------------------------------------

constructor TIOUringBackend.Create;
var
  LParams: TIOUringParams;
  LFd:     Integer;
begin
  inherited Create;

  // Probe io_uring with a minimal ring (1 entry).  If the syscall exists the
  // kernel returns either the ring fd (success) or EINVAL (bad params but
  // syscall is present).  ENOSYS means "not in this kernel"; EPERM means
  // "blocked by seccomp / policy".  Both indicate we must fall back to epoll.
  FillChar(LParams, SizeOf(LParams), 0);
  LFd := _io_uring_setup(1, @LParams);
  if LFd >= 0 then
    _LinuxClose(LFd)               // probe succeeded — actual ring set up in StartListening
  else
  begin
    case GetLastError of
      ENOSYS: raise ENotSupportedException.Create(
        'io_uring unavailable: kernel < 5.1 (ENOSYS)');
      EPERM:  raise ENotSupportedException.Create(
        'io_uring unavailable: blocked by seccomp/policy (EPERM)');
    else
      raise ENotSupportedException.CreateFmt(
        'io_uring probe failed (errno %d)', [GetLastError]);
    end;
  end;

  FRingFd       := -1;
  FListenSocket := -1;
  FSQLock       := TCriticalSection.Create;
  FShutdown     := False;
end;

destructor TIOUringBackend.Destroy;
begin
  FreeAndNil(FSQLock);
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// IIOBackend — lifecycle
// ---------------------------------------------------------------------------

procedure TIOUringBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks);
var
  LParams:   TIOUringParams;
  LAddr:     sockaddr_in;
  LOne, I:   Integer;
  LSQSize:   NativeUInt;
  LCQSize:   NativeUInt;
begin
  FCallbacks := ACallbacks;
  FShutdown  := False;

  // --- Listen socket (identical to TEpollBackend) ---
  FListenSocket := _LinuxSocket(AF_INET, SOCK_STREAM or SOCK_CLOEXEC, 0);
  if FListenSocket < 0 then
    raise Exception.Create('socket() failed: ' + IntToStr(GetLastError));

  LOne := 1;
  _LinuxSetsockopt(FListenSocket, SOL_SOCKET, SO_REUSEADDR, @LOne, SizeOf(LOne));
  _LinuxSetsockopt(FListenSocket, SOL_SOCKET, SO_REUSEPORT, @LOne, SizeOf(LOne));
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

  // --- io_uring ring ---
  FillChar(LParams, SizeOf(LParams), 0);
  FRingFd := _io_uring_setup(RING_ENTRIES, @LParams);
  if FRingFd < 0 then
    raise Exception.CreateFmt('io_uring_setup failed (errno %d)', [GetLastError]);

  // mmap SQ ring
  LSQSize := NativeUInt(LParams.sq_off.array_) +
             NativeUInt(LParams.sq_entries) * SizeOf(UInt32);
  FSQRing := _LinuxMmap(nil, LSQSize, PROT_READ or PROT_WRITE,
    MAP_SHARED, FRingFd, IORING_OFF_SQ_RING);
  if FSQRing = MAP_FAILED then
    raise Exception.Create('mmap(SQ ring) failed');
  FSQRingSize := LSQSize;

  // mmap CQ ring — same mapping when IORING_FEAT_SINGLE_MMAP is set
  if (LParams.features and IORING_FEAT_SINGLE_MMAP) <> 0 then
  begin
    FCQRing     := FSQRing;
    FCQRingSize := 0;
  end
  else
  begin
    LCQSize := NativeUInt(LParams.cq_off.cqes) +
               NativeUInt(LParams.cq_entries) * SizeOf(TIOUringCQE);
    FCQRing := _LinuxMmap(nil, LCQSize, PROT_READ or PROT_WRITE,
      MAP_SHARED, FRingFd, IORING_OFF_CQ_RING);
    if FCQRing = MAP_FAILED then
      raise Exception.Create('mmap(CQ ring) failed');
    FCQRingSize := LCQSize;
  end;

  // mmap SQE array
  FSQEsSize := NativeUInt(LParams.sq_entries) * SizeOf(TIOUringSQE);
  FSQEs     := _LinuxMmap(nil, FSQEsSize, PROT_READ or PROT_WRITE,
    MAP_SHARED, FRingFd, IORING_OFF_SQES);
  if FSQEs = MAP_FAILED then
    raise Exception.Create('mmap(SQEs) failed');

  // Resolve pointers into the rings from the kernel-supplied byte offsets
  FPSQHead  := PUInt32(PByte(FSQRing) + LParams.sq_off.head);
  FPSQTail  := PUInt32(PByte(FSQRing) + LParams.sq_off.tail);
  FPSQMask  := PUInt32(PByte(FSQRing) + LParams.sq_off.ring_mask);

  FPCQHead  := PUInt32(PByte(FCQRing) + LParams.cq_off.head);
  FPCQTail  := PUInt32(PByte(FCQRing) + LParams.cq_off.tail);
  FPCQMask  := PUInt32(PByte(FCQRing) + LParams.cq_off.ring_mask);
  FPCQEs    := Pointer(PByte(FCQRing) + LParams.cq_off.cqes);

  // Initialise SQ indirection array with the identity mapping (slot i → SQE i).
  // This mapping is stable for the lifetime of the ring.
  for I := 0 to Integer(LParams.sq_entries) - 1 do
    PUInt32(PByte(FSQRing) + LParams.sq_off.array_ + NativeUInt(I) * SizeOf(UInt32))^
      := UInt32(I);

  // --- Completion thread ---
  FCompThread := TThread.CreateAnonymousThread(procedure begin _CompletionLoop; end);
  FCompThread.FreeOnTerminate := False;
  FCompThread.Start;

  // --- Accept thread ---
  FAcceptThread := TThread.CreateAnonymousThread(procedure begin _Accept; end);
  FAcceptThread.FreeOnTerminate := False;
  FAcceptThread.Start;
end;

procedure TIOUringBackend.StopAccept;
begin
  _LinuxClose(FListenSocket);
  FListenSocket := -1;
  if FAcceptThread <> nil then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;
end;

procedure TIOUringBackend.ShutdownConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  shutdown(LConn.Socket, SHUT_RDWR);
end;

procedure TIOUringBackend.SignalWorkers;
begin
  // Post a NOP SQE with the shutdown sentinel — the completion thread exits
  // when it sees UD_SHUTDOWN.
  FSQLock.Acquire;
  try
    _SubmitSQE(IORING_OP_NOP, -1, nil, 0, UD_SHUTDOWN);
    _io_uring_enter(FRingFd, 1, 0, 0);
  finally
    FSQLock.Release;
  end;
end;

procedure TIOUringBackend.JoinWorkers;
begin
  if FCompThread <> nil then
  begin
    FCompThread.WaitFor;
    FreeAndNil(FCompThread);
  end;
  // Unmap ring regions
  if (FSQEs <> nil) and (FSQEs <> MAP_FAILED) then
  begin
    _LinuxMunmap(FSQEs, FSQEsSize);
    FSQEs := nil;
  end;
  if (FCQRingSize > 0) and (FCQRing <> nil) and (FCQRing <> MAP_FAILED)
     and (FCQRing <> FSQRing) then
  begin
    _LinuxMunmap(FCQRing, FCQRingSize);
    FCQRing := nil;
  end;
  if (FSQRing <> nil) and (FSQRing <> MAP_FAILED) then
  begin
    _LinuxMunmap(FSQRing, FSQRingSize);
    FSQRing := nil;
  end;
  if FRingFd >= 0 then
  begin
    _LinuxClose(FRingFd);
    FRingFd := -1;
  end;
end;

// ---------------------------------------------------------------------------
// IIOBackend — per-connection
// ---------------------------------------------------------------------------

procedure TIOUringBackend.RegisterConn(AConn: Pointer);
begin
  // No registration step needed: io_uring identifies the fd in each individual SQE.
  // The first recv is posted by PostRecv immediately after this call (server contract).
end;

procedure TIOUringBackend.PostRecv(AConn: Pointer);
var
  LCtx: PRecvCtx;
begin
  New(LCtx);
  LCtx^.Conn := TNativeConn(AConn);
  FSQLock.Acquire;
  try
    if not _SubmitSQE(IORING_OP_RECV, TNativeConn(AConn).Socket,
      @LCtx^.Buf[0], RECV_BUF_SIZE, UInt64(LCtx)) then
    begin
      // Ring full — free context; connection will be reaped by the idle sweep.
      Dispose(LCtx);
      Exit;
    end;
    _io_uring_enter(FRingFd, 1, 0, 0);
  finally
    FSQLock.Release;
  end;
end;

procedure TIOUringBackend.PostSend(AConn: Pointer; const AData: TBytes;
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
  _ResubmitSend(LConn);
end;

procedure TIOUringBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  // R-6: TCP half-close — FIN before full teardown so the client reads pending bytes
  shutdown(LConn.Socket, SHUT_WR);
  _LinuxClose(LConn.Socket);
end;

// ---------------------------------------------------------------------------
// Internal: SQE submission — MUST be called under FSQLock
// ---------------------------------------------------------------------------

function TIOUringBackend._SubmitSQE(AOpcode: Byte; AFd: Integer;
  ABuf: Pointer; ALen: UInt32; AUserData: UInt64): Boolean;
var
  LTail, LIdx: UInt32;
  LSQE:        PIOUringSQE;
begin
  LTail := FPSQTail^;

  // Ring is full when distance from head equals ring capacity
  if LTail - FPSQHead^ >= FPSQMask^ + 1 then
  begin
    Result := False;
    Exit;
  end;

  LIdx := LTail and FPSQMask^;
  LSQE := PIOUringSQE(PByte(FSQEs) + NativeUInt(LIdx) * SizeOf(TIOUringSQE));
  FillChar(LSQE^, SizeOf(TIOUringSQE), 0);
  LSQE^.opcode    := AOpcode;
  LSQE^.fd        := AFd;
  LSQE^.addr      := UInt64(ABuf);
  LSQE^.len       := ALen;
  LSQE^.user_data := AUserData;

  // Advance the SQ tail.  The subsequent io_uring_enter syscall acts as a
  // full memory barrier, so a plain store here is sufficient on x86-64 TSO.
  FPSQTail^ := LTail + 1;

  Result := True;
end;

// ---------------------------------------------------------------------------
// Internal: send helper — submits a SEND SQE for the remaining bytes
// ---------------------------------------------------------------------------

procedure TIOUringBackend._ResubmitSend(AConn: TNativeConn);
var
  LTotal, LRemain: Integer;
begin
  LTotal  := AConn.PendingSendActual;
  if LTotal = 0 then LTotal := Length(AConn.PendingSend);
  LRemain := LTotal - AConn.SentBytes;

  FSQLock.Acquire;
  try
    if not _SubmitSQE(IORING_OP_SEND, AConn.Socket,
      @AConn.PendingSend[AConn.SentBytes], UInt32(LRemain),
      UInt64(AConn) or UD_TAG_SEND) then
    begin
      FCallbacks.OnConnError(AConn);
      Exit;
    end;
    _io_uring_enter(FRingFd, 1, 0, 0);
  finally
    FSQLock.Release;
  end;
end;

// ---------------------------------------------------------------------------
// Internal: CQE dispatch
// ---------------------------------------------------------------------------

procedure TIOUringBackend._ProcessCQE(AUserData: UInt64; ARes: Int32);
var
  LCtx:    PRecvCtx;
  LConn:   TNativeConn;
  LSent:   Integer;
  LTotal:  Integer;
begin
  if AUserData = UD_SHUTDOWN then
  begin
    FShutdown := True;
    Exit;
  end;

  if (AUserData and UD_TAG_SEND) <> 0 then
  begin
    // --- Send completion ---
    LConn := TNativeConn(Pointer(UInt64(AUserData and not UD_TAG_SEND)));

    if ARes <= 0 then
    begin
      // Error or connection closed by peer during send
      FCallbacks.OnConnError(LConn);
      Exit;
    end;

    Inc(LConn.SentBytes, ARes);
    LTotal := LConn.PendingSendActual;
    if LTotal = 0 then LTotal := Length(LConn.PendingSend);

    if LConn.SentBytes < LTotal then
    begin
      // Partial send — re-submit for the remaining bytes
      _ResubmitSend(LConn);
    end
    else
    begin
      // All bytes delivered to the kernel send buffer
      TBufferPool.Release(LConn.PendingSend);
      LConn.PendingSendActual := 0;
      FCallbacks.OnSendComplete(LConn);
    end;
  end
  else
  begin
    // --- Recv completion ---
    LCtx := PRecvCtx(Pointer(AUserData));
    try
      if ARes > 0 then
        FCallbacks.OnRecv(LCtx^.Conn, @LCtx^.Buf[0], Cardinal(ARes))
      else if ARes = 0 then
        FCallbacks.OnConnError(LCtx^.Conn)    // graceful FIN from peer
      else if ARes = -EAGAIN then
        PostRecv(LCtx^.Conn)                  // spurious wakeup — re-arm
      else
        FCallbacks.OnConnError(LCtx^.Conn);   // real error
    finally
      Dispose(LCtx);
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Completion thread — single thread; serial CQE drain after each wakeup
// ---------------------------------------------------------------------------

procedure TIOUringBackend._CompletionLoop;
var
  LHead, LMask: UInt32;
  LCQE:         PIOUringCQE;
begin
  while not FShutdown do
  begin
    // Block until the kernel has at least one completion ready
    _io_uring_enter(FRingFd, 0, 1, IORING_ENTER_GETEVENTS);

    // Drain all currently available CQEs in one pass
    LMask := FPCQMask^;
    LHead := FPCQHead^;
    while LHead <> FPCQTail^ do
    begin
      LCQE := PIOUringCQE(PByte(FPCQEs) +
        NativeUInt(LHead and LMask) * SizeOf(TIOUringCQE));
      try
        _ProcessCQE(LCQE^.user_data, LCQE^.res);
      except
        on E: Exception do
          Writeln(ErrOutput, '[io_uring] CQE_EX [', E.ClassName, ']: ', E.Message);
      end;
      Inc(LHead);
      // Advance CQ head immediately so the kernel can reuse the slot
      FPCQHead^ := LHead;
    end;
  end;
end;

// ---------------------------------------------------------------------------
// Accept thread — plain accept4() loop, identical to TEpollBackend._Accept
// ---------------------------------------------------------------------------

procedure TIOUringBackend._Accept;
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
      Break;  // listen socket closed by StopAccept
    end;

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

{$ELSE}

interface
implementation  // empty stub on Windows

{$ENDIF}

end.
