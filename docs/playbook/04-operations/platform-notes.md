# Platform Notes & Known Limitations

Poseidon is dual-face: Windows (IOCP / RIO) and Linux (io_uring / epoll), and
compiles under **both Delphi and Free Pascal**. The backend is selected once at
construction (compile-time defines override the default).

| Platform | Default backend | Alternative | Force define |
|---|---|---|---|
| Windows 64-bit | IOCP | RIO (Registered I/O) | `FORCE_RIO` |
| Linux 64-bit | io_uring | epoll | `FORCE_EPOLL` |

## Windows: Winsock overlapped extension I/O

The IOCP backend loads `AcceptEx` / `GetAcceptExSockaddrs` via
`WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER, …)`. Some environments — certain
Windows Insider builds, or hosts with a security product that hooks the Winsock
catalog — reject that call with `WSAEINVAL (10022)`. Poseidon handles this by
**falling back to the static `mswsock.dll` exports** for `AcceptEx`, so the
server stays functional on such hosts.

A separate, real bug (fixed) used to drop ~1-in-4 connections under churn: a
socket recycled via `DisconnectEx(TF_REUSE_SOCKET)` stays associated with the
IOCP, and re-calling `CreateIoCompletionPort` returned `ERROR_INVALID_PARAMETER`,
which was treated as fatal. That is now tolerated. The live-socket integration
suite passes clean (0 tolerated environmental failures).

## Linux: TLS

The Linux build (io_uring / epoll) serves plain **and** TLS traffic. The
post-handshake SSL race / use-after-free that used to crash HTTPS/HTTP2-over-TLS
was resolved (all per-connection SSL / `H2Conn` / accum-buffer access is now
serialized under the connection lock; SIGPIPE ignored). Evidence: h2spec **145/146
over TLS/ALPN** and Autobahn **247/247** run green against the Linux io_uring
backend, and a 5.4 h soak on io_uring showed no leak/crash.

## OpenSSL

TLS loads OpenSSL dynamically on the first `ConfigureSSL` call — no compile-time
dependency:

- Windows: `libssl-3-x64.dll` / `libssl-1_1-x64.dll` (and `libcrypto`) in `PATH`.
- Linux: `libssl.so.3` / `libssl.so.1.1` (and `libcrypto`) — e.g.
  `apt install openssl` / `libssl3`.

## Free Pascal / Lazarus

Poseidon compiles and serves HTTP under **FPC 3.3.1** (trunk) on Win64 (IOCP)
and Linux (io_uring / epoll), alongside Delphi. The Delphi build path is
byte-identical (all FPC support lives behind `{$IFDEF FPC}` + an FPC-only
`src/compat/` layer).

- **Compiler:** FPC **3.3.1** (trunk) is required — `reference to` / anonymous
  methods and attribute RTTI are not in the 3.2.2 release. Flags:
  `-MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes`.
- **Linux threading:** `cthreads` must be the **first** unit of the program
  (`{$IFDEF UNIX}`) or `TEvent` / `TThread` fail at runtime.
- **Dispatch mode:** under FPC the server defaults to **SyncDispatch** (inline
  dispatch on the IO thread). The async worker-pool path is best-effort — the
  current FPC trunk has closure-codegen / thread-startup issues that SyncDispatch
  side-steps entirely. Delphi keeps async by default.
- **`TMonitor`** is non-functional under FPC; the pools use `TCriticalSection`
  in the FPC branch.
- **Gates:** `tests/fpc/build-server-fpc.ps1` (Windows) and
  `tests/fpc/build-linux-fpc.sh` (Linux) build the full closure and run a real
  HTTP-serve smoke.
