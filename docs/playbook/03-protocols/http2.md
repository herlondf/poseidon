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

## Server Push (RFC 7540 §8.2)

HTTP/2 server push lets the server proactively send resources to the client
before they are requested. Assign the `OnH2Push` callback to enable push:

```pascal
LServer.OnH2Push :=
  procedure(const AReq: TPoseidonNativeRequest;
            var APushResources: TArray<TPoseidonPushResource>)
  var
    LCss: TPoseidonPushResource;
  begin
    // Only push the stylesheet when the main page is requested
    if AReq.Path = '/' then
    begin
      LCss.Path        := '/style.css';
      LCss.ContentType := 'text/css';
      LCss.Body        := TEncoding.UTF8.GetBytes('body { font-family: sans-serif; }');
      LCss.Extra       := [];
      APushResources   := [LCss];
    end;
  end;
```

The callback receives the current request and may populate `APushResources` with
zero or more `TPoseidonPushResource` records. For each entry Poseidon will:

1. Send a `PUSH_PROMISE` frame on the client's stream.
2. Send `HEADERS + DATA` on a new server-initiated (even) stream.
3. Then send the normal response for the original request.

Push is only performed when the client's `SETTINGS_ENABLE_PUSH` is non-zero
(clients may disable push at any time). When `OnH2Push` is `nil` (default),
no push is attempted.

### TPoseidonPushResource fields

| Field | Type | Description |
|-------|------|-------------|
| `Path` | `string` | Path of the promised resource (e.g. `'/style.css'`) |
| `ContentType` | `string` | `Content-Type` of the pushed response |
| `Body` | `TBytes` | Full response body |
| `Extra` | `TArray<TPair<string,string>>` | Additional response headers |

## Known limitations

- HPACK: headers are sent as literals without indexing (correct, not optimal).

## See also

- [HTTP/2 Flow Control](http2-flow-control.md) — per-stream and connection windows
- [HTTP/2 Cleartext Upgrade (h2c)](h2c-upgrade.md) — detailed h2c protocol flow
- [Recipe: HTTP/2 Server Push](../05-recipes/http2-server-push.md) — full worked example
