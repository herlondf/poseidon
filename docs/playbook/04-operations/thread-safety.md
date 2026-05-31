# Thread safety

## Request handler threading model

Each incoming request is dispatched to a worker thread from the pool.
The handler callback is always called from a **worker thread**, never from the
main thread or the I/O completion thread.

```pascal
// This handler may be called concurrently from multiple worker threads
procedure HandleRequest(
  const AReq: TPoseidonNativeRequest; ...);
begin
  // SAFE: reading AReq fields (immutable for the lifetime of this call)
  // UNSAFE without a lock: accessing module-level variables shared across requests
end;
```

## What is safe

| Operation | Safe? | Notes |
|-----------|-------|-------|
| Reading `AReq` fields | ✅ | Immutable per-call |
| Writing to `AStatus`, `ABody`, `AContentType`, `AExtraHeaders` | ✅ | Per-call out-params |
| Reading `LServer` properties | ✅ | Properties are read-only after `Listen` |
| Accessing a per-connection database connection | ✅ | If each request creates its own |
| Accessing a global `TDictionary` | ❌ | Must protect with `TMonitor` or `TCriticalSection` |
| Accessing a shared `TStringList` | ❌ | Not thread-safe |

## Protecting shared state

```pascal
var
  GCounterLock: TCriticalSection;
  GRequestCount: Integer;

procedure HandleRequest(...);
begin
  GCounterLock.Enter;
  try
    Inc(GRequestCount);
  finally
    GCounterLock.Leave;
  end;
  // ...
end;
```

Prefer `TInterlocked` for simple integer counters:

```pascal
TInterlocked.Increment(GRequestCount);
```

## I/O thread separation

The I/O completion thread (IOCP / io_uring / epoll) is separate from the worker pool.
It calls `OnRecv`/`OnSend` callbacks internally but never invokes the application
handler. The only shared objects between I/O thread and workers are the
`TNativeConn` connection objects, which are ref-counted for safe cross-thread lifetime.

## WebSocket handlers

WebSocket handlers (`RegisterWSHandler`) follow the same rules — called from a
worker thread, one at a time per connection, but multiple connections are concurrent.

## Notes

- `WorkerCount` (default 200) controls the level of concurrency. Design shared
  state to handle up to `WorkerCount` concurrent writers.
- For coarse-grained locking, `TMonitor` (built into every Delphi object) is
  convenient but has higher overhead than a dedicated `TCriticalSection`.
