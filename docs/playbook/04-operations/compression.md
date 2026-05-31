# Compression

Poseidon supports inline gzip compression for HTTP/1.1 responses.
Compression is **disabled by default** (CPU-expensive — opt-in).

## Enabling gzip

```pascal
LServer.CompressionEnabled := True;
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

When enabled, responses with a text-like `Content-Type` and a body > 1 KB are
automatically compressed with gzip **if** the client sent `Accept-Encoding: gzip`.

The compressed response includes the `Content-Encoding: gzip` header. The
`Content-Length` header reflects the compressed size.

## Eligibility

A response is compressed when all of the following are true:

| Condition | Detail |
|-----------|--------|
| `CompressionEnabled = True` | Opt-in at server level |
| Client sent `Accept-Encoding: gzip` | Read from the request header |
| Body size > 1 KB | Smaller bodies are not worth compressing |
| `Content-Type` starts with `text/` or is `application/json` | Binary responses are not compressed |

## ICompressionProvider (dependency injection)

Compression is backed by `ICompressionProvider`, which can be replaced:

```pascal
// nil → built-in ZLib gzip (TDefaultCompressionProvider)
LServer := TPoseidonNativeServer.Create(nil, nil, nil);

// Custom provider (e.g., Brotli or a mock in tests)
LServer := TPoseidonNativeServer.Create(nil, nil, TBrotliCompressionProvider.Create);
```

The `ICompressionProvider` interface:

```pascal
ICompressionProvider = interface
  function IsAvailable: Boolean;
  function TryCompress(const AInput: TBytes;
    const AAcceptEncoding: string;
    out AOutput:   TBytes;
    out AEncoding: string): Boolean;
end;
```

`TryCompress` receives the full `Accept-Encoding` header value and negotiates the
best available encoding. Return `False` to signal that no compression was applied.

## Notes

- Compression is synchronous on the worker thread — large bodies block the worker.
- HTTP/2 responses are not compressed by the server (clients typically handle this).
- For maximum throughput, pre-compress static responses offline and serve them directly.
