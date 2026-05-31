# HTTP/2 Flow Control

Poseidon implements the full RFC 7540 §6.9 flow-control model for HTTP/2 connections.

## Overview

Flow control prevents a fast sender from overwhelming a slow receiver.
HTTP/2 maintains two independent windows:

| Window | Scope | Initial value |
|--------|-------|--------------|
| Connection send window | All streams on one connection | 65 535 bytes |
| Stream send window | Individual stream | Peer's `INITIAL_WINDOW_SIZE` (default 65 535) |

A DATA frame may only be sent when **both** windows are positive and the frame
fits within the peer's `MAX_FRAME_SIZE`.

## Receive-side: automatic WINDOW_UPDATE

When Poseidon delivers a request body to the application, it decrements the
per-stream and per-connection receive windows.
Once either window drops below 50 % of the initial size, Poseidon automatically
sends a `WINDOW_UPDATE` frame to restore the full window.

```
Initial window   = 65 535
50 % threshold   = 32 767
WINDOW_UPDATE credit = initial − current
```

No application code is required.

## Send-side: backpressure

When `SendResponse` has more bytes to send than the available window allows,
the remainder is buffered in the stream's `PendingBody`.
Transmission resumes automatically when the peer sends a `WINDOW_UPDATE` frame.

```
stream send window: 16 384
response body:      100 000 bytes

→ send first 16 384 bytes immediately
→ buffer remaining 83 616 bytes in PendingBody
→ peer WINDOW_UPDATE(32 768) arrives
→ send next 32 768 bytes, buffer 50 848 remaining
→ ...
```

The stream object is kept alive in `FStreams` until all pending bytes are flushed.

## SETTINGS negotiation

Poseidon sends its preferred values in the initial SETTINGS frame.
You can configure them via server properties:

```pascal
LServer.H2MaxConcurrentStreams := 128;   // SETTINGS_MAX_CONCURRENT_STREAMS
LServer.H2InitialWindowSize    := 65535; // SETTINGS_INITIAL_WINDOW_SIZE
```

When a peer SETTINGS changes `INITIAL_WINDOW_SIZE`, Poseidon updates every
existing stream's send window by the delta (positive or negative) and checks for
overflow (RFC 7540 §6.9.2).

## Limits

- Maximum frame size sent respects the peer's `SETTINGS_MAX_FRAME_SIZE`.
- Receive window tracks the per-stream body independently of the connection window.
- A `WINDOW_UPDATE` with increment 0 is rejected with `PROTOCOL_ERROR`.
- A window overflow (> 2³¹ − 1) is rejected with `FLOW_CONTROL_ERROR`.
