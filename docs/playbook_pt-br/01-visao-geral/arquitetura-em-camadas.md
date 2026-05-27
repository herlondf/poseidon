# Arquitetura em camadas

```
┌──────────────────────────────────────────────┐
│  Consumidor (Pegasus / Horse / sua app)       │
│  TAsyncIONativeServer.Listen(host, port, cb)  │
└───────────────────┬──────────────────────────┘
                    │ callback: HandleRequest
┌───────────────────▼──────────────────────────┐
│  Adaptadores de protocolo                     │
│  AsyncIO.Net.WebAdapters.Native               │  bridge WebBroker
│  AsyncIO.Net.WebSocket                        │  codec de frames WS
│  AsyncIO.Net.HTTP2                            │  negociação ALPN h2
│  AsyncIO.Net.SSL                              │  bindings OpenSSL + SNI
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Pools de memória                             │
│  AsyncIO.Net.Pool.Buffer   (TBufferPool)      │  buffers lock-free
│  AsyncIO.Net.Pool.Native   (TNativeContextPool│  adaptadores por requisição
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Servidor core — AsyncIO.Net.HttpServer       │
│  TAsyncIONativeServer                         │
│  Apenas syscalls epoll (Linux) / IOCP (Win)   │
└──────────────────────────────────────────────┘
```

**Regra**: cada camada só pode depender de camadas abaixo dela.
`HttpServer` não importa nada de adaptadores ou pools.
`SSL` e `HTTP2` podem importar tipos do `HttpServer`, mas não das camadas de adaptadores.
