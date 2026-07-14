# Platform Notes & Known Limitations

Poseidon is dual-face: Windows (IOCP / RIO) and Linux (epoll / io_uring). The
backend is selected at compile time.

| Platform | Default backend | Fallback | Force define |
|---|---|---|---|
| Windows 64-bit | RIO (Registered I/O) | IOCP | `FORCE_IOCP` |
| Linux 64-bit | io_uring | epoll | `FORCE_EPOLL` |

## Windows: Winsock overlapped extension I/O

The Windows backends depend on the overlapped extension functions loaded via
`WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER, …)` (`AcceptEx`) and on Registered
I/O (RIO). On a healthy Windows these are always available.

Some environments — certain Windows Insider builds, or hosts with a security
product that hooks the Winsock catalog — **reject those calls with
`WSAEINVAL (10022)`** while basic `accept()` still works. On such a host the
server accepts TCP connections but cannot complete the overlapped receive, so
it closes the connection without responding, and the live-socket integration
tests fail.

This is an **environmental limitation, not a code defect** (reproducible with a
few lines of pure Winsock, no Poseidon involved). If you hit it:

- Run the live-socket integration tests / conformance suites on a clean Windows
  host or on **Linux** (see [Testing & Conformance](testing-and-conformance.md)).
- The pure/logic and fuzz tests are unaffected and validate the parsing and
  protocol logic without sockets.

## Linux: TLS is not yet production-ready

The Linux build (epoll / io_uring) serves plain HTTP correctly and completes the
TLS handshake, but **HTTPS and HTTP/2-over-TLS currently have a crash on Linux**
in the post-handshake receive/dispatch path (a timing-sensitive race /
use-after-free on the SSL + async-worker boundary). It reproduces on both
backends and blocks the HTTP/2 conformance run.

**Recommendation:** until this is fixed, terminate TLS in front of Poseidon on
Linux (e.g. a reverse proxy / load balancer doing TLS, Poseidon serving plain
HTTP behind it). Plain HTTP on Linux is not affected. Track the fix in the
project issues.

## OpenSSL

TLS loads OpenSSL dynamically on the first `ConfigureSSL` call — no compile-time
dependency:

- Windows: `libssl-3-x64.dll` / `libssl-1_1-x64.dll` (and `libcrypto`) in `PATH`.
- Linux: `libssl.so.3` / `libssl.so.1.1` (and `libcrypto`) — e.g.
  `apt install openssl` / `libssl3`.
