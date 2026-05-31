# Pool de buffers

O Poseidon usa um pool multi-tier (`TBufferPool`) para evitar alocações heap por requisição
para buffers de I/O e respostas HTTP.

## Tiers

| Tier | Tamanho do slot | Slots no pool | Uso típico |
|------|-----------------|---------------|------------|
| 0 | 8 KB | 256 | Buffer inicial de conexão, requisições pequenas, ping WebSocket |
| 1 | 64 KB | 64 | Requisições médias, uploads |
| 2 | 512 KB | 16 | Respostas grandes, streaming |
| Heap | tamanho exato | — | Oversized (> 512 KB) — bypassa o pool |

## Como funciona

`TBufferPool.Acquire(ASize)` retorna o menor tier cujo tamanho de slot ≥ `ASize`.
`TBufferPool.Release(var ABuf)` detecta o tier pelo comprimento do buffer e o devolve
à stack correta. Ambas as operações são protegidas por `TMonitor`.

```pascal
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(1024);   // retorna um slot de 8 KB
  try
    // ... usar LBuf[0..1023] ...
  finally
    TBufferPool.Release(LBuf);         // devolvido ao tier 0
  end;
end;
```

## Builder de resposta HTTP com pool (P-4)

O caminho principal em `TProtocolDispatcher` usa `BuildHTTPResponsePooled` ao invés
do `BuildHTTPResponse` convencional. Isso escreve a resposta HTTP completa (status +
headers + body) diretamente em um buffer do pool com chamadas `Move()`, evitando as
alocações intermediárias de `TStringBuilder` e `TEncoding.UTF8.GetBytes`.

## Injeção de dependência

O pool é exposto como `IBufferPool` e pode ser substituído em testes:

```pascal
// Produção: nil seleciona TBufferPool (pool multi-tier embutido)
LServer := TPoseidonNativeServer.Create(nil, nil, nil);

// Testes: injeta um mock
LServer := TPoseidonNativeServer.Create(TMeuMockBufferPool.Create, nil, nil);
```

Veja [Conceitos Core — Pool de buffers](../../02-conceitos-core/pool-de-buffers.md) para a visão conceitual.
