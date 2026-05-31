# HTTP/2

Poseidon implements HTTP/2 (RFC 7540) with HPACK header compression (RFC 7541).
HTTP/2 can be used in two modes:

| Mode | How | Requirement |
|------|-----|-------------|
| **h2** (encrypted) | ALPN negotiation during TLS handshake | Requires SSL |
| **h2c** (cleartext) | HTTP/1.1 `Upgrade: h2c` mechanism | No SSL needed |

## Enabling h2 (over TLS)

```pascal
LServer.HTTP2Enabled := True;   // must be set before ConfigureSSL
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

When a client connects and negotiates `"h2"` via ALPN, Poseidon creates a `TH2Conn`
instance to handle the connection. HTTP/1.1 clients connecting to the same port continue
to work normally.

## Enabling h2c (cleartext upgrade)

h2c requires no configuration. Any plain-TCP connection that sends a valid
`Upgrade: h2c` + `HTTP2-Settings` header is automatically upgraded:

```pascal
LServer.Listen('0.0.0.0', 8080, @HandleRequest, nil);
// a client sending Upgrade: h2c is transparently promoted to HTTP/2
```

## SETTINGS negotiation

Configure the values sent to the client in the initial SETTINGS frame:

```pascal
LServer.H2MaxConcurrentStreams := 200;    // SETTINGS_MAX_CONCURRENT_STREAMS (default 100)
LServer.H2InitialWindowSize    := 65535;  // SETTINGS_INITIAL_WINDOW_SIZE (default 65535)
```

Both properties must be set before `Listen`.

## Application handler

The request handler signature is the same for both HTTP/1.1 and HTTP/2.
Poseidon maps HTTP/2 pseudo-headers (`:method`, `:path`, `:authority`) to the
`TPoseidonNativeRequest` fields (`Method`, `Path`, `Host`).

## Limitations

- **Server Push** is not implemented (`ENABLE_PUSH = 0` in SETTINGS).
- HPACK: headers are sent as literals without indexing (correct, not optimal).

## See also

- [HTTP/2 Flow Control](http2-flow-control.md) — per-stream and connection windows
- [HTTP/2 Cleartext Upgrade (h2c)](h2c-upgrade.md) — detailed h2c protocol flow
