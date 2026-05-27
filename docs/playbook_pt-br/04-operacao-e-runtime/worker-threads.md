# Worker threads

O Poseidon despacha requisições para um pool de threads. O tamanho padrão é **200 workers**
(propriedade `WorkerCount` em `TPoseidonNativeServer`).

## Dimensionamento

```
workers = pico_de_requisições_simultâneas × (1 + avg_espera_ms / avg_cpu_ms)
```

Para handlers puramente em memória: `WorkerCount = número de CPUs × 2` é suficiente.
Para handlers que acessam banco de dados (I/O bloqueante): mantenha o padrão 200 ou iguale ao tamanho do pool de conexões.

## Alterando o número de workers

Deve ser definido **antes** de `Listen`:

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.WorkerCount := 50;
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

## Observações

- Workers são threads do SO, não green threads. Cada worker bloqueado mantém uma stack completa.
- A conclusão de I/O (accept, read, write) é tratada por uma thread de I/O separada.
- Se todos os workers estiverem ocupados, novas requisições ficam na fila do backlog da porta de conclusão do SO.
