# Worker threads & graceful shutdown

Poseidon dispatches incoming requests to a thread pool. The default pool size is **200 workers**
(`WorkerCount` property on `TPoseidonNativeServer`).

## Sizing guidance

```
workers = peak_concurrent_requests × (1 + avg_blocking_wait_ms / avg_cpu_ms)
```

### By workload type

| Workload | Recommended `WorkerCount` | Why |
|----------|--------------------------|-----|
| CPU-bound (in-memory, no I/O) | `logical CPU count` – `× 2` | More workers add context-switch overhead without increasing throughput |
| I/O-bound (DB queries, external APIs) | `peak_concurrent_clients × (1 + wait_ms / cpu_ms)` | Blocked workers hold a thread; more threads = shorter queue |
| Mixed | Start at `auto`; tune with the workers scaling benchmark | Let data decide |

### Benchmark evidence — scaling curve (DAO latency, 50 concurrent clients)

`Theoretical max RPS = workers × (1000 / DAO_ms)`. Results at 50 concurrent clients:

| Workers | DAO=5ms RPS | DAO=30ms RPS | DAO=100ms RPS | Notes |
|---------|-------------|--------------|---------------|-------|
| 4       | 664         | 130          | 40            | **Saturated** at all latencies; matches theory (4×200=800, 4×33=133, 4×10=40) |
| 8       | 1 238       | 257          | 79            | Headroom appears; avg latency drops below 50% of W=4 |
| auto    | 1 949       | 499          | 78            | Adapts to machine CPU count; typically near-optimal |
| 16      | 1 938       | 502          | 126           | Diminishing returns at 5ms; significant gain at 100ms |
| 32      | 2 110       | 706          | 239           | Best raw RPS at high DAO; context-switch overhead visible at 5ms |

Diagnostic rule: if `avg_latency > 2 × handler_sleep_ms`, add more workers.

For pure in-memory handlers: `WorkerCount = logical CPU count × 2` is sufficient.
For handlers that hit a database (blocking I/O): start with `auto`, then tune upward if
`avg_latency > 2 × DB_query_ms`.

> For the full workers scaling matrix (W=4…32 × DAO=5/30/100ms × concurrency=10/50),
> run `Poseidon.Benchmark.Workers` which generates HTML reports in `benchmark/bin/`.

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
