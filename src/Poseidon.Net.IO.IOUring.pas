unit Poseidon.Net.IO.IOUring;

// TIOUringBackend — Linux io_uring backend (shared-nothing, N rings).
//
// Requires Linux kernel 5.1+ (io_uring_setup / syscall 425).
// Constructor raises ENotSupportedException if the syscall is unavailable
// (ENOSYS — kernel < 5.1) or forbidden (EPERM — seccomp sandbox), so
// TPoseidonNativeServer falls back to TEpollBackend at runtime with zero
// per-request overhead (the FIOBackend vtable pointer is set once at Create).
//
// Architecture (shared-nothing per core — mirrors TEpollBackend):
//   The backend owns N TUringRing objects (N = AWorkerCount, one per core).
//   Each ring has:
//     - its OWN io_uring instance (ring fd + SQ/CQ mmaps + SQE array),
//     - its OWN listen socket (SO_REUSEPORT — kernel hashes new connections
//       across the N sockets, spreading load with zero userspace coordination),
//     - one accept thread (accept4() loop) that stamps GCurrentRingIdx = ring
//       index before OnNewConn, so RegisterConn pins the connection to it,
//     - one completion thread that drains that ring's CQEs and dispatches
//       OnRecv / OnSendComplete / OnConnError.
//   A connection is pinned to a ring for life (TNativeConn.OwnerRingIdx); every
//   PostRecv / PostSend / _ResubmitSend / SocketClose submits SQEs to THAT
//   ring's SQ. Recv, handler (SyncDispatch), and send-submit for a given
//   connection therefore all run on that ring's single completion thread — no
//   cross-ring locking, and N rings drive N cores in parallel. This replaces
//   the previous single-ring / single-completion-thread design, whose one
//   thread serialized every connection and capped throughput at ~2 cores.
//
//   SQPOLL is intentionally NOT used: one kernel poller thread per ring would
//   compete with the completion threads for the same cores. Submission uses a
//   plain io_uring_enter(to_submit=N) per batch.
//
// user_data encoding in SQEs / CQEs:
//   Recv:     UInt64(PRecvCtx)              — bit 0 = 0 (pool-allocated, 8-byte aligned)
//   Send:     UInt64(TNativeConn) or $1     — bit 0 = 1
//   SendZC:   UInt64(PSendZCRef) or $3      — bits 0+1 = 1
//   Shutdown: CUdShutdown = $FFFFFFFFFFFFFFFF
//
// Recv contexts are pre-allocated per ring in a contiguous pool (CRecvPoolSize
// entries) at StartListening time, eliminating New/Dispose per recv operation.
// Pool exhaustion falls back to heap.

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
  Posix.SysMman,
  {$ENDIF}
  Poseidon.Net.IO,
  Poseidon.Net.Connection,
  Poseidon.Net.Pool.Buffer;

type
  TIOUringBackend = class;  // forward — TUringRing holds a back-pointer

  // Per-ring state. One io_uring instance + one listen socket + one accept
  // thread + one completion thread. See the unit header for the shared-nothing
  // rationale. Same-unit code (TIOUringBackend) accesses these members directly.
  TUringRing = class
  public
    FBackend: TIOUringBackend;
    FIdx: Integer;
    FRingFd: Integer;
    FSQRing: Pointer;
    FCQRing: Pointer;
    FSQEs: Pointer;
    FSQRingSize: NativeUInt;
    FCQRingSize: NativeUInt;
    FSQEsSize: NativeUInt;
    FPSQHead: PUInt32;
    FPSQTail: PUInt32;
    FPSQMask: PUInt32;
    FPCQHead: PUInt32;
    FPCQTail: PUInt32;
    FPCQMask: PUInt32;
    FPCQEs: Pointer;
    FSQLock: TCriticalSection;
    FPendingSQEs: Integer;
    FCompThread: TThread;
    FListenSocket: Integer;
    FAcceptThread: TThread;   // fallback only (kernel without multishot accept)
    FMultishotAccept: Boolean; // True once this ring accepts via io_uring itself
    FAcceptErrStreak: Integer; // consecutive multishot-accept errors (fd exhaustion watch)
    // Registered files — per ring (io_uring registered fds are ring-local).
    FRegFiles: Boolean;
    FRegFds: array of Int32;
    FRegCount: Integer;
    FRegFreeStack: array of Integer;
    FRegFreeTop: Integer;
    FRegLock: TCriticalSection;
    // Pre-allocated recv-context pool — per ring.
    FRecvCtxPool: Pointer;
    FRecvFreeIdx: array of UInt16;
    FRecvFreeTop: Integer;
    FRecvPoolLock: TCriticalSection;
    FRecvPoolBase: PByte;
    constructor Create(ABackend: TIOUringBackend; AIdx: Integer);
    destructor Destroy; override;
    procedure SetupRing;       // io_uring_setup + mmap + reg-files init
    procedure StartThreads;    // completion thread, then accept thread
    procedure TeardownMaps;    // munmap rings + close ring fd (idempotent)
    procedure SignalShutdown;  // post one NOP to wake the completion thread
    function  _RegFileIndex(AFd: Integer): Integer;
    function  _RegisterFd(AFd: Integer): Integer;
    procedure _UnregisterFd(AFd: Integer);
    function  _RecvPoolAcquire: Pointer;
    procedure _RecvPoolRelease(ACtx: Pointer);
    procedure _NotifyKernel;
    function  _SubmitSQE(AOpcode: Byte; AFd: Integer; ABuf: Pointer;
      ALen: UInt32; AUserData: UInt64; AFlags: Byte = 0): Boolean;
    function  _SubmitAcceptMultishot: Boolean;  // one SQE arms all future accepts
    procedure _CompletionLoop;
    procedure _AcceptLoop;
  end;

  TIOUringBackend = class(TInterfacedObject, IIOBackend)
  private
    FRings: TArray<TUringRing>;
    FRingCount: Integer;
    FCallbacks: IIOCallbacks;
    FShutdown: Int64;  // 0=running, 1=shutdown; atomic via TInterlocked (Read requires Int64)
    FSendZC: Boolean;
    FBatchSubmit: Boolean;  // batch SQE submits on the completion thread (SyncDispatch)
    FHost: string;
    FPort: Integer;
    FFastOpen: Boolean;
    function  _RingOf(AConn: TNativeConn): TUringRing; inline;
    function  _CreateListenSocket: Integer;
    procedure _ResubmitSend(AConn: TNativeConn; AAsync: Boolean = False);
    // #11: per-connection send serialization (see TNativeConn.SendInFlight).
    // _BeginSend returns True if the caller should submit AData now, False if it
    // was queued (in flight). _KickNextSend, called on send completion, submits
    // the next queued chunk and returns True, or marks the conn idle -> False.
    function  _BeginSend(AConn: TNativeConn; const AData: TBytes; ALen: Integer): Boolean;
    function  _KickNextSend(AConn: TNativeConn): Boolean;
    procedure _ProcessCQE(ARing: TUringRing; AUserData: UInt64; ARes: Int32;
      AFlags: UInt32);
  public
    constructor Create;
    destructor Destroy; override;
    // IIOBackend
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
  NR_IO_URING_REGISTER = NativeInt(427);

  // io_uring_enter flags
  IORING_ENTER_GETEVENTS = UInt32(1);

  // io_uring_setup flags
  IORING_SETUP_CQSIZE = UInt32($200);
  IORING_SETUP_COOP_TASKRUN = UInt32($100);   // 1<<8: no IPI to notify completions (5.19+)

  // io_uring feature flags (returned in params.features)
  IORING_FEAT_SINGLE_MMAP = UInt32($0001);
  IORING_FEAT_NODROP = UInt32($0002);

  // SQE opcodes
  IORING_OP_NOP = Byte(0);
  IORING_OP_ACCEPT = Byte(13);
  IORING_OP_RECV = Byte(22);
  IORING_OP_SEND = Byte(23);

  IOSQE_ACCEPT_MULTISHOT = UInt16(1 shl 0);  // ioprio flag: keep accepting

  // SQE flags
  IOSQE_FIXED_FILE = Byte(1 shl 0);
  IOSQE_ASYNC = Byte(1 shl 4);  // force io-wq (blocking) execution

  CEAGAIN = 11;  // -EAGAIN from a SEND on a full non-blocking socket buffer

  // CQE flags
  IORING_CQE_F_MORE = UInt32(1 shl 1);  // more CQEs to come from this SQE

  // mmap file offsets for the three ring regions
  IORING_OFF_SQ_RING = Int64(0);
  IORING_OFF_CQ_RING = Int64($8000000);
  IORING_OFF_SQES = Int64($10000000);

  CUdTagSend = UInt64(1);
  CUdTagAccept = UInt64(2);
  CUdShutdown = UInt64($FFFFFFFFFFFFFFFF);

  // Zero-copy send (kernel 6.0+)
  IORING_OP_SEND_ZC = Byte(53);
  IORING_CQE_F_NOTIF = UInt32(1 shl 2);
  CUdTagSendZC = UInt64(3);

  // io_uring_register opcodes
  IORING_REGISTER_FILES = UInt32(2);
  IORING_REGISTER_FILES_UPDATE = UInt32(6);
  IORING_REGISTER_PROBE = UInt32(8);

  CRegFilesMax = 4096;  // max registered fd slots per ring

  // io_uring_probe_op flag — op is supported by this kernel
  IO_URING_OP_SUPPORTED = UInt16(1);

  // Linux setsockopt level/option constants not in the RTL
  SO_REUSEPORT = 15;
  CTCP_FASTOPEN = 23;
  CTCP_DEFER_ACCEPT = 9;

  CRecvBufSize = 32768;
  CRingEntries = 512;
  CCQEntries = 2048;
  // Zero-copy SEND (IORING_OP_SEND_ZC) only pays off above this payload size:
  // it costs a page-pin + TWO CQEs (result + notification) per send, so for the
  // small plaintext/json responses a plain IORING_OP_SEND (one CQE, kernel copy)
  // is cheaper. Below the threshold we use the regular send path.
  CSendZCThreshold = 16384;
  // Log once when a ring's multishot accept has failed this many times in a row
  // (e.g. sustained EMFILE / fd exhaustion) — surfaces the condition without
  // spamming stderr on every re-arm.
  CAcceptErrLogAt = 64;
  // Recv contexts per ring. Smaller than CRingEntries because connections are
  // now spread across N rings; on exhaustion _RecvPoolAcquire falls back to
  // heap (correct, just slower). 256 * 32 KiB = 8 MiB per ring.
  CRecvPoolSize = 256;

type
  // io_uring_files_update struct for IORING_REGISTER_FILES_UPDATE
  TIOUringFilesUpdate = packed record
    offset: UInt32;
    resv: UInt32;
    fds: UInt64; // pointer to fd array
  end;

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

  // Header followed by ops[0..last_op] — covers up to opcode 53
  // (IORING_OP_SEND_ZC), so a fixed array of 64 entries is needed.
  TIOUringProbe = packed record
    last_op:  Byte;
    ops_len:  Byte;
    resv:     UInt16;
    resv2:    array[0..2] of UInt32;
    ops:      array[0..63] of TIOUringProbeOp;
  end;

  // Pre-allocated recv context: stable buffer for in-flight IORING_OP_RECV.
  PRecvCtx = ^TRecvCtx;
  TRecvCtx = record
    Conn: TNativeConn;
    Buf:  array[0..CRecvBufSize - 1] of Byte;
  end;

  // Zero-copy send context: holds buffer ref until kernel notification CQE.
  // Two CQEs per SEND_ZC: result (app can proceed) + notification (buffer safe to free).
  PSendZCRef = ^TSendZCRef;
  TSendZCRef = record
    Conn: TNativeConn;
    SendBuf: TBytes;
    TotalLen: Integer;
    SentBytes: Integer;
  end;

threadvar
  // Set by each ring's accept thread (_AcceptLoop) before OnNewConn; read by
  // TIOUringBackend.RegisterConn to pin the new connection to that ring.
  // Mirrors TEpollBackend's GCurrentEpollFd.
  GCurrentRingIdx: Integer;

  // Non-nil while THIS thread is inside its own ring's _CompletionLoop drain.
  // _NotifyKernel then DEFERS the io_uring_enter: the queued SQEs ride the next
  // io_uring_enter(GETEVENTS) at the top of the loop, so one syscall both submits
  // the batch and waits for completions — instead of one enter per PostSend/
  // PostRecv. Submissions from other threads (async worker pool) see nil here and
  // submit immediately, as before.
  GDrainRing: TUringRing;

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

// cpuset-aware CPU count (respects Docker --cpuset-cpus / taskset, unlike
// TThread.ProcessorCount which returns the host's online CPUs).
function _sched_getaffinity(pid: Integer; cpusetsize: NativeUInt;
  mask: Pointer): Integer; cdecl; external 'libc.so.6' name 'sched_getaffinity';

// Number of CPUs this process may actually run on. One io_uring ring is created
// per such CPU ("one completion thread per core"): more rings than cores leaves
// each completion thread with too few connections to batch, so under async
// dispatch the completion↔worker-pool hand-off cannot amortize and low-
// concurrency latency collapses. Returns 0 on failure (caller falls back).
function _AffinityCPUCount: Integer;
var
  LMask: array[0..127] of Byte;  // 1024 CPUs worth of bitmask
  LRet, I: Integer;
  LB: Byte;
begin
  Result := 0;
  FillChar(LMask, SizeOf(LMask), 0);
  LRet := _sched_getaffinity(0, SizeOf(LMask), @LMask);
  if LRet < 0 then Exit;
  for I := 0 to High(LMask) do
  begin
    LB := LMask[I];
    while LB <> 0 do
    begin
      Inc(Result, LB and 1);
      LB := LB shr 1;
    end;
  end;
end;

// ===========================================================================
// TUringRing
// ===========================================================================

constructor TUringRing.Create(ABackend: TIOUringBackend; AIdx: Integer);
begin
  inherited Create;
  FBackend := ABackend;
  FIdx := AIdx;
  FRingFd := -1;
  FListenSocket := -1;
  FPendingSQEs := 0;
  FSQLock := TCriticalSection.Create;
  FRecvPoolLock := TCriticalSection.Create;
  FRegLock := TCriticalSection.Create;
  FRegFiles := False;
  FRegCount := 0;
  SetLength(FRegFreeStack, CRegFilesMax);
  FRegFreeTop := 0;
end;

destructor TUringRing.Destroy;
begin
  if FListenSocket >= 0 then
  begin
    _LinuxClose(FListenSocket);
    FListenSocket := -1;
  end;
  // Threads must already be joined by the backend (StopAccept + JoinWorkers).
  // Guarded WaitFor is a defensive net; in the normal flow both are nil here.
  if FAcceptThread <> nil then
  begin
    FAcceptThread.WaitFor;
    FreeAndNil(FAcceptThread);
  end;
  if FCompThread <> nil then
  begin
    FCompThread.WaitFor;
    FreeAndNil(FCompThread);
  end;
  TeardownMaps;
  if FRecvCtxPool <> nil then
  begin
    FreeMem(FRecvCtxPool);
    FRecvCtxPool := nil;
  end;
  FreeAndNil(FRecvPoolLock);
  FreeAndNil(FRegLock);
  FreeAndNil(FSQLock);
  inherited Destroy;
end;

procedure TUringRing.SetupRing;
var
  LParams: TIOUringParams;
  LSQSize: NativeUInt;
  LCQSize: NativeUInt;
  I: Integer;
  LInitFds: array of Int32;
begin
  // Normal mode (no SQPOLL — see unit header). COOP_TASKRUN (kernel 5.19+) tells
  // the kernel it needs no inter-processor interrupt to notify completions — the
  // completion thread reaps them on its next io_uring_enter anyway — cutting
  // per-completion overhead (~+7% throughput at high concurrency, measured).
  // Fall back progressively: COOP -> plain CQSIZE -> bare, so older kernels and
  // seccomp policies still work.
  FillChar(LParams, SizeOf(LParams), 0);
  LParams.flags := IORING_SETUP_CQSIZE or IORING_SETUP_COOP_TASKRUN;
  LParams.cq_entries := CCQEntries;
  FRingFd := _io_uring_setup(CRingEntries, @LParams);
  if FRingFd < 0 then
  begin
    FillChar(LParams, SizeOf(LParams), 0);
    LParams.flags := IORING_SETUP_CQSIZE;
    LParams.cq_entries := CCQEntries;
    FRingFd := _io_uring_setup(CRingEntries, @LParams);
  end;
  if FRingFd < 0 then
  begin
    FillChar(LParams, SizeOf(LParams), 0);
    FRingFd := _io_uring_setup(CRingEntries, @LParams);
  end;
  if FRingFd < 0 then
    raise Exception.CreateFmt('io_uring_setup failed (errno %d)', [GetLastError]);

  LSQSize := NativeUInt(LParams.sq_off.array_) +
             NativeUInt(LParams.sq_entries) * SizeOf(UInt32);
  FSQRing := _LinuxMmap(nil, LSQSize, PROT_READ or PROT_WRITE,
    MAP_SHARED, FRingFd, IORING_OFF_SQ_RING);
  if FSQRing = MAP_FAILED then
    raise Exception.Create('mmap(SQ ring) failed');
  FSQRingSize := LSQSize;

  if (LParams.features and IORING_FEAT_SINGLE_MMAP) <> 0 then
  begin
    FCQRing := FSQRing;
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

  FSQEsSize := NativeUInt(LParams.sq_entries) * SizeOf(TIOUringSQE);
  FSQEs := _LinuxMmap(nil, FSQEsSize, PROT_READ or PROT_WRITE,
    MAP_SHARED, FRingFd, IORING_OFF_SQES);
  if FSQEs = MAP_FAILED then
    raise Exception.Create('mmap(SQEs) failed');

  FPSQHead := PUInt32(PByte(FSQRing) + LParams.sq_off.head);
  FPSQTail := PUInt32(PByte(FSQRing) + LParams.sq_off.tail);
  FPSQMask := PUInt32(PByte(FSQRing) + LParams.sq_off.ring_mask);

  FPCQHead := PUInt32(PByte(FCQRing) + LParams.cq_off.head);
  FPCQTail := PUInt32(PByte(FCQRing) + LParams.cq_off.tail);
  FPCQMask := PUInt32(PByte(FCQRing) + LParams.cq_off.ring_mask);
  FPCQEs := Pointer(PByte(FCQRing) + LParams.cq_off.cqes);

  if (LParams.features and IORING_FEAT_NODROP) = 0 then
    Writeln(ErrOutput, '[io_uring] WARNING: kernel lacks IORING_FEAT_NODROP — ',
      'CQE overflow may silently drop completions. CQ size = ', LParams.cq_entries);

  for I := 0 to Integer(LParams.sq_entries) - 1 do
    PUInt32(PByte(FSQRing) + LParams.sq_off.array_ + NativeUInt(I) * SizeOf(UInt32))^
      := UInt32(I);

  // Recv-context pool (per ring).
  FRecvCtxPool := AllocMem(CRecvPoolSize * SizeOf(TRecvCtx));
  FRecvPoolBase := PByte(FRecvCtxPool);
  SetLength(FRecvFreeIdx, CRecvPoolSize);
  FRecvFreeTop := CRecvPoolSize;
  for I := 0 to CRecvPoolSize - 1 do
    FRecvFreeIdx[I] := UInt16(I);

  // Registered files (per ring) — eliminates fget/fput atomics per I/O op.
  SetLength(LInitFds, CRegFilesMax);
  for I := 0 to CRegFilesMax - 1 do
    LInitFds[I] := -1; // sparse table — all slots empty
  if _io_uring_register(FRingFd, IORING_REGISTER_FILES,
    @LInitFds[0], CRegFilesMax) >= 0 then
  begin
    FRegFiles := True;
    SetLength(FRegFds, 65536);
    for I := 0 to High(FRegFds) do
      FRegFds[I] := -1;
    FRegCount := 0;
  end;
end;

procedure TUringRing.StartThreads;
begin
  // Completion thread first — it must be draining before any accept can produce
  // a connection whose recv submits to this ring.
  FCompThread := TThread.CreateAnonymousThread(
    procedure
    begin
      try
        _CompletionLoop;
      finally
        TBufferPool.FlushThreadCache;
      end;
    end);
  FCompThread.FreeOnTerminate := False;
  FCompThread.Start;

  // Accept via io_uring multishot (kernel 5.19+) so THIS ring's completion
  // thread also does the accepting — no dedicated accept thread. That keeps the
  // total IO thread count at N (one per ring), matching TEpollBackend, instead
  // of 2N (a separate accept thread per ring oversubscribes the cores and, under
  // sustained load, starves/wedges connections). Fall back to a per-ring accept
  // thread only if the kernel rejects the multishot accept SQE.
  FSQLock.Acquire;
  try
    FMultishotAccept := _SubmitAcceptMultishot;
    if FMultishotAccept then
      _NotifyKernel;
  finally
    FSQLock.Release;
  end;

  if not FMultishotAccept then
  begin
    FAcceptThread := TThread.CreateAnonymousThread(
      procedure
      begin
        try
          _AcceptLoop;
        finally
          TBufferPool.FlushThreadCache;
        end;
      end);
    FAcceptThread.FreeOnTerminate := False;
    FAcceptThread.Start;
  end;
end;

// Submit ONE multishot IORING_OP_ACCEPT on this ring's listen socket. The kernel
// keeps generating accept CQEs (each with IORING_CQE_F_MORE) until cancelled;
// _ProcessCQE re-arms if F_MORE ever clears. MUST be called under FSQLock.
function TUringRing._SubmitAcceptMultishot: Boolean;
var
  LTail, LIdx: UInt32;
  LSQE: PIOUringSQE;
begin
  LTail := FPSQTail^;
  if LTail - FPSQHead^ >= FPSQMask^ + 1 then
  begin
    Result := False;
    Exit;
  end;

  LIdx := LTail and FPSQMask^;
  LSQE := PIOUringSQE(PByte(FSQEs) + NativeUInt(LIdx) * SizeOf(TIOUringSQE));
  FillChar(LSQE^, SizeOf(TIOUringSQE), 0);
  LSQE^.opcode := IORING_OP_ACCEPT;
  LSQE^.fd := FListenSocket;
  LSQE^.ioprio := IOSQE_ACCEPT_MULTISHOT;
  LSQE^.op_flags := UInt32(SOCK_NONBLOCK or SOCK_CLOEXEC);
  LSQE^.user_data := CUdTagAccept;

  FPSQTail^ := LTail + 1;
  Inc(FPendingSQEs);
  Result := True;
end;

procedure TUringRing.TeardownMaps;
begin
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

procedure TUringRing.SignalShutdown;
begin
  FSQLock.Acquire;
  try
    _SubmitSQE(IORING_OP_NOP, -1, nil, 0, CUdShutdown);
    // Submit ALL queued SQEs (the batched completion loop may have deferred some)
    // so the shutdown NOP is guaranteed to reach the kernel and wake the thread.
    _io_uring_enter(FRingFd, UInt32(FPendingSQEs), 0, 0);
    FPendingSQEs := 0;
  finally
    FSQLock.Release;
  end;
end;

// ---------------------------------------------------------------------------
// Registered files — eliminates fget/fput atomic refcount per I/O op
// ---------------------------------------------------------------------------

function TUringRing._RegFileIndex(AFd: Integer): Integer;
begin
  Result := -1;
  if not FRegFiles then Exit;
  FRegLock.Acquire;
  try
    if (AFd >= 0) and (AFd < Length(FRegFds)) and (FRegFds[AFd] >= 0) then
      Result := FRegFds[AFd];
  finally
    FRegLock.Release;
  end;
end;

function TUringRing._RegisterFd(AFd: Integer): Integer;
var
  LUpdate: TIOUringFilesUpdate;
  LSlot: Integer;
  LFdVal: Int32;
begin
  Result := -1;
  if not FRegFiles then Exit;
  FRegLock.Acquire;
  try
    if AFd >= Length(FRegFds) then
      SetLength(FRegFds, AFd + 256); // grow mapping table

    // Recycle freed slots instead of monotonic FRegCount
    LSlot := -1;
    if FRegFreeTop > 0 then
    begin
      Dec(FRegFreeTop);
      LSlot := FRegFreeStack[FRegFreeTop];
    end
    else if FRegCount < CRegFilesMax then
    begin
      LSlot := FRegCount;
      Inc(FRegCount);
    end;
    if LSlot < 0 then Exit; // table full

    LFdVal := AFd;
    FillChar(LUpdate, SizeOf(LUpdate), 0);
    LUpdate.offset := UInt32(LSlot);
    LUpdate.fds := UInt64(@LFdVal);

    if _io_uring_register(FRingFd, IORING_REGISTER_FILES_UPDATE,
      @LUpdate, 1) >= 0 then
    begin
      FRegFds[AFd] := LSlot;
      Result := LSlot;
    end
    else
    begin
      // return slot to free stack
      FRegFreeStack[FRegFreeTop] := LSlot;
      Inc(FRegFreeTop);
    end;
  finally
    FRegLock.Release;
  end;
end;

procedure TUringRing._UnregisterFd(AFd: Integer);
var
  LSlot: Integer;
  LUpdate: TIOUringFilesUpdate;
  LFdVal: Int32;
begin
  if not FRegFiles then Exit;
  FRegLock.Acquire;
  try
    if (AFd < 0) or (AFd >= Length(FRegFds)) then Exit;
    LSlot := FRegFds[AFd];
    if LSlot < 0 then Exit;
    LFdVal := -1;
    FillChar(LUpdate, SizeOf(LUpdate), 0);
    LUpdate.offset := UInt32(LSlot);
    LUpdate.fds := UInt64(@LFdVal);
    _io_uring_register(FRingFd, IORING_REGISTER_FILES_UPDATE, @LUpdate, 1);
    FRegFds[AFd] := -1;
    FRegFreeStack[FRegFreeTop] := LSlot;
    Inc(FRegFreeTop);
  finally
    FRegLock.Release;
  end;
end;

// ---------------------------------------------------------------------------
// Pre-allocated recv context pool (per ring)
// ---------------------------------------------------------------------------

function TUringRing._RecvPoolAcquire: Pointer;
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
  New(Result);
end;

procedure TUringRing._RecvPoolRelease(ACtx: Pointer);
var
  LOffset: NativeUInt;
  LIdx: Integer;
begin
  LOffset := NativeUInt(PByte(ACtx)) - NativeUInt(FRecvPoolBase);
  if LOffset < NativeUInt(CRecvPoolSize) * SizeOf(TRecvCtx) then
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
    Dispose(ACtx);
end;

// ---------------------------------------------------------------------------
// Notify kernel about new SQEs (normal mode — no SQPOLL).
// ---------------------------------------------------------------------------

procedure TUringRing._NotifyKernel;
var
  LPending: Integer;
begin
  // Batched path: called on this ring's completion thread mid-drain — leave the
  // SQEs queued; the loop's next io_uring_enter(GETEVENTS) submits them in one
  // syscall together with the wait. (FPendingSQEs stays as-is.)
  if GDrainRing = Self then
    Exit;
  LPending := FPendingSQEs;
  if LPending <= 0 then
    LPending := 1;
  FPendingSQEs := 0;
  _io_uring_enter(FRingFd, LPending, 0, 0);
end;

// ---------------------------------------------------------------------------
// SQE submission — MUST be called under FSQLock
// ---------------------------------------------------------------------------

function TUringRing._SubmitSQE(AOpcode: Byte; AFd: Integer;
  ABuf: Pointer; ALen: UInt32; AUserData: UInt64; AFlags: Byte): Boolean;
var
  LTail, LIdx: UInt32;
  LSQE: PIOUringSQE;
  LRegIdx: Integer;
begin
  LTail := FPSQTail^;

  if LTail - FPSQHead^ >= FPSQMask^ + 1 then
  begin
    Result := False;
    Exit;
  end;

  LIdx := LTail and FPSQMask^;
  LSQE := PIOUringSQE(PByte(FSQEs) + NativeUInt(LIdx) * SizeOf(TIOUringSQE));
  FillChar(LSQE^, SizeOf(TIOUringSQE), 0);
  LSQE^.opcode := AOpcode;
  LSQE^.addr := UInt64(ABuf);
  LSQE^.len := ALen;
  LSQE^.user_data := AUserData;

  // Use registered file index when available (eliminates fget/fput atomics)
  LRegIdx := _RegFileIndex(AFd);
  if LRegIdx >= 0 then
  begin
    LSQE^.fd := LRegIdx;
    LSQE^.flags := IOSQE_FIXED_FILE;
  end
  else
    LSQE^.fd := AFd;
  LSQE^.flags := LSQE^.flags or AFlags;  // #199: e.g. IOSQE_ASYNC on -EAGAIN retry

  // x86-64 TSO: plain store sufficient; io_uring_enter acts as full barrier
  FPSQTail^ := LTail + 1;
  Inc(FPendingSQEs);

  Result := True;
end;

// ---------------------------------------------------------------------------
// Completion thread — one per ring; serial CQE drain after each wakeup
// ---------------------------------------------------------------------------

procedure TUringRing._CompletionLoop;
var
  LHead, LTail, LMask: UInt32;
  LCQE: PIOUringCQE;
  LToSubmit: Integer;
begin
  // Stamp this thread's ring index so RegisterConn (invoked from OnNewConn while
  // this thread processes a multishot-accept CQE) pins the connection here.
  GCurrentRingIdx := FIdx;
  // Mark this thread as its ring's drain thread so _NotifyKernel defers submits
  // into the batched io_uring_enter below — only under inline dispatch (see
  // SetInlineDispatch). Under the async pool GDrainRing stays nil (no batching).
  if FBackend.FBatchSubmit then
    GDrainRing := Self;
  try
    while TInterlocked.Read(FBackend.FShutdown) = 0 do
    begin
      // One syscall: submit SQEs queued by the previous drain AND wait for the
      // next batch of completions. Read+clear FPendingSQEs under the lock (fast),
      // then enter WITHOUT the lock so the blocking wait never holds it.
      FSQLock.Acquire;
      LToSubmit := FPendingSQEs;
      FPendingSQEs := 0;
      FSQLock.Release;
      _io_uring_enter(FRingFd, UInt32(LToSubmit), 1, IORING_ENTER_GETEVENTS);

      // Re-arm multishot accept if a previous drain's re-arm (in _ProcessCQE)
      // found the SQ full and gave up (#224 — silent, permanent loss of
      // accept on this ring). The syscall above just let the kernel consume
      // submitted SQEs, so FPSQHead^ has advanced and there is now the best
      // chance of room; retried every iteration until it succeeds.
      if (not FMultishotAccept) and (TInterlocked.Read(FBackend.FShutdown) = 0)
         and (FListenSocket >= 0) then
      begin
        FSQLock.Acquire;
        try
          if _SubmitAcceptMultishot then
          begin
            FMultishotAccept := True;
            _NotifyKernel;
          end;
        finally
          FSQLock.Release;
        end;
      end;

      LMask := FPCQMask^;
      LHead := FPCQHead^;
      LTail := FPCQTail^;

      // Batch CQ head update — process all CQEs, then advance head once.
      while LHead <> LTail do
      begin
        LCQE := PIOUringCQE(PByte(FPCQEs) +
          NativeUInt(LHead and LMask) * SizeOf(TIOUringCQE));
        try
          FBackend._ProcessCQE(Self, LCQE^.user_data, LCQE^.res, LCQE^.flags);
        except
          on E: Exception do
            Writeln(ErrOutput, '[io_uring] CQE_EX [', E.ClassName, ']: ', E.Message);
        end;
        Inc(LHead);
      end;
      FPCQHead^ := LHead;
    end;
  finally
    GDrainRing := nil;
  end;
end;

// ---------------------------------------------------------------------------
// Accept thread — plain accept4() loop on this ring's listen socket.
// Stamps GCurrentRingIdx so RegisterConn pins the connection to this ring.
// ---------------------------------------------------------------------------

procedure TUringRing._AcceptLoop;
var
  LFd: Integer;
  LAddr: sockaddr_in;
  LAddrLen: Cardinal;
  LIP: AnsiString;
  LOne: Integer;
begin
  GCurrentRingIdx := FIdx;
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
      FBackend.FCallbacks.OnNewConn(NativeUInt(LFd),
        string(LIP) + ':' + IntToStr(ntohs(LAddr.sin_port)));
    except
      _LinuxClose(LFd);
    end;
  end;
end;

// ===========================================================================
// TIOUringBackend — constructor / destructor
// ===========================================================================

constructor TIOUringBackend.Create;
var
  LParams: TIOUringParams;
  LFd: Integer;
  LProbe: TIOUringProbe;
begin
  inherited Create;

  // Phase 1: check io_uring_setup is available (kernel >= 5.1).
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

  // Detect SEND_ZC support (kernel 6.0+)
  FSendZC := (LProbe.last_op >= IORING_OP_SEND_ZC) and
    ((LProbe.ops[IORING_OP_SEND_ZC].flags and IO_URING_OP_SUPPORTED) <> 0);

  FShutdown := 0;
end;

destructor TIOUringBackend.Destroy;
var
  I: Integer;
  LAnyComp: Boolean;
begin
  // Safety net for the "Stop was never fully driven" path. Idempotent — after a
  // normal Stop (StopAccept + SignalWorkers + JoinWorkers) the guards below are
  // all no-ops.
  StopAccept;

  LAnyComp := False;
  for I := 0 to High(FRings) do
    if (FRings[I] <> nil) and (FRings[I].FCompThread <> nil) then
      LAnyComp := True;
  if LAnyComp then
    SignalWorkers;
  JoinWorkers;

  for I := 0 to High(FRings) do
    FRings[I].Free;
  SetLength(FRings, 0);
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function TIOUringBackend._RingOf(AConn: TNativeConn): TUringRing;
begin
  Result := FRings[AConn.OwnerRingIdx];
end;

function TIOUringBackend._CreateListenSocket: Integer;
var
  LAddr: sockaddr_in;
  LOne: Integer;
begin
  Result := _LinuxSocket(AF_INET, SOCK_STREAM or SOCK_CLOEXEC, 0);
  if Result < 0 then
    raise Exception.Create('socket() failed: ' + IntToStr(GetLastError));

  LOne := 1;
  _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEADDR, @LOne, SizeOf(LOne));
  _LinuxSetsockopt(Result, SOL_SOCKET, SO_REUSEPORT, @LOne, SizeOf(LOne));
  if FFastOpen then
    _LinuxSetsockopt(Result, IPPROTO_TCP, CTCP_FASTOPEN, @LOne, SizeOf(LOne));
  // TCP_DEFER_ACCEPT — kernel waits for data before waking accept
  _LinuxSetsockopt(Result, IPPROTO_TCP, CTCP_DEFER_ACCEPT, @LOne, SizeOf(LOne));

  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family := AF_INET;
  LAddr.sin_port := htons(FPort);
  if (FHost = '0.0.0.0') or (FHost = '') then
    LAddr.sin_addr.s_addr := INADDR_ANY
  else
    LAddr.sin_addr.s_addr := inet_addr(MarshaledAString(AnsiString(FHost)));

  if _LinuxBind(Result, @LAddr, SizeOf(LAddr)) < 0 then
    raise Exception.Create('bind() failed: ' + IntToStr(GetLastError));
  if _LinuxListen(Result, SOMAXCONN) < 0 then
    raise Exception.Create('listen() failed: ' + IntToStr(GetLastError));
end;

// ---------------------------------------------------------------------------
// IIOBackend — lifecycle
// ---------------------------------------------------------------------------

procedure TIOUringBackend.SetInlineDispatch(AEnabled: Boolean);
begin
  // Submission batching is only correct when the thread that submits SQEs (via
  // PostSend/PostRecv during dispatch) IS the completion thread — i.e. inline
  // SyncDispatch. Under the async worker pool, sends are submitted from pool
  // threads and only the completion thread's own re-arms/resubmits would be
  // batched; that path interacts badly with large fragmented WebSocket sends
  // (Autobahn 9.5/9.6), so keep batching off unless dispatch is inline.
  FBatchSubmit := AEnabled;
end;

procedure TIOUringBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);
var
  I: Integer;
begin
  FCallbacks := ACallbacks;
  FShutdown := 0;
  FHost := AHost;
  FPort := APort;
  FFastOpen := AFastOpen;

  // One ring (completion thread) per USABLE core. Prefer the cpuset-aware count
  // (sched_getaffinity) over AWorkerCount, which is derived from
  // TThread.ProcessorCount = the host's online CPUs and ignores a Docker
  // --cpuset / taskset restriction. Creating ProcessorCount*2 rings on 4 cores
  // (the old behaviour) leaves ~1 connection per ring at low concurrency, and
  // the async completion↔pool hand-off then pays an un-amortized wake-up per
  // request. Cap at AWorkerCount so we never exceed the IO-worker budget.
  FRingCount := _AffinityCPUCount;
  if (FRingCount < 1) or (FRingCount > AWorkerCount) then
    FRingCount := AWorkerCount;
  if FRingCount < 1 then FRingCount := 1;

  SetLength(FRings, FRingCount);
  for I := 0 to FRingCount - 1 do
    FRings[I] := TUringRing.Create(Self, I);

  // Listen sockets first (SO_REUSEPORT), then set up each ring, then start
  // threads — completion thread must be draining before its accept thread runs.
  for I := 0 to FRingCount - 1 do
    FRings[I].FListenSocket := _CreateListenSocket;
  for I := 0 to FRingCount - 1 do
    FRings[I].SetupRing;
  for I := 0 to FRingCount - 1 do
    FRings[I].StartThreads;
end;

procedure TIOUringBackend.StopAccept;
var
  I: Integer;
begin
  for I := 0 to High(FRings) do
    if (FRings[I] <> nil) and (FRings[I].FListenSocket >= 0) then
    begin
      // shutdown() BEFORE close(): on Linux a bare close() does NOT wake a
      // thread blocked in accept4() on this fd, so the WaitFor below would hang.
      // shutdown(SHUT_RDWR) forces the blocked accept4() to return EINVAL,
      // breaking the accept loop cleanly.
      shutdown(FRings[I].FListenSocket, SHUT_RDWR);
      _LinuxClose(FRings[I].FListenSocket);
      FRings[I].FListenSocket := -1;
    end;
  for I := 0 to High(FRings) do
    if (FRings[I] <> nil) and (FRings[I].FAcceptThread <> nil) then
    begin
      FRings[I].FAcceptThread.WaitFor;
      FreeAndNil(FRings[I].FAcceptThread);
    end;
end;

procedure TIOUringBackend.ShutdownConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LSock: Integer;
begin
  // #173: skip if SocketClose already invalidated the fd (kernel reuse).
  LSock := LConn.Socket;
  if LSock <> -1 then
    shutdown(LSock, SHUT_RDWR);
end;

procedure TIOUringBackend.SignalWorkers;
var
  I: Integer;
begin
  TInterlocked.Exchange(FShutdown, 1);
  for I := 0 to High(FRings) do
    if (FRings[I] <> nil) and (FRings[I].FRingFd >= 0) then
      FRings[I].SignalShutdown;
end;

procedure TIOUringBackend.JoinWorkers;
var
  I: Integer;
begin
  for I := 0 to High(FRings) do
  begin
    if FRings[I] = nil then Continue;
    if FRings[I].FCompThread <> nil then
    begin
      FRings[I].FCompThread.WaitFor;
      FreeAndNil(FRings[I].FCompThread);
    end;
    FRings[I].TeardownMaps;
  end;
end;

// ---------------------------------------------------------------------------
// IIOBackend — per-connection
// ---------------------------------------------------------------------------

procedure TIOUringBackend.RegisterConn(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  // Pin the connection to the ring whose accept thread produced it.
  LConn.OwnerRingIdx := GCurrentRingIdx;
  FRings[LConn.OwnerRingIdx]._RegisterFd(LConn.Socket);
end;

procedure TIOUringBackend.PostRecv(AConn: Pointer);
var
  LCtx: PRecvCtx;
  LConn: TNativeConn absolute AConn;
  LRing: TUringRing;
begin
  LRing := _RingOf(LConn);
  LCtx := LRing._RecvPoolAcquire;
  LCtx^.Conn := LConn;
  LConn.AddRef;
  LRing.FSQLock.Acquire;
  try
    if not LRing._SubmitSQE(IORING_OP_RECV, LConn.Socket,
      @LCtx^.Buf[0], CRecvBufSize, UInt64(LCtx)) then
    begin
      // Ring full — cancel the ref we just took and signal an error so the
      // server closes the connection instead of leaving it orphaned forever.
      LConn.Release;
      LRing._RecvPoolRelease(LCtx);
      FCallbacks.OnConnError(AConn);
      Exit;
    end;
    LRing._NotifyKernel;
  finally
    LRing.FSQLock.Release;
  end;
end;

procedure TIOUringBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
var
  LConn: TNativeConn absolute AConn;
  LRing: TUringRing;
  LSendLen: Integer;
  LZCRef: PSendZCRef;
  LTmp: TBytes;
begin
  LSendLen := AActualLen;
  if LSendLen = 0 then LSendLen := Length(AData);

  if LSendLen = 0 then
  begin
    FCallbacks.OnSendComplete(AConn);
    Exit;
  end;

  // #11: serialize — io_uring won't order independent SEND SQEs, so at most ONE
  // send may be in flight per connection. If one already is, queue and return.
  if not _BeginSend(LConn, AData, LSendLen) then
  begin
    LTmp := AData;                 // copied into the backlog by _BeginSend
    TBufferPool.Release(LTmp);
    Exit;
  end;

  if FSendZC and (LSendLen >= CSendZCThreshold) then
  begin
    // Zero-copy send: kernel DMAs directly from user buffer.
    // Two CQEs per op: result (proceed) + notification (buffer safe to free).
    LRing := _RingOf(LConn);
    New(LZCRef);
    LZCRef^.Conn := LConn;
    LZCRef^.SendBuf := AData;
    LZCRef^.TotalLen := LSendLen;
    LZCRef^.SentBytes := 0;

    LConn.AddRef;  // result CQE
    LConn.AddRef;  // notification CQE
    LRing.FSQLock.Acquire;
    try
      if not LRing._SubmitSQE(IORING_OP_SEND_ZC, LConn.Socket,
        @AData[0], UInt32(LSendLen),
        UInt64(LZCRef) or CUdTagSendZC) then
      begin
        LConn.Release;
        LConn.Release;
        TBufferPool.Release(LZCRef^.SendBuf);
        Dispose(LZCRef);
        FCallbacks.OnConnError(AConn);
        Exit;
      end;
      LRing._NotifyKernel;
    finally
      LRing.FSQLock.Release;
    end;
  end
  else
  begin
    LConn.PendingSend := AData;
    LConn.PendingSendActual := AActualLen;
    LConn.SentBytes := 0;
    _ResubmitSend(LConn);
  end;
end;

// io_uring SEND doesn't support scatter-gather on sockets,
// so concatenate into a pool buffer and delegate to PostSend.
procedure TIOUringBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
var
  LHLen: Integer;
  LBLen: Integer;
  LConcat: TBytes;
  LTmpH: TBytes;
  LTmpB: TBytes;
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

  // Fast path: the headers buffer is a pooled tier buffer (typically 8 KB) with
  // only ~100 bytes used, so a small body fits after it. Append it in place and
  // send the SAME buffer — no extra Acquire, no copy of the header bytes. This is
  // the common plaintext/json case. (io_uring SEND takes one contiguous buffer,
  // so we can't scatter-gather like epoll's writev.)
  if (LHLen + LBLen <= Length(AHeaders)) then
  begin
    if LBLen > 0 then Move(ABody[0], AHeaders[LHLen], LBLen);
    LTmpB := ABody; TBufferPool.Release(LTmpB);  // body copied out; headers buffer is handed to PostSend
    PostSend(AConn, AHeaders, LHLen + LBLen);
    Exit;
  end;

  // Slow path: body too big to append (e.g. json-large) — concatenate into a
  // fresh buffer sized for the total.
  LConcat := TBufferPool.Acquire(LHLen + LBLen);
  if LHLen > 0 then Move(AHeaders[0], LConcat[0], LHLen);
  if LBLen > 0 then Move(ABody[0], LConcat[LHLen], LBLen);

  LTmpH := AHeaders; TBufferPool.Release(LTmpH);
  LTmpB := ABody;    TBufferPool.Release(LTmpB);

  PostSend(AConn, LConcat, LHLen + LBLen);
end;

procedure TIOUringBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
  LRing: TUringRing;
  LSock: Integer;
begin
  // #173: invalidate the conn's fd copy before closing (kernel reuses fds).
  LSock := LConn.Socket;
  LConn.Socket := -1;
  LRing := FRings[LConn.OwnerRingIdx];

  // Batching + close ordering: if we are on this ring's completion thread with
  // SQEs still queued (e.g. an h2 error path just deferred a GOAWAY send and now
  // closes the connection in the same drain), flush them to the kernel BEFORE
  // closing the fd. Otherwise the deferred send would target an already-closed
  // socket and the final frame (GOAWAY / RST_STREAM) would be lost — h2spec
  // 6.9.1 "WINDOW_UPDATE above 2^31-1". The kernel copies the small control
  // frame into the socket send buffer at submit time, so the subsequent
  // shutdown(SHUT_WR) still flushes it out ahead of the FIN.
  if GDrainRing = LRing then
  begin
    LRing.FSQLock.Acquire;
    try
      if LRing.FPendingSQEs > 0 then
      begin
        _io_uring_enter(LRing.FRingFd, UInt32(LRing.FPendingSQEs), 0, 0);
        LRing.FPendingSQEs := 0;
      end;
    finally
      LRing.FSQLock.Release;
    end;
  end;

  LRing._UnregisterFd(LSock);
  // TCP half-close — FIN before full teardown so the client reads pending bytes
  shutdown(LSock, SHUT_WR);
  _LinuxClose(LSock);
end;

// ---------------------------------------------------------------------------
// Internal: send helpers
// ---------------------------------------------------------------------------

// #11 — serialization gate. Under LConn.Lock: if a send is already in flight,
// copy AData onto the connection's ordered backlog and return False (queued);
// otherwise mark in-flight and return True (caller submits now).
function TIOUringBackend._BeginSend(AConn: TNativeConn; const AData: TBytes;
  ALen: Integer): Boolean;
begin
  AConn.Lock.Enter;
  try
    if AConn.SendInFlight then
    begin
      if AConn.SendBacklogLen + ALen > Length(AConn.SendBacklog) then
        SetLength(AConn.SendBacklog, AConn.SendBacklogLen + ALen + 8192);
      if ALen > 0 then
        Move(AData[0], AConn.SendBacklog[AConn.SendBacklogLen], ALen);
      Inc(AConn.SendBacklogLen, ALen);
      Result := False;
    end
    else
    begin
      AConn.SendInFlight := True;
      Result := True;
    end;
  finally
    AConn.Lock.Leave;
  end;
end;

// #11 — called when a send op fully completes. If the backlog holds queued
// bytes, move them into PendingSend and submit ONE regular SEND (keeping the
// conn in-flight, order preserved) -> True. Otherwise clear in-flight -> False.
function TIOUringBackend._KickNextSend(AConn: TNativeConn): Boolean;
var
  LLen: Integer;
  LBuf: TBytes;
begin
  AConn.Lock.Enter;
  try
    if AConn.SendBacklogLen > 0 then
    begin
      LLen := AConn.SendBacklogLen;
      LBuf := TBufferPool.Acquire(LLen);
      Move(AConn.SendBacklog[0], LBuf[0], LLen);
      AConn.SendBacklogLen := 0;
      AConn.PendingSend := LBuf;
      AConn.PendingSendActual := LLen;
      AConn.SentBytes := 0;
      Result := True;
    end
    else
    begin
      AConn.SendInFlight := False;
      Result := False;
    end;
  finally
    AConn.Lock.Leave;
  end;
  if Result then
    _ResubmitSend(AConn);  // acquires ring FSQLock; ordering LConn.Lock -> FSQLock ok
end;

procedure TIOUringBackend._ResubmitSend(AConn: TNativeConn; AAsync: Boolean);
var
  LRing: TUringRing;
  LTotal, LRemain: Integer;
  LFlags: Byte;
begin
  LRing := _RingOf(AConn);
  LTotal  := AConn.PendingSendActual;
  if LTotal = 0 then LTotal := Length(AConn.PendingSend);
  LRemain := LTotal - AConn.SentBytes;

  LFlags := 0;
  if AAsync then LFlags := IOSQE_ASYNC;

  AConn.AddRef;
  LRing.FSQLock.Acquire;
  try
    if not LRing._SubmitSQE(IORING_OP_SEND, AConn.Socket,
      @AConn.PendingSend[AConn.SentBytes], UInt32(LRemain),
      UInt64(AConn) or CUdTagSend, LFlags) then
    begin
      AConn.Release;  // op not posted — drop the ref we just took
      FCallbacks.OnConnError(AConn);
      Exit;
    end;
    LRing._NotifyKernel;
  finally
    LRing.FSQLock.Release;
  end;
end;

// ---------------------------------------------------------------------------
// CQE dispatch — runs on ARing's completion thread. The connection carried by
// the CQE is pinned to ARing, so any resubmit routes back to ARing.
// ---------------------------------------------------------------------------

procedure TIOUringBackend._ProcessCQE(ARing: TUringRing; AUserData: UInt64;
  ARes: Int32; AFlags: UInt32);
var
  LCtx: PRecvCtx;
  LConn: TNativeConn;
  LRecvConn: TNativeConn;
  LTotal: Integer;
  LZCRef: PSendZCRef;
  LHasNotif: Boolean;
  LRemainLen: Integer;
  LRemainBuf: TBytes;
  LOne: Integer;
  LAddr: sockaddr_in;
  LAddrLen: Cardinal;
  LIP: AnsiString;
begin
  if AUserData = CUdShutdown then
  begin
    TInterlocked.Exchange(FShutdown, 1);
    Exit;
  end;

  // Multishot-accept CQE (CUdTagAccept = 2, an exact sentinel — no pool pointer
  // or conn value equals 2). This ring's completion thread does the accepting,
  // so GCurrentRingIdx (set at loop entry) pins the new connection to ARing.
  if AUserData = CUdTagAccept then
  begin
    if ARes >= 0 then
    begin
      ARing.FAcceptErrStreak := 0;
      LOne := 1;
      _LinuxSetsockopt(ARes, IPPROTO_TCP, TCP_NODELAY, @LOne, SizeOf(LOne));
      _LinuxSetsockopt(ARes, SOL_SOCKET, SO_KEEPALIVE, @LOne, SizeOf(LOne));
      FillChar(LAddr, SizeOf(LAddr), 0);
      LAddrLen := SizeOf(LAddr);
      getpeername(ARes, sockaddr(LAddr), LAddrLen);
      LIP := AnsiString(inet_ntoa(LAddr.sin_addr));
      try
        FCallbacks.OnNewConn(NativeUInt(ARes),
          string(LIP) + ':' + IntToStr(ntohs(LAddr.sin_port)));
      except
        _LinuxClose(ARes);
      end;
    end
    else if (TInterlocked.Read(FShutdown) = 0) and (ARing.FListenSocket >= 0) then
    begin
      // Genuine accept error (not teardown). We still re-arm below so the ring
      // recovers once the transient condition (EMFILE/ENFILE — fd exhaustion)
      // clears, but surface a sustained streak once so it is not silent.
      Inc(ARing.FAcceptErrStreak);
      if ARing.FAcceptErrStreak = CAcceptErrLogAt then
        Writeln(ErrOutput, '[io_uring] ring ', ARing.FIdx,
          ': ', CAcceptErrLogAt, ' consecutive accept errors (errno ',
          -ARes, ') — fd exhaustion?');
    end;
    // F_MORE clear ⇒ kernel ended the multishot stream — re-arm it (unless we
    // are shutting down or the listen socket was already closed by StopAccept).
    if (AFlags and IORING_CQE_F_MORE) = 0 then
    begin
      ARing.FMultishotAccept := False;
      if (TInterlocked.Read(FShutdown) = 0) and (ARing.FListenSocket >= 0) then
      begin
        ARing.FSQLock.Acquire;
        try
          if ARing._SubmitAcceptMultishot then
          begin
            ARing.FMultishotAccept := True;
            ARing._NotifyKernel;
          end;
        finally
          ARing.FSQLock.Release;
        end;
      end;
    end;
    Exit;
  end;

  // Zero-copy send (CUdTagSendZC = 3, both bits 0+1 set) — check before send.
  if (AUserData and 3) = CUdTagSendZC then
  begin
    LZCRef := PSendZCRef(Pointer(AUserData and not UInt64(3)));
    LConn := LZCRef^.Conn;

    if (AFlags and IORING_CQE_F_NOTIF) <> 0 then
    begin
      // Buffer release notification — kernel no longer needs the buffer
      if LZCRef^.SendBuf <> nil then
        TBufferPool.Release(LZCRef^.SendBuf);
      Dispose(LZCRef);
      LConn.Release;
      Exit;
    end;

    // Send result CQE. A notification CQE (F_NOTIF) only follows when the
    // result CQE carried IORING_CQE_F_MORE — i.e. the kernel took a reference to
    // the buffer. On an early failure (res<=0) F_MORE is clear and NO
    // notification comes, so this path must do the cleanup the notification
    // would have done. #194
    LHasNotif := (AFlags and IORING_CQE_F_MORE) <> 0;

    // #207: a zero-copy SEND on an already-full socket buffer returns -EAGAIN
    // with NO buffer reference taken (F_MORE clear ⇒ no F_NOTIF will follow).
    // Like the regular SEND path (#199), this is NOT fatal — retry the whole
    // buffer via a blocking regular SEND (io-wq).
    if (ARes = -CEAGAIN) and (not LHasNotif) then
    begin
      LConn.PendingSend       := LZCRef^.SendBuf;
      LConn.PendingSendActual := LZCRef^.TotalLen;
      LConn.SentBytes         := LZCRef^.SentBytes;  // 0 — ZC is only the 1st op
      LZCRef^.SendBuf := nil;                         // ownership → PendingSend
      Dispose(LZCRef);
      _ResubmitSend(LConn, True);                     // io-wq async; own AddRef
      LConn.Release;                                  // result ref
      LConn.Release;                                  // notification ref (none coming)
      Exit;
    end;

    if ARes <= 0 then
    begin
      FCallbacks.OnConnError(LConn);
      LConn.Release;                       // result ref
    end
    else
    begin
      Inc(LZCRef^.SentBytes, ARes);
      if LZCRef^.SentBytes < LZCRef^.TotalLen then
      begin
        // Partial send — send the remainder via a regular IORING_OP_SEND.
        if LHasNotif then
        begin
          // The kernel still references SendBuf[0..SentBytes) until the pending
          // F_NOTIF CQE. Copy the remainder into a FRESH buffer for the resubmit
          // so its completion cannot return the still-in-flight original to the
          // pool. The original is freed by the F_NOTIF path; do NOT nil it here.
          LRemainLen := LZCRef^.TotalLen - LZCRef^.SentBytes;
          LRemainBuf := TBufferPool.Acquire(LRemainLen);
          Move(LZCRef^.SendBuf[LZCRef^.SentBytes], LRemainBuf[0], LRemainLen);
          LConn.PendingSend       := LRemainBuf;
          LConn.PendingSendActual := LRemainLen;
          LConn.SentBytes         := 0;
        end
        else
        begin
          // No notification pending (kernel copied) — hand the original over.
          LConn.PendingSend       := LZCRef^.SendBuf;
          LConn.PendingSendActual := LZCRef^.TotalLen;
          LConn.SentBytes         := LZCRef^.SentBytes;
          LZCRef^.SendBuf := nil;
        end;
        _ResubmitSend(LConn);
        LConn.Release;                     // result ref
      end
      else
      begin
        // All bytes sent (buffer stays alive for the notification CQE). #11:
        // submit the next queued chunk in order, else notify the server.
        if not _KickNextSend(LConn) then
          FCallbacks.OnSendComplete(LConn);
        LConn.Release;                     // result ref
      end;
    end;

    // #194: no notification CQE will follow — release buffer + ctx + the second
    // (notification) ref here instead of leaking them on every failed ZC send.
    if not LHasNotif then
    begin
      if LZCRef^.SendBuf <> nil then
        TBufferPool.Release(LZCRef^.SendBuf);
      Dispose(LZCRef);
      LConn.Release;                       // notification ref
    end;
    Exit;
  end;

  if (AUserData and CUdTagSend) <> 0 then
  begin
    LConn := TNativeConn(Pointer(UInt64(AUserData and not CUdTagSend)));

    // #199: a non-blocking SEND on a full socket buffer returns -EAGAIN. That is
    // NOT fatal — re-submit the same remaining bytes via io-wq (IOSQE_ASYNC) so
    // the kernel completes the send as the peer drains.
    if ARes = -CEAGAIN then
    begin
      _ResubmitSend(LConn, True);
      LConn.Release;                       // drop this op's ref; resubmit took its own
      Exit;
    end;
    if ARes <= 0 then
    begin
      FCallbacks.OnConnError(LConn);
      LConn.Release;
      Exit;
    end;

    Inc(LConn.SentBytes, ARes);
    LTotal := LConn.PendingSendActual;
    if LTotal = 0 then LTotal := Length(LConn.PendingSend);

    if LConn.SentBytes < LTotal then
    begin
      // Partial send — re-submit for the remaining bytes.
      _ResubmitSend(LConn);
      LConn.Release;
    end
    else
    begin
      // All bytes delivered — return buffer, then either submit the next queued
      // chunk (#11: preserves TLS byte order) or notify the server. Drop our ref.
      TBufferPool.Release(LConn.PendingSend);
      LConn.PendingSend := nil;
      LConn.PendingSendActual := 0;
      if not _KickNextSend(LConn) then
        FCallbacks.OnSendComplete(LConn);
      LConn.Release;
    end;
  end
  else
  begin
    LCtx := PRecvCtx(Pointer(AUserData));
    LRecvConn := LCtx^.Conn;
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
      ARing._RecvPoolRelease(LCtx);
      LRecvConn.Release;
    end;
  end;
end;

{$ELSE}

interface
implementation  // empty stub on Windows

{$ENDIF}

end.
