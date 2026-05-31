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

## TCP half-close on shutdown (R-6)

When `_CloseConn` is called, Poseidon performs a **TCP half-close** before
`closesocket` / `close(fd)`:

```
shutdown(socket, SD_SEND / SHUT_WR)   — stop sending; peer can still read
closesocket / close(fd)                — tear down after peer drains
```

`SD_SEND` (Windows) / `SHUT_WR` (Linux) signals to the remote peer that no more
data will be sent, but the socket remains open for reading. This allows the client
to receive any bytes already in the kernel send buffer before the connection is fully
torn down — preventing silent data loss on abrupt shutdowns.

This behaviour is automatic and requires no configuration.

## HTTP/2 GOAWAY on shutdown (R-2)

When the server is stopped while an HTTP/2 connection is active, Poseidon sends a
`GOAWAY` frame before closing the socket. `GOAWAY` carries the last processed
stream ID and a `NO_ERROR` code, signalling to the client that it may safely retry
streams with IDs higher than the last-processed one on a new connection.

The close callback (`FCloseProc`) is deferred until all active streams have finished
sending their responses. If `DrainTimeoutMs` expires first, the connection is closed
unconditionally.

## Upgrade to WebSocket / HTTP/2

When the dispatcher detects a WebSocket upgrade (`Upgrade: websocket`) or an h2c
upgrade (`Upgrade: h2c`), it transitions the connection to the respective protocol
handler. After the upgrade, the `TNativeConn` is no longer used for HTTP/1.1
dispatch and is driven by `TWebSocketConn` or `TH2Conn` instead.
