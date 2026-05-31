# Limites e backpressure

O Poseidon oferece limites configuráveis que protegem contra esgotamento de recursos
e permitem degradação controlada sob carga.

## Limites de tamanho de requisição (R-4)

```pascal
LServer.MaxRequestSize := 4 * 1024 * 1024;  // 4 MB — 413 se excedido
LServer.MaxHeaderSize  := 32768;             // 32 KB — 400 se excedido
```

Veja [http1.md](../03-protocolos/http1.md#limites-de-tamanho-de-requisição-e-headers-r-4) para detalhes.

## Limites de conexão

```pascal
LServer.MaxConnections      := 10000;  // limite global — socket descartado se excedido
LServer.MaxConnectionsPerIP := 100;    // limite por IP — socket descartado se excedido
```

O padrão é `0` (ilimitado) para ambos. Quando o limite é atingido, o socket entrante
é fechado imediatamente sem resposta HTTP.

## Profundidade de fila / backpressure (R-5)

`MaxQueueDepth` limita o número de requisições sendo processadas simultaneamente.
Quando o limite é atingido, o servidor retorna `503 Service Unavailable` em vez de
enfileirar mais trabalho.

```pascal
LServer.MaxQueueDepth := 500;  // 0 = ilimitado (padrão)
```

Use em conjunto com `WorkerCount`: `MaxQueueDepth` é o portão de aceitação
(caminho rápido), `WorkerCount` é a capacidade de processamento (caminho lento).

## Rate limiting

Contadores de janela fixa que reiniciam a cada segundo.

```pascal
LServer.RateLimitPerIP    := 100;  // máx 100 req/s por IP cliente — 429 se excedido
LServer.RateLimitGlobal   := 5000; // máx 5000 req/s global — 429 se excedido
LServer.RateLimitResponse := 429;  // padrão; altere para 503 se preferir
```

O padrão é `0` (ilimitado) para ambos os contadores. Os limites por IP e global são
independentes — uma requisição é rejeitada se **qualquer** limite for excedido.

## Tamanho de frame WebSocket (R-3)

```pascal
LServer.MaxWSFrameSize := 1 * 1024 * 1024;  // 1 MB — código WS 1009 se excedido
```

Veja [websocket.md](../03-protocolos/websocket.md#limite-de-tamanho-de-frame-r-3) para detalhes.

## Timeout de conexão ociosa

```pascal
LServer.IdleTimeoutMs := 30000;  // 30 s — padrão 10 000 ms; 0 = desabilitado
```

Conexões sem bytes recebidos por `IdleTimeoutMs` são fechadas.
O timer é reiniciado a cada byte recebido, portanto conexões keep-alive ativas não são afetadas.

## Tabela resumo

| Propriedade | Padrão | Ação ao exceder |
|-------------|--------|-----------------|
| `MaxRequestSize` | 8 MB | `413` |
| `MaxHeaderSize` | 64 KB | `400` |
| `MaxConnections` | 0 (∞) | socket descartado |
| `MaxConnectionsPerIP` | 0 (∞) | socket descartado |
| `MaxQueueDepth` | 0 (∞) | `503` |
| `RateLimitPerIP` | 0 (∞) | `429` (ou `RateLimitResponse`) |
| `RateLimitGlobal` | 0 (∞) | `429` (ou `RateLimitResponse`) |
| `MaxWSFrameSize` | 0 (∞) | WS close `1009` |
| `IdleTimeoutMs` | 10 000 ms | conexão fechada |
