# Worker threads

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

## Notes

- Workers are OS threads, not green threads. Each blocked worker holds a full stack.
- I/O completion (accept, read, write) is handled by a separate I/O thread — workers only run your callback.
- If all workers are busy, new requests queue in the OS completion port backlog.
