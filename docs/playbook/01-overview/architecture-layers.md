# Architecture layers

```
┌──────────────────────────────────────────────┐
│  Consumer (Pegasus / Horse / your app)        │
│  TAsyncIONativeServer.Listen(host, port, cb)  │
└───────────────────┬──────────────────────────┘
                    │ callback: HandleRequest
┌───────────────────▼──────────────────────────┐
│  Protocol adapters                            │
│  AsyncIO.Net.WebAdapters.Native               │  WebBroker bridge
│  AsyncIO.Net.WebSocket                        │  WS frame codec
│  AsyncIO.Net.HTTP2                            │  h2 ALPN negotiation
│  AsyncIO.Net.SSL                              │  OpenSSL bindings + SNI
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Memory pools                                 │
│  AsyncIO.Net.Pool.Buffer   (TBufferPool)      │  lock-free byte buffers
│  AsyncIO.Net.Pool.Native   (TNativeContextPool│  per-request adapters
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Core server  — AsyncIO.Net.HttpServer        │
│  TAsyncIONativeServer                         │
│  epoll (Linux) / IOCP (Windows) syscalls only │
└──────────────────────────────────────────────┘
```

**Rule**: each layer may only depend on layers below it.
`HttpServer` has zero imports from adapters or pools.
`SSL` and `HTTP2` may import `HttpServer` types but not adapter layers.
