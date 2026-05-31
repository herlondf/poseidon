# Worker threads e encerramento gracioso

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

## Encerramento gracioso (R-1)

`Stop` aguarda todas as requisições em-flight terminarem antes de retornar.
Usa um evento interno (sem busy-wait / Sleep) para que a thread chamadora bloqueie
eficientemente até o drain completar ou o timeout expirar.

```pascal
LServer.DrainTimeoutMs := 15000;  // padrão 30 000 ms
LServer.Stop;
// retorna quando todas as requisições em-flight terminaram, ou após DrainTimeoutMs
```

`DrainTimeoutMs` deve ser definido antes de `Listen` (é lido uma vez na inicialização).

### Padrão típico de shutdown

```pascal
// em um signal handler ou encerramento da aplicação:
LServer.Stop;
LServer.Free;
```

## Observações

- Workers são threads do SO, não green threads. Cada worker bloqueado mantém uma stack completa.
- A conclusão de I/O (accept, read, write) é tratada por uma thread de I/O separada.
- Se todos os workers estiverem ocupados, novas requisições ficam na fila do backlog da porta de conclusão do SO.
- `MaxQueueDepth` (padrão 0 = ilimitado) permite limitar o número de requisições em-flight e retornar 503 quando o limite é atingido — veja [limits-and-backpressure.md](limits-and-backpressure.md).
