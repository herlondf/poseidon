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
//   Shutdown: CUdShutdown = $FFFFFFFFFFFFFFFF
//
// v2 (#56): Recv contexts are pre-allocated in a contiguous pool (CRecvPoolSize
// entries) at Create time, eliminating New/Dispose per recv operation.  Pool
// exhaustion (should not happen — sized to CRingEntries) falls back to heap.

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
    FAcceptThreads: TArray<TThread>;    // #58: per-core accept threads
    FCompThread: TThread;
    FCallbacks: IIOCallbacks;
    FListenSockets: TArray<Integer>;    // #58: per-core listen sockets
    FSQLock: TCriticalSection;
    FShutdown: Boolean;
    FSQPoll: Boolean;                   // #60: kernel poll thread active
    FPSQFlags: PUInt32;                 // #60: sq_off.flags for NEED_WAKEUP check
    FRecvCtxPool: Pointer;              // #56: contiguous recv context pool
    FRecvFreeIdx: array of UInt16;
    FRecvFreeTop: Integer;
    FRecvPoolLock: TCriticalSection;
    FRecvPoolBase: PByte;
    FMultishotAccept: Boolean;          // #73: multishot accept active
    FPendingSQEs: Integer;               // #109: count of SQEs pending notification
    // #75: registered files
    FRegFiles: Boolean;                   // True if IORING_REGISTER_FILES succeeded
    FRegFds: array of Int32;              // fd → index mapping table
    FRegCount: Integer;                   // allocated slots (high-water mark)
    FRegFreeStack: array of Integer;      // #103: recycled slot indices
    FRegFreeTop: Integer;                 // #103: free stack top
    FRegLock: TCriticalSection;
    function _RegFileIndex(AFd: Integer): Integer;
    function _RegisterFd(AFd: Integer): Integer;
    procedure _UnregisterFd(AFd: Integer);
    // helpers
    procedure _AcceptOn(AListenFd: Integer);
    procedure _CompletionLoop;
    function  _SubmitSQE(AOpcode: Byte; AFd: Integer; ABuf: Pointer;
      ALen: UInt32; AUserData: UInt64): Boolean;
    function  _SubmitAcceptMultishot(AListenFd: Integer): Boolean;
    procedure _ProcessCQE(AUserData: UInt64; ARes: Int32; AFlags: UInt32);
    procedure _ResubmitSend(AConn: TNativeConn);
    function  _RecvPoolAcquire: Pointer;
    procedure _RecvPoolRelease(ACtx: Pointer);
    procedure _NotifyKernel;  // #60: io_uring_enter or SQPOLL wakeup
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
  IORING_SETUP_CQSIZE     = UInt32($200); // #109: custom CQ ring size
  IORING_SETUP_CLAMP      = UInt32($10);  // clamp entries to max allowed

  // SQ ring flags (read from sq_off.flags at runtime)
  IORING_SQ_NEED_WAKEUP   = UInt32(1);   // #60: SQPOLL thread is idle, need wakeup

  // io_uring feature flags (returned in params.features)
  IORING_FEAT_SINGLE_MMAP = UInt32($0001);

  // SQE opcodes
  IORING_OP_NOP    = Byte(0);
  IORING_OP_ACCEPT = Byte(13);   // #73: multishot accept
  IORING_OP_RECV   = Byte(22);
  IORING_OP_SEND   = Byte(23);

  // #73: multishot accept — one SQE generates multiple CQEs
  IOSQE_ACCEPT_MULTISHOT = UInt16(1 shl 0);  // ioprio flag for multishot accept

  // SQE flags
  IOSQE_FIXED_FILE = Byte(1 shl 0);  // #75: use registered file index instead of fd

  // CQE flags
  IORING_CQE_F_MORE = UInt32(1 shl 1);  // more CQEs to come from this SQE

  // mmap file offsets for the three ring regions
  IORING_OFF_SQ_RING = Int64(0);
  IORING_OFF_CQ_RING = Int64($8000000);
  IORING_OFF_SQES    = Int64($10000000);

  CUdTagSend   = UInt64(1);
  CUdTagAccept = UInt64(2);                     // #73: accept completion
  CUdShutdown  = UInt64($FFFFFFFFFFFFFFFF);

  CRecvBufSize  = 32768;
  CRingEntries  = 512;
  CCQEntries    = 2048;  // #109: larger CQ to prevent overflow
  CRecvPoolSize = CRingEntries;

  // io_uring_register opcodes
  IORING_REGISTER_FILES        = UInt32(2);   // #75: register fd array
  IORING_REGISTER_FILES_UPDATE = UInt32(6);   // #75: update registered fds
  IORING_REGISTER_PROBE        = UInt32(8);   // added in kernel 5.6

  // io_uring_probe_op flag — op is supported by this kernel
  IO_URING_OP_SUPPORTED = UInt16(1);

  // Linux setsockopt level/option constants not in the RTL
  SO_REUSEPORT    = 15;
type
  // #103: io_uring_files_update struct for IORING_REGISTER_FILES_UPDATE
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
    Buf:  array[0..CRecvBufSize - 1] of Byte;
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
  LFd: Integer;
  LProbe: TIOUringProbe;
  LI: Integer;
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
  FPendingSQEs  := 0;

  FRecvCtxPool := AllocMem(CRecvPoolSize * SizeOf(TRecvCtx));
  FRecvPoolBase := PByte(FRecvCtxPool);
  SetLength(FRecvFreeIdx, CRecvPoolSize);
  FRecvFreeTop := CRecvPoolSize;
  for LI := 0 to CRecvPoolSize - 1 do
    FRecvFreeIdx[LI] := UInt16(LI);

  // #75: registered files — pre-allocate slot table
  FRegLock := TCriticalSection.Create;
  FRegFiles := False;
  FRegCount := 0;
  SetLength(FRegFreeStack, CRegFilesMax);
  FRegFreeTop := 0;
end;

destructor TIOUringBackend.Destroy;
begin
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
    // #70: TCP_DEFER_ACCEPT — kernel waits for data before waking accept
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
  LParams: TIOUringParams;
  LOne, I: Integer;
  LSQSize: NativeUInt;
  LCQSize: NativeUInt;
  LAcceptN: Integer;
  LFd: Integer;
begin
  FCallbacks := ACallbacks;
  FShutdown  := False;
  LAcceptN   := AAcceptThreads;
  if LAcceptN < 1 then LAcceptN := 1;

  SetLength(FListenSockets, LAcceptN);
  for I := 0 to LAcceptN - 1 do
    FListenSockets[I] := CreateListenSocket;

  // #60: try SQPOLL first (kernel 5.11+ or CAP_SYS_NICE); fall back silently
  // #109: use IORING_SETUP_CQSIZE for larger CQ to prevent overflow
  FillChar(LParams, SizeOf(LParams), 0);
  LParams.flags          := IORING_SETUP_SQPOLL or IORING_SETUP_CQSIZE;
  LParams.sq_thread_idle := 10000;  // 10ms idle before kernel poller sleeps
  LParams.cq_entries     := CCQEntries;
  FRingFd := _io_uring_setup(CRingEntries, @LParams);
  if FRingFd >= 0 then
    FSQPoll := True
  else
  begin
    // SQPOLL not available — try normal mode with custom CQ size
    FSQPoll := False;
    FillChar(LParams, SizeOf(LParams), 0);
    LParams.flags      := IORING_SETUP_CQSIZE;
    LParams.cq_entries := CCQEntries;
    FRingFd := _io_uring_setup(CRingEntries, @LParams);
    if FRingFd < 0 then
    begin
      // CQSIZE not supported — plain setup
      FillChar(LParams, SizeOf(LParams), 0);
      FRingFd := _io_uring_setup(CRingEntries, @LParams);
    end;
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

  FSQEsSize := NativeUInt(LParams.sq_entries) * SizeOf(TIOUringSQE);
  FSQEs     := _LinuxMmap(nil, FSQEsSize, PROT_READ or PROT_WRITE,
    MAP_SHARED, FRingFd, IORING_OFF_SQES);
  if FSQEs = MAP_FAILED then
    raise Exception.Create('mmap(SQEs) failed');

  FPSQHead  := PUInt32(PByte(FSQRing) + LParams.sq_off.head);
  FPSQTail  := PUInt32(PByte(FSQRing) + LParams.sq_off.tail);
  FPSQMask  := PUInt32(PByte(FSQRing) + LParams.sq_off.ring_mask);
  FPSQFlags := PUInt32(PByte(FSQRing) + LParams.sq_off.flags);  // #60: NEED_WAKEUP

  FPCQHead  := PUInt32(PByte(FCQRing) + LParams.cq_off.head);
  FPCQTail  := PUInt32(PByte(FCQRing) + LParams.cq_off.tail);
  FPCQMask  := PUInt32(PByte(FCQRing) + LParams.cq_off.ring_mask);
  FPCQEs    := Pointer(PByte(FCQRing) + LParams.cq_off.cqes);

  for I := 0 to Integer(LParams.sq_entries) - 1 do
    PUInt32(PByte(FSQRing) + LParams.sq_off.array_ + NativeUInt(I) * SizeOf(UInt32))^
      := UInt32(I);

  // #75: Register an initial empty file table — allows later REGISTER_FILES_UPDATE
  begin
    var LInitFds: array of Int32;
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

  FCompThread := TThread.CreateAnonymousThread(procedure begin _CompletionLoop; end);
  FCompThread.FreeOnTerminate := False;
  FCompThread.Start;

  // --- #73: Try multishot accept via io_uring ---
  // Submit one IORING_OP_ACCEPT with multishot for each listen socket.
  // If successful, no accept threads needed (kernel pushes CQEs directly).
  FMultishotAccept := False;
  if LAcceptN = 1 then
  begin
    FSQLock.Acquire;
    try
      FMultishotAccept := _SubmitAcceptMultishot(FListenSockets[0]);
      if FMultishotAccept then
        _NotifyKernel;
    finally
      FSQLock.Release;
    end;
  end;

  // Fallback: per-core accept threads (when multishot not used or multiple listeners)
  if not FMultishotAccept then
  begin
    SetLength(FAcceptThreads, LAcceptN);
    for I := 0 to LAcceptN - 1 do
    begin
      LFd := FListenSockets[I];
      FAcceptThreads[I] := TThread.CreateAnonymousThread(
        procedure begin _AcceptOn(LFd); end);
      FAcceptThreads[I].FreeOnTerminate := False;
      FAcceptThreads[I].Start;
    end;
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
  FSQLock.Acquire;
  try
    _SubmitSQE(IORING_OP_NOP, -1, nil, 0, CUdShutdown);
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
var
  LConn: TNativeConn absolute AConn;
begin
  // #75: register the fd for IOSQE_FIXED_FILE (eliminates fget/fput per I/O)
  _RegisterFd(LConn.Socket);
end;

procedure TIOUringBackend.PostRecv(AConn: Pointer);
var
  LCtx: PRecvCtx;
  LConn: TNativeConn absolute AConn;
begin
  LCtx := _RecvPoolAcquire;
  LCtx^.Conn := LConn;
  LConn.AddRef;  // #43: keep conn alive while recv CQE is in-flight
  FSQLock.Acquire;
  try
    if not _SubmitSQE(IORING_OP_RECV, LConn.Socket,
      @LCtx^.Buf[0], CRecvBufSize, UInt64(LCtx)) then
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
  LConn: TNativeConn absolute AConn;
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

// #61: Vectored send — io_uring SEND doesn't support scatter-gather on sockets,
// so concatenate into a pool buffer and delegate to PostSend.
procedure TIOUringBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
var
  LHLen: Integer;
  LBLen: Integer;
  LConcat: TBytes;
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

  LConcat := TBufferPool.Acquire(LHLen + LBLen);
  if LHLen > 0 then Move(AHeaders[0], LConcat[0], LHLen);
  if LBLen > 0 then Move(ABody[0], LConcat[LHLen], LBLen);

  PostSend(AConn, LConcat, LHLen + LBLen);
end;

procedure TIOUringBackend.SocketClose(AConn: Pointer);
var
  LConn: TNativeConn absolute AConn;
begin
  // #75: unregister fd from the file table before closing
  _UnregisterFd(LConn.Socket);
  // R-6: TCP half-close — FIN before full teardown so the client reads pending bytes
  shutdown(LConn.Socket, SHUT_WR);
  _LinuxClose(LConn.Socket);
end;

// ---------------------------------------------------------------------------
// Pre-allocated recv context pool (#56)
// ---------------------------------------------------------------------------

function TIOUringBackend._RecvPoolAcquire: Pointer;
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

procedure TIOUringBackend._RecvPoolRelease(ACtx: Pointer);
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
// #75: Registered files — eliminates fget/fput atomic refcount per I/O op
// ---------------------------------------------------------------------------

const
  CRegFilesMax = 4096;  // max registered fd slots

function TIOUringBackend._RegFileIndex(AFd: Integer): Integer;
begin
  // Linear scan — FRegCount is typically small relative to hot-path savings
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

function TIOUringBackend._RegisterFd(AFd: Integer): Integer;
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

    // #103: recycle freed slots instead of monotonic FRegCount
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

    // #103: use proper io_uring_files_update struct
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

procedure TIOUringBackend._UnregisterFd(AFd: Integer);
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
    // #103: use proper io_uring_files_update struct
    LFdVal := -1;
    FillChar(LUpdate, SizeOf(LUpdate), 0);
    LUpdate.offset := UInt32(LSlot);
    LUpdate.fds := UInt64(@LFdVal);
    _io_uring_register(FRingFd, IORING_REGISTER_FILES_UPDATE, @LUpdate, 1);
    FRegFds[AFd] := -1;
    // #103: recycle slot
    FRegFreeStack[FRegFreeTop] := LSlot;
    Inc(FRegFreeTop);
  finally
    FRegLock.Release;
  end;
end;

// ---------------------------------------------------------------------------
// #60: Notify kernel about new SQEs.  In normal mode, calls io_uring_enter
// with to_submit=1.  In SQPOLL mode, the kernel poller picks up SQEs
// automatically; we only call io_uring_enter if it went idle (NEED_WAKEUP).
// ---------------------------------------------------------------------------

procedure TIOUringBackend._NotifyKernel;
var
  LPending: Integer;
begin
  LPending := FPendingSQEs;
  if LPending <= 0 then
    LPending := 1;
  FPendingSQEs := 0;

  if FSQPoll then
  begin
    // Kernel poller is active — only wake it if it went idle
    if (FPSQFlags <> nil) and
       ((FPSQFlags^ and IORING_SQ_NEED_WAKEUP) <> 0) then
      _io_uring_enter(FRingFd, 0, 0, IORING_ENTER_SQ_WAKEUP);
  end
  else
    _io_uring_enter(FRingFd, LPending, 0, 0);
end;

// ---------------------------------------------------------------------------
// Internal: SQE submission — MUST be called under FSQLock
// ---------------------------------------------------------------------------

function TIOUringBackend._SubmitSQE(AOpcode: Byte; AFd: Integer;
  ABuf: Pointer; ALen: UInt32; AUserData: UInt64): Boolean;
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
  LSQE^.opcode    := AOpcode;
  LSQE^.addr      := UInt64(ABuf);
  LSQE^.len       := ALen;
  LSQE^.user_data := AUserData;

  // #75: use registered file index when available (eliminates fget/fput atomics)
  LRegIdx := _RegFileIndex(AFd);
  if LRegIdx >= 0 then
  begin
    LSQE^.fd    := LRegIdx;
    LSQE^.flags := IOSQE_FIXED_FILE;
  end
  else
    LSQE^.fd := AFd;

  // x86-64 TSO: plain store sufficient; io_uring_enter acts as full barrier
  FPSQTail^ := LTail + 1;
  Inc(FPendingSQEs);  // #109: track for batched submission

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
      UInt64(AConn) or CUdTagSend) then
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

// #73: Submit a multishot accept SQE — one submission handles all future accepts
function TIOUringBackend._SubmitAcceptMultishot(AListenFd: Integer): Boolean;
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
  LSQE^.opcode    := IORING_OP_ACCEPT;
  LSQE^.fd        := AListenFd;
  LSQE^.ioprio    := IOSQE_ACCEPT_MULTISHOT;  // multishot: one SQE → many CQEs
  LSQE^.op_flags  := UInt32(SOCK_NONBLOCK or SOCK_CLOEXEC);  // accept4 flags
  LSQE^.user_data := CUdTagAccept;

  FPSQTail^ := LTail + 1;
  Result := True;
end;

procedure TIOUringBackend._ProcessCQE(AUserData: UInt64; ARes: Int32;
  AFlags: UInt32);
var
  LCtx: PRecvCtx;
  LConn: TNativeConn;
  LRecvConn: TNativeConn;
  LTotal: Integer;
  LOne: Integer;
  LAddr: sockaddr_in;
  LAddrLen: Cardinal;
  LIP: AnsiString;
begin
  if AUserData = CUdShutdown then
  begin
    FShutdown := True;
    Exit;
  end;

  if (AUserData and CUdTagAccept) <> 0 then
  begin
    if ARes >= 0 then
    begin
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
    end;
    // #73: if IORING_CQE_F_MORE not set, kernel cancelled the multishot accept
    if (AFlags and IORING_CQE_F_MORE) = 0 then
    begin
      FMultishotAccept := False;
      // #103: re-arm multishot accept — without this, server stops accepting
      if not FShutdown and (Length(FListenSockets) > 0) then
      begin
        FSQLock.Acquire;
        try
          _SubmitAcceptMultishot(FListenSockets[0]);
          _NotifyKernel;
        finally
          FSQLock.Release;
        end;
      end;
    end;
    Exit;
  end;

  if (AUserData and CUdTagSend) <> 0 then
  begin
    LConn := TNativeConn(Pointer(UInt64(AUserData and not CUdTagSend)));

    if ARes <= 0 then
    begin
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
  LHead, LTail, LMask: UInt32;
  LCQE: PIOUringCQE;
begin
  while not FShutdown do
  begin
    _io_uring_enter(FRingFd, 0, 1, IORING_ENTER_GETEVENTS);

    LMask := FPCQMask^;
    LHead := FPCQHead^;
    LTail := FPCQTail^;

    // #109: Batch CQ head update — process all CQEs, then advance head once.
    // Reduces memory barrier overhead vs per-CQE update.
    while LHead <> LTail do
    begin
      LCQE := PIOUringCQE(PByte(FPCQEs) +
        NativeUInt(LHead and LMask) * SizeOf(TIOUringCQE));
      try
        _ProcessCQE(LCQE^.user_data, LCQE^.res, LCQE^.flags);
      except
        on E: Exception do
          Writeln(ErrOutput, '[io_uring] CQE_EX [', E.ClassName, ']: ', E.Message);
      end;
      Inc(LHead);
    end;
    FPCQHead^ := LHead;
  end;
end;

// ---------------------------------------------------------------------------
// Accept thread — plain accept4() loop, identical to TEpollBackend._Accept
// ---------------------------------------------------------------------------

procedure TIOUringBackend._AcceptOn(AListenFd: Integer);
var
  LFd: Integer;
  LAddr: sockaddr_in;
  LAddrLen: Cardinal;
  LIP: AnsiString;
  LOne: Integer;
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
