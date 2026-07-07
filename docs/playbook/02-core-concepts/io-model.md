# I/O model

Poseidon uses native async I/O on all supported platforms:

| Platform | Mechanism | Selection |
|----------|-----------|-----------|
| Windows 64-bit (primary) | **RIO** (Registered I/O) | automatic (preferred) |
| Windows 64-bit (fallback) | IOCP (I/O Completion Ports) | automatic or `FORCE_IOCP` |
| Linux 64-bit — kernel >= 5.1 | **io_uring** | automatic (preferred) |
| Linux 64-bit — kernel < 5.1 | epoll(7) + `EPOLLONESHOT` | automatic fallback or `FORCE_EPOLL` |

The backend is selected **once** at `TPoseidonNativeServer.Create` time and
stored as a vtable pointer (`IIOBackend`). There is zero per-request overhead
from the selection.

---

## Key properties

- **Zero thread-per-connection overhead** — connections are file descriptors in a kernel set, not blocked threads.
- **Single send per response** — headers + body assembled in one buffer, sent with a single `WSASend`/`send`. Eliminates Nagle/delayed-ACK stalls on loopback.
- **Pluggable backend** — `IIOBackend` separates the server from the I/O platform; no `{$IFDEF}` blocks in the request hot path.

---

## Windows: RIO (primary)

Registered I/O (`mswsock.h`, available since Windows 8 / Server 2012) provides
the lowest-overhead path on Windows:

- **Pre-registered buffers** — receive and send buffers are registered with the
  kernel once at startup (`RIORegisterBuffer`). The kernel reads and writes
  directly into these buffers without a per-call copy.
- **Zero-syscall polling** — the completion queue (CQ) is a shared-memory ring
  between user space and the kernel. Worker threads call `RIODequeueCompletion`
  on the CQ without issuing a syscall; the kernel signals readiness via an IOCP
  notification handle used only as a wake-up event.
- **Shared-memory CQ** — multiple I/O operations share one CQ per worker thread,
  reducing context switches compared to one IOCP packet per operation.

Poseidon creates one RIO request queue per worker thread and one shared CQ.
`PostRecv` submits a `RIO_BUF` pointing into the pre-registered buffer pool;
`PostSend` does the same for the outgoing side.

## Windows: IOCP (fallback)

Used automatically when RIO is unavailable, or when the `FORCE_IOCP` define is
set at compile time.

`WSARecv` and `WSASend` are posted with an `OVERLAPPED` structure. When the OS
completes the operation it posts a completion packet to the IOCP handle.
Worker threads call `GetQueuedCompletionStatus` in a loop and dispatch accordingly.

To force IOCP and skip RIO:

```pascal
{$DEFINE FORCE_IOCP}
```

---

## Linux: io_uring (preferred, kernel >= 5.1)

`TIOUringBackend` manages a single `io_uring` ring with two optional
optimizations enabled when the kernel supports them:

- **Registered files** (`IORING_REGISTER_FILES`) — file descriptors for all
  accepted sockets are registered with the ring at accept time and referenced by
  index in subsequent SQEs, eliminating the per-operation fd table lookup in the
  kernel.
- **Multishot accept** (`IORING_OP_ACCEPT` with `IOSQE_IO_LINK`) — a single SQE
  continuously re-arms itself after each accepted connection, avoiding repeated
  `accept4` submissions.

`PostRecv` submits an `IORING_OP_RECV` SQE with a heap-allocated per-request
buffer. A dedicated completion thread calls `io_uring_enter(GETEVENTS)` in a
loop, drains available CQEs, and dispatches `OnRecv` / `OnSendComplete` /
`OnConnError` directly.

Advantages over epoll: `IORING_OP_SEND` avoids extra `send()` syscalls, and the
kernel DMA-fills the recv buffer in-place without an extra copy.

To force epoll and skip io_uring (e.g., in containers without `io_uring` permission):

```pascal
{$DEFINE FORCE_EPOLL}
```

## Linux: epoll (fallback)

Used automatically when `io_uring_setup` (syscall 425) returns `ENOSYS` or
`EPERM`, or when `FORCE_EPOLL` is defined.

- **Shared-nothing per-core** — when `PerCoreAccept` is enabled, each worker
  thread owns its own epoll fd and binds to the listener socket via
  `SO_REUSEPORT`. The kernel load-balances accepted connections across all
  epoll instances without a shared lock.
- **EPOLLONESHOT** — each accepted socket is added with `EPOLLONESHOT | EPOLLIN`.
  When epoll reports readiness, one worker reads the available bytes and
  re-arms the fd with `EPOLL_CTL_MOD`. This ensures only one worker processes a
  given fd at a time, eliminating lock contention on the connection object.

---

## Backend selection summary

| Compile-time define | Windows result | Linux result |
|---------------------|---------------|--------------|
| (none) | RIO if available, else IOCP | io_uring if available, else epoll |
| `FORCE_IOCP` | IOCP | (no effect) |
| `FORCE_EPOLL` | (no effect) | epoll |

Selection happens once at construction. Changing the define requires
recompilation; there is no runtime switch.

---

## See also

- [Connection lifecycle](connection-lifecycle.md)
- [Worker threads](../04-operations/worker-threads.md)
