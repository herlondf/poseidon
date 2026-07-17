unit Poseidon.Compat.Posix;

// Free Pascal POSIX/Linux compatibility for the epoll / io_uring backends
// (issue #5). Those units bind their own libc entry points (socket, bind,
// mmap, accept4, the io_uring syscalls) directly via `external 'libc.so.6'`,
// so from Delphi's Posix.* units they need only a small slice of TYPES and
// CONSTANTS: the sockaddr_in record, htons/inet_addr, MarshaledAString, and a
// handful of AF_/SOCK_/PROT_/MAP_ constants. FPC has no Posix.* units, so this
// mirrors exactly that slice (values are the Linux/x86-64 ABI), letting the
// backend bodies compile unchanged. FPC + non-Windows only.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
{$ENDIF}

interface

{$IFDEF FPC}
{$IFNDEF MSWINDOWS}

type
  MarshaledAString = PAnsiChar;
  socklen_t   = LongWord;
  sa_family_t = Word;
  in_port_t   = Word;

  in_addr = record
    s_addr: Cardinal;   // network byte order
  end;

  sockaddr_in = record
    sin_family: sa_family_t;
    sin_port:   in_port_t;
    sin_addr:   in_addr;
    sin_zero:   array[0..7] of Byte;
  end;
  TSockAddrIn = sockaddr_in;
  PSockAddrIn = ^sockaddr_in;

  // Generic socket address (same 16-byte footprint as sockaddr_in); used as a
  // cast target for getpeername.
  sockaddr = record
    sa_family: sa_family_t;
    sa_data:   array[0..13] of Byte;
  end;
  Psockaddr = ^sockaddr;

  // C signal-handler function pointer (Delphi Posix.Signal.TSignalHandler).
  TSignalHandler = procedure(ASigNum: Integer); cdecl;

  // glibc x86-64 signal set (128 bytes) + sigaction struct. Field names/order
  // mirror Delphi's Posix.Signal.sigaction_t so GracefulReload compiles as-is.
  sigset_t = record
    __val: array[0..15] of QWord;
  end;

  sigaction_t = record
    _u: record
      sa_handler: TSignalHandler;   // union with sa_sigaction; handler used here
    end;
    sa_mask:     sigset_t;
    sa_flags:    Integer;
    sa_restorer: Pointer;
  end;
  Psigaction_t = ^sigaction_t;

const
  // signals
  SIGHUP  = 1;
  SIGINT  = 2;
  SIGPIPE = 13;
  SIGTERM = 15;
  SIG_IGN = Pointer(1);   // ignore-signal sentinel (cast to TSignalHandler)
  SIG_DFL = Pointer(0);


  // errno values (Linux/x86-64 ABI)
  EINTR       = 4;
  EAGAIN      = 11;
  EWOULDBLOCK = 11;
  EINVAL      = 22;
  EPIPE       = 32;
  ENOSYS      = 38;
  ECONNRESET  = 104;
  EINPROGRESS = 115;
  EPERM       = 1;


  // Address / socket families and types (Linux x86-64 ABI)
  AF_INET       = 2;
  INADDR_ANY    = 0;
  SOCK_STREAM   = 1;
  SOCK_NONBLOCK = $800;    // 04000 octal
  SOCK_CLOEXEC  = $80000;  // 02000000 octal

  // setsockopt levels / options
  SOL_SOCKET   = 1;
  SO_REUSEADDR = 2;
  SO_KEEPALIVE = 9;
  IPPROTO_TCP  = 6;
  TCP_NODELAY  = 1;
  SOMAXCONN    = 128;

  // shutdown(2) directions
  SHUT_RD   = 0;
  SHUT_WR   = 1;
  SHUT_RDWR = 2;

  // mmap protection / flags
  PROT_READ    = 1;
  PROT_WRITE   = 2;
  MAP_SHARED   = 1;
  MAP_PRIVATE  = 2;
  MAP_POPULATE = $8000;
  MAP_ANONYMOUS = $20;

  MAP_FAILED: Pointer = Pointer(-1);   // mmap failure sentinel

// libc byte-order + address helpers (the backends call these unqualified).
function htons(AHostShort: Word): Word; cdecl; external 'libc.so.6' name 'htons';
function htonl(AHostLong: Cardinal): Cardinal; cdecl; external 'libc.so.6' name 'htonl';
function ntohs(ANetShort: Word): Word; cdecl; external 'libc.so.6' name 'ntohs';
function inet_addr(cp: MarshaledAString): Cardinal; cdecl; external 'libc.so.6' name 'inet_addr';
function inet_ntoa(inaddr: in_addr): MarshaledAString; cdecl; external 'libc.so.6' name 'inet_ntoa';
function getpeername(socket: Integer; var address: sockaddr;
  var address_len: socklen_t): Integer; cdecl; external 'libc.so.6' name 'getpeername';
function shutdown(socket: Integer; how: Integer): Integer; cdecl; external 'libc.so.6' name 'shutdown';
function signal(sig: Integer; handler: TSignalHandler): TSignalHandler; cdecl; external 'libc.so.6' name 'signal';
function sigaction(sig: Integer; act: Psigaction_t; oldact: Psigaction_t): Integer; cdecl; external 'libc.so.6' name 'sigaction';
function sigemptyset(var nset: sigset_t): Integer; cdecl; external 'libc.so.6' name 'sigemptyset';
function getpid: Integer; cdecl; external 'libc.so.6' name 'getpid';

// Delphi's cross-platform GetLastError maps to errno on POSIX. The backends
// call libc entry points directly, so this must read LIBC's thread-local errno
// (not FPC's own), which lives behind __errno_location().
function GetLastError: Integer;

{$ENDIF}
{$ENDIF}

implementation

{$IFDEF FPC}
{$IFNDEF MSWINDOWS}

function __errno_location: PInteger; cdecl; external 'libc.so.6' name '__errno_location';

function GetLastError: Integer;
begin
  Result := __errno_location^;
end;

{$ENDIF}
{$ENDIF}

end.
