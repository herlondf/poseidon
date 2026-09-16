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

## Esgotamento do Tier 2 (#245)

O Tier 2 tem só 16 slots **globais** (compartilhados por todas as threads)
pra buffers de 512 KB — o tier que mais importa pra respostas grandes. Se
isso de fato esgota sob tráfego real de resposta grande (em vez de só ser
teoricamente possível) era uma pergunta em aberto, não um problema
confirmado: subir `POOL_TIER2_MAX` ou adicionar um Tier 3 sem evidência
seria um chute de ajuste não validado.

`TBufferPool.Tier2ExhaustedCount` e `.OversizedCount` respondem isso
diretamente — também expostos como contadores Prometheus
(`poseidon_bufferpool_tier2_exhausted_total`,
`poseidon_bufferpool_oversized_total` — veja [metrics.md](metrics.md)):

- **`Tier2ExhaustedCount`** subindo sob carga significa que uma resposta que
  *deveria* ter sido pooled não foi — tanto o cache local da thread quanto
  a stack global do Tier 2 estavam vazios, caindo pra um `SetLength` de
  heap. Esse é o sinal de verdade pra subir `POOL_TIER2_MAX` ou adicionar
  um Tier 3.
- **`OversizedCount`** é requisições acima de 512 KB, que bypassam o pool
  *por design* (veja a tabela de tiers acima) — não é um problema de
  dimensionamento por si só, mostrado junto do `Tier2ExhaustedCount` só
  como contexto (um `OversizedCount` grande pode significar que o tamanho
  das suas respostas pertence a um tier maior por completo, não que o
  Tier 2 precisa de mais slots).

Veja [Conceitos Core — Pool de buffers](../../02-conceitos-core/pool-de-buffers.md) para a visão conceitual.
