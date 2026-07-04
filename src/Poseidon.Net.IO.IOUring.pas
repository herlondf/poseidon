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
//   Recv:     UInt64(PRecvCtx)              — bit 0 = 0 (pool-allocated, 8-byte aligned)
//   Send:     UInt64(TNativeConn) or $1     — bit 0 = 1
//   Shutdown: UD_SHUTDOWN = $FFFFFFFFFFFFFFFF
//
// v2 (#56): Recv contexts are pre-allocated in a contiguous pool (RECV_POOL_SIZE
// entries) at Create time, eliminating New/Dispose per recv operation.  Pool
// exhaustion (should not happen — sized to RING_ENTRIES) falls back to heap.

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
    FAcceptThreads: TArray<TThread>;   // per-core accept threads (#58)
    FCompThread:    TThread;
    // infrastructure
    FCallbacks:     IIOCallbacks;
    FListenSockets: TArray<Integer>;   // per-core listen sockets (#58)
    FSQLock:       TCriticalSection;
    FShutdown:     Boolean;
    FSQPoll:       Boolean;            // #60: kernel poll thread active
    FPSQFlags:     PUInt32;            // #60: pointer to sq_off.flags for NEED_WAKEUP check
    // Pre-allocated recv context pool (#56) — eliminates New/Dispose per recv
    FRecvCtxPool:  Pointer;             // contiguous block: RECV_POOL_SIZE × SizeOf(TRecvCtx)
    FRecvFreeIdx:  array of UInt16;     // free-list stack of pool indices
    FRecvFreeTop:  Integer;             // top of free stack
    FRecvPoolLock: TCriticalSection;    // protects free-list (separate from FSQLock)
    FRecvPoolBase: PByte;              // cached base address for index calculation
    // helpers
    procedure _AcceptOn(AListenFd: Integer);
    procedure _CompletionLoop;
    function  _SubmitSQE(AOpcode: Byte; AFd: Integer; ABuf: Pointer;
      ALen: UInt32; AUserData: UInt64): Boolean;
    procedure _ProcessCQE(AUserData: UInt64; ARes: Int32);
    procedure _ResubmitSend(AConn: TNativeConn);
    function  _RecvPoolAcquire: PRecvCtx;
    procedure _RecvPoolRelease(ACtx: PRecvCtx);
    procedure _NotifyKernel; inline;  // #60: io_uring_enter or SQPOLL wakeup
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
    procedure SocketClose(AConn: Pointer);
  end;

implementation

// ---------------------------------------------------------------------------
// io_uring constants and types
// ---------------------------------------------------------------------------

const
  // Linux x86-64 syscall numbers
  NR_IO_URING_SETUP    = NativeInt(425);
  NR_IO_URING_ENTER    = NativeInt(426);
  NR_IO_URING_REGISTER = NativeInt(427);

  // io_uring_enter flags
  IORING_ENTER_GETEVENTS  = UInt32(1);
  IORING_ENTER_SQ_WAKEUP  = UInt32(2);   // #60: wake up idle SQPOLL thread

  // io_uring_setup flags
  IORING_SETUP_SQPOLL     = UInt32(2);   // #60: kernel-side SQ polling thread

  // SQ ring flags (read from sq_off.flags at runtime)
  IORING_SQ_NEED_WAKEUP   = UInt32(1);   // #60: SQPOLL thread is idle, need wakeup

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

  RECV_BUF_SIZE  = 32768;
  RING_ENTRIES   = 512;
  RECV_POOL_SIZE = RING_ENTRIES;  // one recv ctx per possible in-flight SQE

  // io_uring_register opcodes
  IORING_REGISTER_PROBE = UInt32(8);   // added in kernel 5.6

  // io_uring_probe_op flag — op is supported by this kernel
  IO_URING_OP_SUPPORTED = UInt16(1);

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

  // io_uring_register IORING_REGISTER_PROBE structs (kernel 5.6+).
  // Used in the constructor to verify RECV/SEND opcode support before committing
  // to the io_uring backend.  If the register call fails (EINVAL on < 5.6), we
  // raise ENotSupportedException so HttpServer falls back to TEpollBackend.
  TIOUringProbeOp = packed record
    op:    Byte;
    resv:  Byte;
    flags: UInt16;   // IO_URING_OP_SUPPORTED = 1
    resv2: UInt32;
  end;

  // Header followed by ops[0..last_op] — we only care about ops up to opcode 23
  // (IORING_OP_SEND), so a fixed array of 32 entries is more than enough.
  TIOUringProbe = packed record
    last_op:  Byte;
    ops_len:  Byte;
    resv:     UInt16;
    resv2:    array[0..2] of UInt32;
    ops:      array[0..31] of TIOUringProbeOp;
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
  external 'libc.so.6' name 'syscall'; varargs;

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

// opcode, arg, nr_args, flags (flags always 0 for REGISTER_PROBE).
function _io_uring_register(AFd: Integer; AOpcode: UInt32;
  AArg: Pointer; ANrArgs: UInt32): Integer; inline;
begin
  Result := Integer(_csyscall(NR_IO_URING_REGISTER,
    AFd, AOpcode, AArg, ANrArgs));
end;

// ---------------------------------------------------------------------------
// libc helpers (same set as TEpollBackend — duplicated to avoid cross-coupling)
// ---------------------------------------------------------------------------

function _LinuxAccept4(sockfd: Integer; addr: Pointer; addrlen: Pointer;
  flags: Integer): Integer; cdecl; external 'libc.so.6' name 'accept4';
function _LinuxClose(fd: Integer): Integer; cdecl; external 'libc.so.6' name 'close';
function _LinuxSocket(domain, typ, protocol: Integer): Integer; cdecl;
  external 'libc.so.6' name 'socket';
function _LinuxBind(sockfd: Integer; addr: Pointer; addrlen: UInt32): Integer; cdecl;
  external 'libc.so.6' name 'bind';
function _LinuxListen(sockfd, backlog: Integer): Integer; cdecl;
  external 'libc.so.6' name 'listen';
function _LinuxSetsockopt(sockfd, level, optname: Integer; optval: Pointer;
  optlen: UInt32): Integer; cdecl; external 'libc.so.6' name 'setsockopt';

function _LinuxMmap(addr: Pointer; length: NativeUInt; prot, flags, fd: Integer;
  offset: Int64): Pointer; cdecl; external 'libc.so.6' name 'mmap';
function _LinuxMunmap(addr: Pointer; length: NativeUInt): Integer; cdecl;
  external 'libc.so.6' name 'munmap';

// ---------------------------------------------------------------------------
// TIOUringBackend — constructor / destructor
// ---------------------------------------------------------------------------

constructor TIOUringBackend.Create;
var
  LParams: TIOUringParams;
  LFd:     Integer;
  LProbe:  TIOUringProbe;
  LI:      Integer;
begin
  inherited Create;

  // Phase 1: check io_uring_setup is available (kernel >= 5.1).
  // Returns ring fd on success, or -ENOSYS / -EPERM on failure.
  FillChar(LParams, SizeOf(LParams), 0);
  LFd := _io_uring_setup(1, @LParams);
  if LFd >= 0 then
    _LinuxClose(LFd)
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

  // Phase 2: verify IORING_OP_RECV (22) and IORING_OP_SEND (23) are supported.
  // These opcodes require kernel >= 5.6.  IORING_REGISTER_PROBE itself was added
  // in 5.6, so -EINVAL here means the kernel predates 5.6 and lacks RECV/SEND.
  // We open a fresh 1-entry ring solely for the probe, then close it immediately.
  FillChar(LParams, SizeOf(LParams), 0);
  LFd := _io_uring_setup(1, @LParams);
  if LFd >= 0 then
  try
    FillChar(LProbe, SizeOf(LProbe), 0);
    if _io_uring_register(LFd, IORING_REGISTER_PROBE, @LProbe,
         SizeOf(LProbe.ops) div SizeOf(TIOUringProbeOp)) < 0 then
      raise ENotSupportedException.Create(
        'io_uring unavailable: IORING_REGISTER_PROBE failed (kernel < 5.6)');

    if (LProbe.last_op < IORING_OP_SEND) or
       ((LProbe.ops[IORING_OP_RECV].flags and IO_URING_OP_SUPPORTED) = 0) or
       ((LProbe.ops[IORING_OP_SEND].flags and IO_URING_OP_SUPPORTED) = 0) then
      raise ENotSupportedException.Create(
        'io_uring unavailable: IORING_OP_RECV/SEND not supported (kernel < 5.6)');
  finally
    _LinuxClose(LFd);
  end;

  FRingFd       := -1;
  FSQLock       := TCriticalSection.Create;
  FRecvPoolLock := TCriticalSection.Create;
  FShutdown     := False;

  // Pre-allocate recv context pool — contiguous block for cache locality
  FRecvCtxPool := AllocMem(RECV_POOL_SIZE * SizeOf(TRecvCtx));
  FRecvPoolBase := PByte(FRecvCtxPool);
  SetLength(FRecvFreeIdx, RECV_POOL_SIZE);
  FRecvFreeTop := RECV_POOL_SIZE;
  for LI := 0 to RECV_POOL_SIZE - 1 do
    FRecvFreeIdx[LI] := UInt16(LI);
end;

destructor TIOUringBackend.Destroy;
begin
  if FRecvCtxPool <> nil then
  begin
    FreeMem(FRecvCtxPool);
    FRecvCtxPool := nil;
  end;
  FreeAndNil(FRecvPoolLock);
  FreeAndNil(FSQLock);
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// IIOBackend — lifecycle
// ---------------------------------------------------------------------------

procedure TIOUringBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);

  function CreateListenSocket: Integer;
  var
    LAddr: sockaddr_in;
    LOne:  Integer;
  begin
    Result := _LinuxSocket(AF_INET, SOCK_STREAM or SOCK_CLOEXEC, 0);
    if Result < 0 then
      raise Exception.Create('socket() failed: ' + IntToStr(GetLastError));

    LOne := 1;
    _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEADDR, @LOne, SizeOf(LOne));
    _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEPORT, @LOne, SizeOf(LOne));
    if AFastOpen then
      _LinuxSetsockopt(Result, IPPROTO_TCP, 23 {TCP_FASTOPEN}, @LOne, SizeOf(LOne));

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
  LParams:   TIOUringParams;
  LOne, I:   Integer;
  LSQSize:   NativeUInt;
  LCQSize:   NativeUInt;
  LAcceptN:  Integer;
begin
  FCallbacks := ACallbacks;
  FShutdown  := False;
  LAcceptN   := AAcceptThreads;
  if LAcceptN < 1 then LAcceptN := 1;

  // --- Per-core listen sockets (#58) ---
  SetLength(FListenSockets, LAcceptN);
  for I := 0 to LAcceptN - 1 do
    FListenSockets[I] := CreateListenSocket;

  // --- io_uring ring ---
  // #60: try SQPOLL first (kernel 5.11+ or CAP_SYS_NICE); fall back silently
  FillChar(LParams, SizeOf(LParams), 0);
  LParams.flags          := IORING_SETUP_SQPOLL;
  LParams.sq_thread_idle := 10000;  // 10ms idle before kernel poller sleeps
  FRingFd := _io_uring_setup(RING_ENTRIES, @LParams);
  if FRingFd >= 0 then
    FSQPoll := True
  else
  begin
    // SQPOLL not available — normal mode
    FSQPoll := False;
    FillChar(LParams, SizeOf(LParams), 0);
    FRingFd := _io_uring_setup(RING_ENTRIES, @LParams);
  end;
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
  FPSQFlags := PUInt32(PByte(FSQRing) + LParams.sq_off.flags);  // #60: NEED_WAKEUP

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

  // --- Per-core accept threads (#58) ---
  SetLength(FAcceptThreads, LAcceptN);
  for I := 0 to LAcceptN - 1 do
  begin
    var LFd := FListenSockets[I];
    FAcceptThreads[I] := TThread.CreateAnonymousThread(
      procedure begin _AcceptOn(LFd); end);
    FAcceptThreads[I].FreeOnTerminate := False;
    FAcceptThreads[I].Start;
  end;
end;

procedure TIOUringBackend.StopAccept;
var
  I: Integer;
begin
  for I := 0 to High(FListenSockets) do
  begin
    if FListenSockets[I] >= 0 then
      _LinuxClose(FListenSockets[I]);
    FListenSockets[I] := -1;
  end;
  for I := 0 to High(FAcceptThreads) do
  begin
    if FAcceptThreads[I] <> nil then
    begin
      FAcceptThreads[I].WaitFor;
      FreeAndNil(FAcceptThreads[I]);
    end;
  end;
  SetLength(FAcceptThreads, 0);
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
  LCtx:  PRecvCtx;
  LConn: TNativeConn absolute AConn;
begin
  LCtx := _RecvPoolAcquire;
  LCtx^.Conn := LConn;
  LConn.AddRef;  // #43: keep conn alive while recv CQE is in-flight
  FSQLock.Acquire;
  try
    if not _SubmitSQE(IORING_OP_RECV, LConn.Socket,
      @LCtx^.Buf[0], RECV_BUF_SIZE, UInt64(LCtx)) then
    begin
      // Ring full — cancel the ref we just took and signal an error so the
      // server closes the connection instead of leaving it orphaned forever.
      LConn.Release;
      _RecvPoolRelease(LCtx);
      FCallbacks.OnConnError(AConn);
      Exit;
    end;
    _NotifyKernel;
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
// Pre-allocated recv context pool (#56)
// ---------------------------------------------------------------------------

function TIOUringBackend._RecvPoolAcquire: PRecvCtx;
var
  LIdx: Integer;
begin
  FRecvPoolLock.Acquire;
  try
    if FRecvFreeTop > 0 then
    begin
      Dec(FRecvFreeTop);
      LIdx := FRecvFreeIdx[FRecvFreeTop];
      Result := PRecvCtx(FRecvPoolBase + NativeUInt(LIdx) * SizeOf(TRecvCtx));
      Exit;
    end;
  finally
    FRecvPoolLock.Release;
  end;
  // Pool exhausted (should not happen — pool sized to RING_ENTRIES) — heap fallback
  New(Result);
end;

procedure TIOUringBackend._RecvPoolRelease(ACtx: PRecvCtx);
var
  LOffset: NativeUInt;
  LIdx:    Integer;
begin
  LOffset := NativeUInt(PByte(ACtx)) - NativeUInt(FRecvPoolBase);
  // Check if the pointer belongs to our pool
  if LOffset < NativeUInt(RECV_POOL_SIZE) * SizeOf(TRecvCtx) then
  begin
    LIdx := Integer(LOffset div SizeOf(TRecvCtx));
    FRecvPoolLock.Acquire;
    try
      FRecvFreeIdx[FRecvFreeTop] := UInt16(LIdx);
      Inc(FRecvFreeTop);
    finally
      FRecvPoolLock.Release;
    end;
  end
  else
    // Heap-allocated fallback context
    Dispose(ACtx);
end;

// ---------------------------------------------------------------------------
// #60: Notify kernel about new SQEs.  In normal mode, calls io_uring_enter
// with to_submit=1.  In SQPOLL mode, the kernel poller picks up SQEs
// automatically; we only call io_uring_enter if it went idle (NEED_WAKEUP).
// ---------------------------------------------------------------------------

procedure TIOUringBackend._NotifyKernel;
begin
  if FSQPoll then
  begin
    // Kernel poller is active — only wake it if it went idle
    if (FPSQFlags <> nil) and
       ((FPSQFlags^ and IORING_SQ_NEED_WAKEUP) <> 0) then
      _io_uring_enter(FRingFd, 0, 0, IORING_ENTER_SQ_WAKEUP);
  end
  else
    _io_uring_enter(FRingFd, 1, 0, 0);
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

  AConn.AddRef;  // #43: keep conn alive while send CQE is in-flight
  FSQLock.Acquire;
  try
    if not _SubmitSQE(IORING_OP_SEND, AConn.Socket,
      @AConn.PendingSend[AConn.SentBytes], UInt32(LRemain),
      UInt64(AConn) or UD_TAG_SEND) then
    begin
      AConn.Release;  // op not posted — drop the ref we just took
      FCallbacks.OnConnError(AConn);
      Exit;
    end;
    _NotifyKernel;
  finally
    FSQLock.Release;
  end;
end;

// ---------------------------------------------------------------------------
// Internal: CQE dispatch
// ---------------------------------------------------------------------------

procedure TIOUringBackend._ProcessCQE(AUserData: UInt64; ARes: Int32);
var
  LCtx:       PRecvCtx;
  LConn:      TNativeConn;
  LRecvConn:  TNativeConn;
  LTotal:     Integer;
begin
  if AUserData = UD_SHUTDOWN then
  begin
    FShutdown := True;
    Exit;
  end;

  if (AUserData and UD_TAG_SEND) <> 0 then
  begin
    // --- Send completion ---
    // user_data encodes the connection pointer with bit 0 set as the send tag.
    LConn := TNativeConn(Pointer(UInt64(AUserData and not UD_TAG_SEND)));

    if ARes <= 0 then
    begin
      // Error or connection closed by peer during send
      FCallbacks.OnConnError(LConn);
      LConn.Release;  // #43: drop send-op ref (AddRef was in _ResubmitSend)
      Exit;
    end;

    Inc(LConn.SentBytes, ARes);
    LTotal := LConn.PendingSendActual;
    if LTotal = 0 then LTotal := Length(LConn.PendingSend);

    if LConn.SentBytes < LTotal then
    begin
      // Partial send — re-submit for the remaining bytes.
      // _ResubmitSend does its own AddRef; we Release the current send-op ref.
      _ResubmitSend(LConn);
      LConn.Release;  // #43: drop this send-op ref; _ResubmitSend owns the next one
    end
    else
    begin
      // All bytes delivered — return buffer, notify server, then drop our ref.
      TBufferPool.Release(LConn.PendingSend);
      LConn.PendingSendActual := 0;
      FCallbacks.OnSendComplete(LConn);  // may call PostRecv (which AddRefs)
      LConn.Release;  // #43: drop send-op ref last, after OnSendComplete
    end;
  end
  else
  begin
    // --- Recv completion ---
    LCtx      := PRecvCtx(Pointer(AUserData));
    LRecvConn := LCtx^.Conn;  // save before releasing ctx back to pool
    try
      if ARes > 0 then
        FCallbacks.OnRecv(LRecvConn, @LCtx^.Buf[0], Cardinal(ARes))
      else if ARes = 0 then
        FCallbacks.OnConnError(LRecvConn)    // graceful FIN from peer
      else if ARes = -EAGAIN then
        PostRecv(LRecvConn)                  // spurious wakeup — re-arm (PostRecv AddRefs)
      else
        FCallbacks.OnConnError(LRecvConn);   // real error
    finally
      _RecvPoolRelease(LCtx);
      LRecvConn.Release;  // #43: drop recv-op ref (AddRef was in PostRecv)
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

procedure TIOUringBackend._AcceptOn(AListenFd: Integer);
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
    LFd := _LinuxAccept4(AListenFd, @LAddr, @LAddrLen,
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
