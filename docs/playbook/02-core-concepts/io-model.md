# I/O model

Poseidon uses native async I/O on all supported platforms:

| Platform | Mechanism | Selection |
|----------|-----------|-----------|
| Windows 64-bit | IOCP (I/O Completion Ports) | always |
| Linux 64-bit — kernel ≥ 5.1 | **io_uring** | automatic (preferred) |
| Linux 64-bit — kernel < 5.1 | epoll(7) + `EPOLLONESHOT` | automatic fallback |

The Linux backend is selected **once** at `TPoseidonNativeServer.Create` time: if
the `io_uring_setup` syscall (425) succeeds, `TIOUringBackend` is used; otherwise
(`ENOSYS` or `EPERM`) the server silently falls back to `TEpollBackend`.
There is zero per-request overhead from the selection — it is a vtable pointer
set once at construction.

## Key properties

- **Zero thread-per-connection overhead** — connections are file descriptors in a kernel set, not blocked threads.
- **Single send per response** — headers + body assembled in one buffer, sent with a single `WSASend`/`send`. Eliminates Nagle/delayed-ACK stalls on loopback.
- **Pluggable backend** — `IIOBackend` separates the server from the I/O platform; no `{$IFDEF}` blocks in the request hot path.

## Windows: IOCP

`WSARecv` and `WSASend` are posted with an `OVERLAPPED` structure. When the OS
completes the operation, it posts a completion packet to the IOCP handle.
Worker threads call `GetQueuedCompletionStatus` in a loop and dispatch accordingly.

## Linux: io_uring (preferred, kernel ≥ 5.1)

`TIOUringBackend` manages a single `io_uring` ring. `PostRecv` submits an
`IORING_OP_RECV` SQE with a heap-allocated per-request buffer. A dedicated
completion thread calls `io_uring_enter(GETEVENTS)` in a loop, drains available
CQEs, and dispatches `OnRecv` / `OnSendComplete` / `OnConnError` directly.

Advantages over epoll: `IORING_OP_SEND` avoids extra `send()` syscalls, and the
kernel DMA-fills the recv buffer in-place without an extra copy.

## Linux: epoll (fallback)

The server creates one epoll fd at startup. Each accepted socket is added with
`EPOLLONESHOT | EPOLLIN`. When epoll reports readiness, a worker reads the
available bytes and re-arms the fd with `EPOLL_CTL_MOD`.

`EPOLLONESHOT` ensures only one worker processes a given fd at a time, eliminating
lock contention on the connection object.

## See also

- [Connection lifecycle](connection-lifecycle.md)
- [Worker threads](../04-operations/worker-threads.md)
