# Architecture layers

```
┌──────────────────────────────────────────────┐
│  Consumer (Pegasus / Horse / your app)        │
│  TPoseidonNativeServer.Listen(host, port, cb)  │
└───────────────────┬──────────────────────────┘
                    │ callback: HandleRequest
┌───────────────────▼──────────────────────────┐
│  Protocol adapters                            │
│  Poseidon.Net.WebAdapters.Native               │  WebBroker bridge
│  Poseidon.Net.ResponseBuilder                  │  pre-encoded response assembly
│  Poseidon.Net.WebSocket                        │  WS frame codec (zero-copy)
│  Poseidon.Net.HTTP2                            │  h2 ALPN + h2c + flow control
│  Poseidon.Net.SSL                              │  OpenSSL bindings + SNI
│  Poseidon.Net.Security                         │  input validation helpers
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Memory pools                                 │
│  Poseidon.Net.Pool.Buffer   (TBufferPool)      │  lock-free byte buffers
│  Poseidon.Net.Pool.Native   (TNativeContextPool│  per-request adapters
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Core server  — Poseidon.Net.HttpServer        │
│  TPoseidonNativeServer                         │
│  epoll (Linux) / IOCP (Windows) syscalls only │
└──────────────────────────────────────────────┘
```

**Rule**: each layer may only depend on layers below it.
`HttpServer` has zero imports from adapters or pools.
`SSL` and `HTTP2` may import `HttpServer` types but not adapter layers.
`ResponseBuilder` depends only on `Pool.Buffer` and `Security` — no server types.
