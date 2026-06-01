# Worker threads e encerramento gracioso

O Poseidon despacha requisições para um pool de threads. O tamanho padrão é **200 workers**
(propriedade `WorkerCount` em `TPoseidonNativeServer`).

## Dimensionamento

```
workers = pico_de_requisições_simultâneas × (1 + avg_espera_ms / avg_cpu_ms)
```

### Por tipo de workload

| Workload | `WorkerCount` recomendado | Motivo |
|----------|--------------------------|--------|
| CPU-bound (em memória, sem I/O) | `nº de CPUs lógicas × 2` | Mais workers aumentam overhead de troca de contexto sem ganho de throughput |
| I/O-bound (queries no BD, APIs externas) | `pico_clientes_simultâneos × (1 + wait_ms / cpu_ms)` | Workers bloqueados seguram uma thread; mais threads = fila menor |
| Misto | Comece com `auto`; ajuste com o benchmark de escalonamento de workers | Deixe os dados decidirem |

### Evidência do benchmark — curva de escalonamento (latência DAO, 50 clientes simultâneos)

`RPS teórico máximo = workers × (1000 / DAO_ms)`. Resultados com 50 clientes simultâneos:

| Workers | DAO=5ms RPS | DAO=30ms RPS | DAO=100ms RPS | Observação |
|---------|-------------|--------------|---------------|------------|
| 4       | 664         | 130          | 40            | **Saturado** em todas as latências; corresponde à teoria (4×200=800, 4×33=133, 4×10=40) |
| 8       | 1 238       | 257          | 79            | Margem aparece; latência média cai abaixo de 50% do W=4 |
| auto    | 1 949       | 499          | 78            | Adapta-se à contagem de CPUs da máquina; tipicamente próximo do ótimo |
| 16      | 1 938       | 502          | 126           | Retorno decrescente em 5ms; ganho significativo em 100ms |
| 32      | 2 110       | 706          | 239           | Melhor RPS bruto em DAO alto; overhead de troca de contexto visível em 5ms |

Regra de diagnóstico: se `latência_média > 2 × handler_sleep_ms`, adicione mais workers.

Para handlers puramente em memória: `WorkerCount = número de CPUs × 2` é suficiente.
Para handlers que acessam banco de dados (I/O bloqueante): comece com `auto` e ajuste
para cima se `latência_média > 2 × DB_query_ms`.

> Para a matriz completa de escalonamento de workers (W=4…32 × DAO=5/30/100ms × concorrência=10/50),
> execute `Poseidon.Benchmark.Workers`, que gera relatórios HTML em `benchmark/bin/`.

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

### HTTP/2 e encerramento gracioso

Para conexões HTTP/2, `Stop` adicionalmente:

1. Envia um frame `GOAWAY` a cada conexão h2 ativa (último stream ID processado +
   código de erro `NO_ERROR`), dando aos clientes chance de reattempt em nova conexão.
2. Adia o fechamento TCP até que todos os streams ativos tenham terminado de enviar.
3. Após as respostas serem enviadas, realiza um TCP half-close (`SD_SEND` / `SHUT_WR`)
   para que o cliente leia os bytes ainda em trânsito antes de o socket ser encerrado.

Tudo isso é automático — nenhuma configuração adicional além de `DrainTimeoutMs`.

## Observações

- Workers são threads do SO, não green threads. Cada worker bloqueado mantém uma stack completa.
- A conclusão de I/O (accept, read, write) é tratada por uma thread de I/O separada.
- Se todos os workers estiverem ocupados, novas requisições ficam na fila do backlog da porta de conclusão do SO.
- `MaxQueueDepth` (padrão 0 = ilimitado) permite limitar o número de requisições em-flight e retornar 503 quando o limite é atingido — veja [limits-and-backpressure.md](limits-and-backpressure.md).
