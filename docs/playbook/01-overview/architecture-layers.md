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
│  Poseidon.Net.WebSocket                        │  WS frame codec
│  Poseidon.Net.HTTP2                            │  h2 ALPN negotiation
│  Poseidon.Net.SSL                              │  OpenSSL bindings + SNI
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
