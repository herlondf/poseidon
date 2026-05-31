# Worker threads & graceful shutdown

Poseidon dispatches incoming requests to a thread pool. The default pool size is **200 workers**
(`WorkerCount` property on `TPoseidonNativeServer`).

## Sizing guidance

```
workers = peak_concurrent_requests × (1 + avg_blocking_wait_ms / avg_cpu_ms)
```

For pure in-memory handlers: `WorkerCount = logical CPU count × 2` is sufficient.
For handlers that hit a database (blocking I/O): keep the default 200 or match your DB pool size.

## Changing worker count

Must be set **before** `Listen`:

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.WorkerCount := 50;
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

## Graceful shutdown (R-1)

`Stop` waits for all in-flight requests to complete before returning.
It uses an internal event (no busy-wait / Sleep loop) so the calling thread blocks
efficiently until the drain completes or the timeout expires.

```pascal
LServer.DrainTimeoutMs := 15000;  // default 30 000 ms
LServer.Stop;
// returns when all in-flight requests have finished, or after DrainTimeoutMs
```

`DrainTimeoutMs` must be set before `Listen` (it is read once at start, not during drain).

### Typical shutdown pattern

```pascal
// in a signal handler or application shutdown:
LServer.Stop;
LServer.Free;
```

### HTTP/2 and graceful shutdown

For HTTP/2 connections, `Stop` additionally:

1. Sends a `GOAWAY` frame to each active h2 connection (last processed stream ID +
   `NO_ERROR` error code), giving clients a chance to retry streams on a new connection.
2. Defers the TCP close until all active streams have finished sending their responses.
3. After responses are flushed, performs a TCP half-close (`SD_SEND` / `SHUT_WR`) so
   the client can read any bytes still in-flight before the socket is torn down.

All of this is automatic — no extra configuration beyond `DrainTimeoutMs`.

## Notes

- Workers are OS threads, not green threads. Each blocked worker holds a full stack.
- I/O completion (accept, read, write) is handled by a separate I/O thread — workers only run your callback.
- If all workers are busy, new requests queue in the OS completion port backlog.
- `MaxQueueDepth` (default 0 = unlimited) lets you cap the in-flight count and return 503 when the limit is reached — see [limits-and-backpressure.md](limits-and-backpressure.md).
