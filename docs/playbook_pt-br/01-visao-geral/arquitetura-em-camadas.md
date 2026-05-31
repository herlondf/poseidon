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
│  Poseidon.Net.ResponseBuilder                  │  montagem de resposta pré-codificada
│  Poseidon.Net.WebSocket                        │  codec de frames WS (zero-copy)
│  Poseidon.Net.HTTP2                            │  ALPN h2 + h2c + flow control
│  Poseidon.Net.SSL                              │  bindings OpenSSL + SNI
│  Poseidon.Net.Security                         │  helpers de validação de entrada
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
`ResponseBuilder` depende apenas de `Pool.Buffer` e `Security` — sem tipos do servidor.
