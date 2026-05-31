# Pool de buffers (conceito)

O Poseidon usa um pool multi-tier para evitar alocações heap por requisição.
Cada slot é um `TBytes` pré-alocado mantido em uma `TStack` com guarda de lock.

## Tiers

| Tier | Tamanho | Uso |
|------|---------|-----|
| 0 | 8 KB | Buffer de acumulação da conexão, requisições pequenas |
| 1 | 64 KB | Requisições médias / uploads |
| 2 | 512 KB | Respostas grandes / streaming |

`Acquire(ASize)` retorna o menor tier ≥ `ASize`.
`Release` devolve o buffer ao tier correto pelo seu comprimento.

Para detalhes de implementação e uso avançado veja
[04-operacao-e-runtime/buffer-pool.md](../04-operacao-e-runtime/buffer-pool.md).
