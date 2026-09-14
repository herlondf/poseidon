# Crash diagnostics

What Poseidon prints when a process dies, and how to turn it into a fix.

> **Delphi/`dcclinux64` only for now.** Under FPC, `Poseidon.Diagnostics` fails
> to compile — see [Platform notes](platform-notes.md#free-pascal--lazarus).
> An FPC/Linux deployment runs without this crash handler installed.

## The problem this solves

A long-running server that dies of memory corruption on Linux gives you, by
default, almost nothing:

```
malloc(): unaligned tcache chunk detected
Runtime error 232 at 000000000048A2C5
```

`232` is the Delphi RTL's *"Fatal signal raised on a non-Delphi thread"*. The
address alone is useless without the exact binary that produced it, and the
thread that failed is not identified. Worse, a heap overflow usually does **not**
abort where it happens — it corrupts a neighbouring chunk header and only
explodes later, in an unrelated allocation. So even a resolved address often
points at an innocent bystander.

## What you get instead

`TPoseidonDiagnostics.InstallCrashHandler` is called automatically by `Listen()`.
On SIGSEGV / SIGABRT / SIGBUS / SIGFPE / SIGILL it writes to stderr:

```
=== POSEIDON CRASH REPORT (iid=a1b2c3) ===
build  : a696b2d806862683f30ec60aa7179563f93340ad
signal : 6 - SIGABRT (abort - usually glibc heap corruption)
tid    : 7
frames :
./server[0x521398]
/lib/x86_64-linux-gnu/libc.so.6(abort+0xdf)
/lib/x86_64-linux-gnu/libc.so.6(__libc_free+0x7e)   <- the free that detected it
./server[0x521457]                                   <- your call chain
./server[0x52166d]
breadcrumbs:
  [nfce.emissao] POST /nfce/v1/empresa/.../nfce serie=624 rp=800000879
=== END CRASH REPORT ===
Aborted (core dumped)
```

glibc calls `abort()` the instant it finds corrupted heap metadata, so a
backtrace taken from the SIGABRT handler lands on the `malloc`/`free` chain that
tripped it.

The handler restores the default disposition and re-raises the signal, so the
process still dies with the original signal and **the core dump is still
written**. Nothing is swallowed.

### Resolving the addresses

Frames inside your binary print as raw addresses, not names —
`backtrace_symbols_fd` only resolves the dynamic symbol table. Resolve them
against *the same binary*:

```bash
addr2line -f -C -e ./server 0x521457 0x52166d
```

`dcclinux64` keeps symbols by default; do not strip the deployed binary.

### Which binary to resolve against

`build  :` is the running binary's `.note.gnu.build-id`, the same value
`readelf -n <binary> | grep 'Build ID'` prints. It answers "which binary do I
fetch for `addr2line`" without guessing from a deploy timestamp - a wrong
guess resolves silently to nonsense symbols, no error. `(unknown - ...)`
means either the linker didn't emit the note (rare) or `/proc/self/exe`
could not be read at startup; the rest of the report is unaffected.

### What was happening on the other threads

A heap-corruption abort almost never happens where it was caused (see above),
so frames alone often name an innocent bystander, not the request that broke
things. Call this from request-handling code, wherever it is useful to know
"what was this thread doing":

```pascal
TPoseidonDiagnostics.Breadcrumb('nfce.emissao',
  Format('POST %s serie=%s rp=%s', [ARoute, ASerie, ARP]));
```

The last 32 (any thread, oldest dropped first) print with the *next* crash
report, in the order they happened - not just from the thread that died. Two
things this is not: a general-purpose log (use the existing logger for
that - this is capped at 32 and only ever surfaces next to a crash) and a
correctness-critical audit trail (a write racing the crash handler's read can
tear one entry's text under real concurrency; accepted, since the
alternative - a lock the crashing thread might already hold - is the one
failure mode this handler cannot survive).

## Making the abort land near the cause

By default glibc only validates what it happens to touch, so a buffer overflow
can go unnoticed for minutes. Its full checking mode moves the abort to the
corrupting `free()`:

```
LD_PRELOAD=libc_malloc_debug.so.0
GLIBC_TUNABLES=glibc.malloc.check=3
MALLOC_PERTURB_=165
```

> **`MALLOC_CHECK_` on its own does nothing on glibc 2.34+.** The checking was
> moved into `libc_malloc_debug.so.0`, and the tunable is only honoured when that
> library is preloaded. Verified: a deliberate heap overflow goes undetected
> without the `LD_PRELOAD` and aborts with it.

This costs real throughput — it is a debug allocator. Enable it on **one**
instance, not the whole fleet, and leave it there until the fault reproduces.

`MALLOC_PERTURB_` fills freed memory with a byte pattern, which turns
use-after-free from "usually works" into a deterministic failure.

## Core dumps

The handler preserves them, so it is worth enabling:

```
ulimit -c unlimited
```

and mounting a writable path for `/proc/sys/kernel/core_pattern`. A core plus
the unstripped binary gives you full state, not just a stack.

## Before the crash: the health line

A process that logs only at startup leaves you unable to tell a sudden death
from a slow slide into saturation. Poseidon emits, once a minute by default:

```
[startup] backend=epoll (io_uring unavailable) io_workers=8 accept_threads=4 \
          req_pool=8..200 dispatch=worker-pool idle_timeout=10000ms \
          crash_handler=True build=a696b2d806862683f30ec60aa7179563f93340ad
[health] conns=42 inflight=3 pool=12 busy=8 idle=4 backend=epoll
```

`build` is the same value a crash report's `build  :` line carries - printed
here too so a reader confirming "is this the build I think is deployed"
never needs a crash to check.

| Field | Read it as |
|---|---|
| `backend` | Which I/O backend actually started. The io_uring → epoll fallback is automatic (a container seccomp profile blocking `io_uring_setup` is the usual reason) and was previously invisible |
| `dispatch` | `worker-pool` = handlers run off the I/O thread; `sync-inline` = on it |
| `conns` | Open connections |
| `inflight` | Requests queued **or** executing |
| `pool` / `busy` / `idle` | Request-pool threads alive / working / parked |

`busy` climbing toward `pool` while `pool` climbs toward its ceiling is the
saturation signature: handlers are blocking long enough that the pool keeps
spawning. Set `HeartbeatMs := 0` before `Listen()` to silence the line.

## Reproducing memory faults deliberately

Two harnesses in the Benchmark repo, both meant to run under the glibc checking
above:

- `samples/delphi/crash-handler-test` — triggers a real double free, heap
  overflow or null dereference, to confirm the handler is wired up.
- `samples/delphi/poseidon-fuzz` — the repo's parser fuzzer, cross-compiled for
  Linux. `FUZZ_SEED` varies the corpus between runs; `FUZZ_SCALE` deepens it.
  Under `libc_malloc_debug` its invariant strengthens from "never crash" to
  "never corrupt the heap".

## See also

- [Health and recovery](health-and-recovery.md)
- [Thread safety](thread-safety.md)
- [Worker threads](worker-threads.md)
