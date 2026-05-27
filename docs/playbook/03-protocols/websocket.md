# WebSocket

WebSocket handlers are registered per-path via `RegisterWSHandler`.
The same server instance handles both HTTP and WebSocket traffic on the same port.

## Registering a handler

```pascal
uses Poseidon.Net.WebSocket;

LServer.RegisterWSHandler('/ws',
  procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
  begin
    if AFrame.Opcode = OPCODE_TEXT then
      AConn.Send('echo: ' + TEncoding.UTF8.GetString(AFrame.Payload))
    else if AFrame.Opcode = OPCODE_BINARY then
      AConn.SendBinary(AFrame.Payload)
    else if AFrame.Opcode = OPCODE_CLOSE then
      AConn.Close(1000);
  end);
```

## TWebSocketFrame fields

| Field | Type | Description |
|-------|------|-------------|
| `Opcode` | `Byte` | Frame type — use the `OPCODE_*` constants |
| `Payload` | `TBytes` | Raw frame payload |
| `FinFlag` | `Boolean` | True when this is the final fragment |

## OPCODE constants

| Constant | Value | Meaning |
|----------|-------|---------|
| `OPCODE_TEXT`   | `$1` | UTF-8 text message |
| `OPCODE_BINARY` | `$2` | Binary message |
| `OPCODE_CLOSE`  | `$8` | Close handshake |
| `OPCODE_PING`   | `$9` | Ping (handled automatically) |
| `OPCODE_PONG`   | `$A` | Pong (handled automatically) |

## IPoseidonWSConn methods

| Method | Description |
|--------|-------------|
| `Send(AText: string)` | Send a UTF-8 text frame |
| `SendBinary(AData: TBytes)` | Send a binary frame |
| `Close(ACode: Word = 1000)` | Send close frame and tear down the connection |
| `RemoteAddr: string` | Remote IP address (read-only property) |
| `Closed: Boolean` | True if the connection is already closed (read-only property) |

## Working with text payloads

`Payload` is always `TBytes`. Decode to string explicitly:

```pascal
LText := TEncoding.UTF8.GetString(AFrame.Payload);
```

## Notes

- Ping frames are answered automatically with Pong — your handler is not called for Ping.
- Close frames: call `AConn.Close(1000)` to complete the handshake. After this call, the
  connection is torn down and any further send on `AConn` is a no-op.
- The handler is called from a worker thread; shared state must be protected.
- `TWebSocketUtils` exposes the raw protocol helpers (`ParseFrame`, `BuildFrame`,
  `HandshakeAccept`) if you need lower-level control.
