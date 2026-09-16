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

## Header completion deadline / Slowloris guard (#254)

`IdleTimeoutMs` resets on **every** received byte, including a single byte of
a still-incomplete request. That is exactly the classic Slowloris attack
(2009, against Apache): open many connections and trickle one byte every few
seconds — none of them ever go idle long enough to hit `IdleTimeoutMs`, so
none are ever closed, for the cost of near-zero bandwidth per connection.

```pascal
LServer.HeaderTimeoutMs := 10000;  // 0 = disabled (default)
```

This is a separate, **absolute** deadline measured from connection open, not
reset by partial activity — mirroring nginx's `client_header_timeout`. It
only applies until the connection's first request has a complete request line
+ headers; from then on the connection is governed by `IdleTimeoutMs` as
usual for the rest of its keep-alive life. Pair this with
`MaxConnectionsPerIP` (also `0`/unlimited by default) for real Slowloris
resistance — a header deadline alone still lets one IP hold many slow
connections open simultaneously, just not indefinitely.

This is opt-in (default `0`, disabled) for the same reason as
`MaxHandlerRunMs` below: existing deployments keep today's behavior unless set
explicitly.

## Stuck handler watchdog (#233)

None of the limits above protect against a handler that is genuinely stuck —
blocked forever on a slow/unresponsive outbound dependency (a webservice, a
database), not merely slow. `Poseidon.Middleware.Timeout` cannot help here
either: it is a post-execution check (see [middlewares](../09-middlewares/README.md#6-timeout))
that only measures a handler AFTER it returns.

```pascal
LServer.MaxHandlerRunMs := 60000;  // 0 = disabled (default)
```

When a connection's in-flight handler has been running longer than
`MaxHandlerRunMs`, the idle-sweep logs a warning and closes the connection —
the same "leak the resource instead of freeing it" pattern used at shutdown
(never kills the worker thread itself, since Delphi has no safe way to abort
a thread mid-native-call). The stuck worker eventually finishes on its own
(possibly much later) and its `finally` still runs, releasing its reference
normally; the client just does not wait for it — it sees the connection drop
immediately and can retry against a fresh connection/instance.

This is opt-in (default `0`, disabled) so existing deployments keep today's
behavior unless set explicitly. Pick a value above your slowest legitimate
handler's p99, not your median — this is a backstop against being stuck
forever, not a general request timeout (use `Poseidon.Middleware.Timeout` or
an explicit timeout on the outbound client for that).

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
| `HeaderTimeoutMs` | 0 (disabled) | connection closed (Slowloris guard) |
| `MaxHandlerRunMs` | 0 (disabled) | connection closed (handler leaked, not killed) |
