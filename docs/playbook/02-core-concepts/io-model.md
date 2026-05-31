# I/O model

Poseidon uses native async I/O on both supported platforms:

| Platform | Mechanism | Description |
|----------|-----------|-------------|
| Windows 64-bit | IOCP (I/O Completion Ports) | Kernel posts completed I/O operations to a queue; workers dequeue them |
| Linux 64-bit | epoll(7) level-triggered + `EPOLLONESHOT` | Kernel notifies readiness; worker reads and re-arms the fd |

## Key properties

- **Zero thread-per-connection overhead** — connections are file descriptors in a kernel set, not blocked threads.
- **Single send per response** — the full HTTP response (headers + body) is assembled in one buffer and sent with a single `WSASend`/`send` call. This eliminates Nagle/delayed-ACK stalls that affect multi-write servers on loopback.
- **Worker pool** — I/O completion is handled by a dedicated I/O thread. Workers only run application callbacks. The two thread pools never block each other.

## Windows: IOCP

`WSARecv` and `WSASend` are posted with an `OVERLAPPED` structure. When the OS
completes the operation, it posts a completion packet to the IOCP handle.
Worker threads call `GetQueuedCompletionStatus` in a loop and dispatch accordingly.

Each in-flight operation holds a reference on the `TNativeConn` object
(`AddRef`/`Release`). This ensures the connection is not freed while an IOCP
packet is still queued in the kernel.

## Linux: epoll

The server creates one epoll fd at startup. Each accepted socket is added with
`EPOLLONESHOT | EPOLLIN`. When epoll reports readiness, a worker reads the
available bytes and then re-arms the fd with `EPOLL_CTL_MOD`.

`EPOLLONESHOT` ensures only one worker processes a given fd at a time, eliminating
lock contention on the connection object.

## See also

- [Connection lifecycle](connection-lifecycle.md)
- [Worker threads](../04-operations/worker-threads.md)
