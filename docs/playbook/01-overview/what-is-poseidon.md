# What is Poseidon

Poseidon is a native async I/O HTTP server library for Delphi.
It bypasses the Delphi-Cross-Socket and Indy stacks in favour of direct OS syscalls:

- **Windows**: I/O Completion Ports (IOCP) via `WSARecv` / `WSASend`
- **Linux (kernel ≥ 5.1)**: io_uring via `io_uring_setup` / `io_uring_enter` (preferred)
- **Linux (kernel < 5.1)**: epoll level-triggered + `EPOLLONESHOT` (automatic fallback)

A single `WSASend` (or `write`) call delivers the entire HTTP response — no Nagle stall,
no double-write, no `TCP_NODELAY` workaround needed.

## Key properties

| Property | Value |
|----------|-------|
| External dependencies | **zero** |
| Platforms | Linux 64-bit, Windows 64-bit |
| Default worker threads | 200 (`WorkerCount`) |
| Response delivery | single syscall per response |
| Protocols | HTTP/1.1, HTTPS, WebSocket, HTTP/2 (ALPN + h2c cleartext) |
