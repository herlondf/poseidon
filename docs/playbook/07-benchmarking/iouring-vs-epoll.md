# io_uring vs epoll — Comparison Methodology

Poseidon automatically selects the best available I/O back-end at startup:

| Back-end | Condition | Notes |
|----------|-----------|-------|
| **io_uring** | Linux, kernel ≥ 5.1 | Preferred; fewer syscalls per request |
| **epoll** | Linux, kernel < 5.1 or io_uring blocked | Automatic fallback |
| **IOCP** | Windows | Always used on Windows |

Because the selection is automatic, comparing the two back-ends requires two
separate runs on different environments.

## Setup

**Run 1 — io_uring path** (kernel ≥ 5.1, io_uring not blocked by seccomp):

```bash
uname -r           # must print 5.1 or higher
./Poseidon.Sample.Benchmark
```

**Run 2 — epoll fallback** (one of):

- Machine with kernel < 5.1
- Container with `seccomp` policy that blocks `io_uring_setup` (syscall 425)
- Temporarily block via `sysctl -w kernel.io_uring_disabled=1`
  (available on kernel ≥ 5.10)

## Expected difference

io_uring batches submission and completion in shared ring buffers, eliminating
per-operation `epoll_ctl` + `read`/`write` syscalls.  Under high concurrency
(> 500 concurrent connections) the syscall reduction typically yields:

- 15–30% higher throughput
- 20–40% lower P99 latency

The benefit is smaller for low-concurrency workloads where syscall overhead is
not the bottleneck.

## Confirming which back-end is active

Add a log callback before `Listen`:

```pascal
LServer.OnLog :=
  procedure(ALevel: TLogLevel; const AMsg: string)
  begin
    if ALevel <= llInfo then Writeln(AMsg);
  end;
```

The server logs `[INFO] I/O back-end: io_uring` or `[INFO] I/O back-end: epoll`
during startup.
