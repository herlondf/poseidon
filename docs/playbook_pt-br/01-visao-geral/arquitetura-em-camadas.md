# Arquitetura em camadas

```
┌──────────────────────────────────────────────┐
│  Consumidor (Pegasus / Horse / sua app)       │
│  TPoseidonNativeServer.Listen(host, port, cb)  │
└───────────────────┬──────────────────────────┘
                    │ callback: HandleRequest
┌───────────────────▼──────────────────────────┐
│  Adaptadores de protocolo                     │
│  Poseidon.Net.WebAdapters.Native               │  bridge WebBroker
│  Poseidon.Net.WebSocket                        │  codec de frames WS
│  Poseidon.Net.HTTP2                            │  negociação ALPN h2
│  Poseidon.Net.SSL                              │  bindings OpenSSL + SNI
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Pools de memória                             │
│  Poseidon.Net.Pool.Buffer   (TBufferPool)      │  buffers lock-free
│  Poseidon.Net.Pool.Native   (TNativeContextPool│  adaptadores por requisição
└───────────────────┬──────────────────────────┘
                    │
┌───────────────────▼──────────────────────────┐
│  Servidor core — Poseidon.Net.HttpServer       │
│  TPoseidonNativeServer                         │
│  Apenas syscalls epoll (Linux) / IOCP (Win)   │
└──────────────────────────────────────────────┘
```

**Regra**: cada camada só pode depender de camadas abaixo dela.
`HttpServer` não importa nada de adaptadores ou pools.
`SSL` e `HTTP2` podem importar tipos do `HttpServer`, mas não das camadas de adaptadores.
