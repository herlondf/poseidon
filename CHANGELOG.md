# Changelog

All notable changes to Poseidon are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/), and the project aims at
[Semantic Versioning](https://semver.org/).

## [Unreleased] — v2 production-readiness hardening

Security, correctness and conformance hardening toward the v2 maturity gate
(≥85). Two-face (Windows IOCP/RIO + Linux epoll/io_uring) throughout.

### Security
- **HTTP/2 control-frame flood defense** (CVE-2019-9512 PING / -9515 SETTINGS /
  -9518 empty-frame): rolling-window counter of unproductive frames → GOAWAY
  `ENHANCE_YOUR_CALM`. Zero-length CONTINUATION flood also bounded.
- **TLS context hardening**: disable client-initiated renegotiation
  (`SSL_OP_NO_RENEGOTIATION`, TLS 1.2 CPU-amplification DoS), TLS compression
  (`SSL_OP_NO_COMPRESSION`, CRIME) and set server cipher preference.
- **Rate limiter**: hard cap on the tracked-key map (was unbounded → memory-DoS
  and bypass via IPv6/XFF rotation) with amortized eviction and fail-closed; a
  length guard on the `X-Forwarded-For`-derived key.
- **Digest auth**: bind the authenticated `uri` to the actual request path
  (blocks replaying a captured header onto another resource); amortize the nonce
  purge (was an O(n)-per-request lock-held DoS under a 401 flood).
- **JWT**: optional `aud` / `iss` enforcement and require-`exp` (blocks
  cross-service token replay when an HMAC secret is shared).
- **ALPN** no longer selects a protocol the server does not implement
  (RFC 7301 §3.2 — was a protocol-confusion path).
- **HPACK / HTTP/1** hardening proven by deterministic guards: HPACK-bomb,
  Huffman EOS, unsigned length bounds, dyn-table cap; HTTP/1 request smuggling
  (CL.CL, CL+TE, obs-fold, whitespace-before-colon, oversized Content-Length).

### Fixed
- **Windows: connections dropped/hung before dispatch.** Two real code bugs, not
  an environmental issue: (1) the RIO backend accepted with a plain `accept()`,
  yielding sockets that are not RIO-capable, so `RIOCreateRequestQueue` had
  nothing valid to register and every connection was dropped ("socket hang up",
  handler never reached); (2) the IOCP backend obtained `AcceptEx` only via
  `WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER)`, which can fail with `WSAEINVAL`
  on the listen socket, leaving `FAcceptEx = nil` and the server never ready.
  Fixes: IOCP is now the default Windows backend (RIO opt-in via `-DFORCE_RIO`);
  `AcceptEx`/`GetAcceptExSockaddrs` fall back to the static `mswsock.dll` exports
  when `WSAIoctl` fails; the accepted socket is set non-blocking and the readiness
  `recv` re-arms on `WSAEWOULDBLOCK` instead of blocking a worker thread.
- **io_uring TLS record corruption under load**: one send in flight per
  connection + ordered backlog (unordered SEND SQEs interleaved TLS records).
- **io_uring `SEND_ZC` `-EAGAIN`** on a full socket buffer no longer kills the
  connection (retried via io-wq); the ZC remainder buffer is sized correctly.
- **HTTP/2 `FActiveStreams` leak** when a flow-control-buffered stream is
  `RST_STREAM`'d (a graceful GOAWAY drain would never complete).
- **WebSocket messages > `MaxRequestSize`**: `StepSizeCheck` now skips WS
  connections (was 413 + close before the echo).
- **io_uring backend `Destroy`** signals + joins the completion thread before
  unmapping the rings (UAF window on a failed `StartListening`).
- HTTP/2 conformance: RFC 7540 frame validation, HPACK / content-length /
  pseudo-header errors, dyn-table-size, truncated header block, H2Conn
  use-after-free at teardown (deferred close). h2spec 1/146 → 145/146.

### Added
- **Two-face CI harness** (`ci/run-ci.ps1`): compile gate + socket-free fuzz
  runner + Win64 suite (env failures tolerated via a baseline) + optional Linux
  conformance (h2spec + Autobahn, reusing a provisioned WSL distro, CI-safe).
  `.github/workflows/ci.yml` for a self-hosted runner. See `ci/README.md`.
- **Fuzzing**: dedicated socket-free runner with HTTP/1 + HPACK + WebSocket
  fuzz and deterministic invariant / smuggling guards.
- **Conformance harnesses**: h2spec (`tests/run-h2spec.ps1`, `-Reuse` mode) and
  Autobahn (`tests/autobahn/`). Current: h2spec 145/146, Autobahn 247/247 core +
  42/42 large-payload.
- **Vendor sync** (`ci/sync-vendor.ps1`): mirror/drift-check the Benchmark repo's
  vendored copy.
- `ERR_clear_error` before each SSL op for accurate `SSL_get_error` classification.

### Changed
- Default Windows I/O backend: **RIO → IOCP** (see Fixed). Set `-DFORCE_RIO` to
  keep RIO where it is validated to serve end-to-end.

[Unreleased]: https://github.com/herlondf/poseidon/commits/master
