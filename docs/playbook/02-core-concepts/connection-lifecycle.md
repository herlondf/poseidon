# Connection lifecycle

## Phases

```
TCP accept
    ↓
[Proxy Protocol parse]   — if ProxyProtocol ≠ ppDisabled
    ↓
[TLS handshake]          — if SSL configured
    ↓
[ALPN negotiation]       — h2 or http/1.1
    ↓
Request accumulation     — bytes arrive via recv/IOCP
    ↓
Request dispatch         — handler callback (worker thread)
    ↓
Response send            — single WSASend / send
    ↓
[Keep-alive: back to request accumulation]
    ↓
Connection close         — idle timeout / Connection: close / GOAWAY
    ↓
Ref-count drops to 0     — TNativeConn freed
```

## TNativeConn (ref-counted lifetime)

Each connection is represented by a `TNativeConn` object with a `FRefCount`
integer managed by `AddRef`/`Release`. The server holds one reference from accept
to close; each in-flight IOCP operation holds an additional reference for its
duration. The object is freed when the count reaches zero — never while an IOCP
packet is queued.

## Idle sweep

A background thread (`FIdleSweepThread`) scans all connections every 5 seconds.
Any connection whose `LastActivity` timestamp is older than `IdleTimeoutMs`
(default 10 000 ms) is closed. The timer resets on every inbound byte.

Set `IdleTimeoutMs := 0` to disable the sweep entirely.

## Keep-alive

HTTP/1.1 connections with `Connection: keep-alive` reuse the same TCP connection
for multiple requests. The accumulation buffer (`AccumBuf`) is kept alive between
requests and reused without reallocation.

## Upgrade to WebSocket / HTTP/2

When the dispatcher detects a WebSocket upgrade (`Upgrade: websocket`) or an h2c
upgrade (`Upgrade: h2c`), it transitions the connection to the respective protocol
handler. After the upgrade, the `TNativeConn` is no longer used for HTTP/1.1
dispatch and is driven by `TWebSocketConn` or `TH2Conn` instead.
