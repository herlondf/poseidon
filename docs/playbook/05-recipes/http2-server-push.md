# Recipe: HTTP/2 Server Push

HTTP/2 server push (RFC 7540 §8.2) lets the server send resources to the client
**before** they are requested, eliminating a round-trip for critical assets.

## When to use it

- HTML page that always needs a CSS file or a JavaScript bundle.
- API response that always includes a related resource.
- Any case where you know in advance what the client will request next.

Do **not** push resources that clients already have cached; modern clients send a
`Cache-Digest` or simply disable push via `SETTINGS_ENABLE_PUSH = 0`.

## Minimal example

```pascal
uses
  Poseidon.Net.HttpServer,
  Poseidon.Net.Types;

procedure HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
begin
  AStatus      := 200;
  AContentType := 'text/html';
  ABody        := TEncoding.UTF8.GetBytes(
    '<html><head><link rel="stylesheet" href="/style.css"></head>' +
    '<body><h1>Hello!</h1></body></html>');
end;

procedure HandlePush(
  const AReq:           TPoseidonNativeRequest;
  var   APushResources: TArray<TPoseidonPushResource>);
var
  LCss: TPoseidonPushResource;
begin
  if AReq.Path = '/' then
  begin
    LCss.Path        := '/style.css';
    LCss.ContentType := 'text/css';
    LCss.Body        := TEncoding.UTF8.GetBytes('body { margin: 0; }');
    LCss.Extra       := [];
    APushResources   := [LCss];
  end;
end;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  LServer.HTTP2Enabled := True;
  LServer.ConfigureSSL('server.crt', 'server.key');
  LServer.OnH2Push := HandlePush;   // <- wire up push
  LServer.Listen('0.0.0.0', 443, HandleRequest, nil);
end;
```

## How it works

For each request, Poseidon calls `OnH2Push` **before** sending the response.
The callback may populate `APushResources` with any number of resources.
For each resource:

1. A `PUSH_PROMISE` frame is sent on the client's stream (announces the push).
2. `HEADERS + DATA` frames are sent on a new server-initiated (even) stream ID.
3. The normal response for the original request follows.

The wire sequence looks like:

```
client → HEADERS  (stream 1, GET /)
server ← PUSH_PROMISE (stream 1, promised stream 2, :path /style.css)
server ← HEADERS  (stream 2, 200 text/css)
server ← DATA     (stream 2, CSS body, END_STREAM)
server ← HEADERS  (stream 1, 200 text/html)
server ← DATA     (stream 1, HTML body, END_STREAM)
```

## TPoseidonPushResource reference

| Field | Type | Description |
|-------|------|-------------|
| `Path` | `string` | URL path of the pushed resource (e.g. `'/app.js'`) |
| `ContentType` | `string` | `Content-Type` value for the push response |
| `Body` | `TBytes` | Full body of the push response |
| `Extra` | `TArray<TPair<string,string>>` | Optional extra response headers |

## Caveats

- Push only works over **h2** (TLS + ALPN). h2c upgrade connections also support push.
- A client may send `SETTINGS_ENABLE_PUSH = 0` to disable push at any time.
  Poseidon honours this and stops calling `_SendPushPromiseAndResponse` automatically.
- Only push resources that are small and always needed — large or conditional pushes
  waste bandwidth when the client already has the resource cached.
- Each pushed resource consumes a server-initiated stream ID (even numbers: 2, 4, 6 …).
  These are separate from client-initiated streams (odd numbers).

## See also

- [HTTP/2](../03-protocols/http2.md) — general HTTP/2 configuration
- [HTTP/2 Flow Control](../03-protocols/http2-flow-control.md) — window management
- [Sample: 07-http2-server-push](../../../samples/07-http2-server-push/)
