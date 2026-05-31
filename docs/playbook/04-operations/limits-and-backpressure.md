# Limits & backpressure

Poseidon provides several configurable limits that defend against resource exhaustion
and allow controlled degradation under load.

## Request size limits (R-4)

```pascal
LServer.MaxRequestSize := 4 * 1024 * 1024;  // 4 MB — 413 on exceed
LServer.MaxHeaderSize  := 32768;             // 32 KB — 400 on exceed
```

See [http1.md](../03-protocols/http1.md#request-and-header-size-limits-r-4) for details.

## Connection limits

```pascal
LServer.MaxConnections      := 10000;  // global limit — new sockets dropped on exceed
LServer.MaxConnectionsPerIP := 100;    // per-IP limit — new sockets dropped on exceed
```

Default is `0` (unlimited) for both. When the limit is reached, the incoming socket
is closed immediately with no HTTP response.

## Queue depth / backpressure (R-5)

`MaxQueueDepth` caps the number of requests being processed simultaneously.
When the limit is reached, the server returns `503 Service Unavailable` instead of
queuing more work.

```pascal
LServer.MaxQueueDepth := 500;  // 0 = unlimited (default)
```

Pair with `WorkerCount` to size the system: `MaxQueueDepth` is the acceptance gate
(fast path), `WorkerCount` is the processing capacity (slow path).

## Rate limiting

Fixed-window counters reset every second.

```pascal
LServer.RateLimitPerIP    := 100;  // max 100 req/s per client IP — 429 on exceed
LServer.RateLimitGlobal   := 5000; // max 5000 req/s total — 429 on exceed
LServer.RateLimitResponse := 429;  // default; change to 503 if preferred
```

Default is `0` (unlimited) for both counters. The per-IP and global limits are
independent — a request is rejected if **either** limit is exceeded.

## WebSocket frame size (R-3)

```pascal
LServer.MaxWSFrameSize := 1 * 1024 * 1024;  // 1 MB — WS close code 1009 on exceed
```

See [websocket.md](../03-protocols/websocket.md#frame-size-limit-r-3) for details.

## Idle connection timeout

```pascal
LServer.IdleTimeoutMs := 30000;  // 30 s — default 10 000 ms; 0 = disabled
```

Connections with no inbound bytes for `IdleTimeoutMs` are closed.
The timer resets on every received byte, so long-running keep-alive connections
that are actively sending requests are not affected.

## Summary table

| Property | Default | Exceeded action |
|----------|---------|-----------------|
| `MaxRequestSize` | 8 MB | `413` |
| `MaxHeaderSize` | 64 KB | `400` |
| `MaxConnections` | 0 (∞) | socket dropped |
| `MaxConnectionsPerIP` | 0 (∞) | socket dropped |
| `MaxQueueDepth` | 0 (∞) | `503` |
| `RateLimitPerIP` | 0 (∞) | `429` (or `RateLimitResponse`) |
| `RateLimitGlobal` | 0 (∞) | `429` (or `RateLimitResponse`) |
| `MaxWSFrameSize` | 0 (∞) | WS close `1009` |
| `IdleTimeoutMs` | 10 000 ms | connection closed |
