# Benchmark de Throughput

O benchmark executável está em [`samples/08-benchmark/`](../../../samples/08-benchmark/).

## O que é medido

| Cenário | Conexões | Requisições | Observação |
|---------|----------|-------------|-----------|
| A — keep-alive | 50 persistentes | 1 000 por worker | Uma conexão TCP por worker, 50 000 no total |
| B — nova conexão | 50 × nova | 200 por worker | Novo handshake TCP a cada requisição, 10 000 no total |

Métricas reportadas: **throughput** (req/s), **P50** e **P99** de latência (ms).

## Execução

```
cd samples\08-benchmark
# Compilar em modo Release, depois:
bin\Release\Poseidon.Sample.Benchmark.exe
```

Exemplo de saída:

```
Poseidon Sample 08 — HTTP/1.1 Throughput Benchmark
Server: 127.0.0.1:9090   Workers: 200
──────────────────────────────────────────────────────────────────────────────
Cenário                         Requisições  Throughput    P50 Latência  P99 Latência
──────────────────────────────────────────────────────────────────────────────
A: keep-alive (50x1000)           50000 req   42 000 req/s   P50= 0.80 ms   P99=  3.10 ms
B: new-conn (50x200)              10000 req    8 200 req/s   P50= 4.20 ms   P99= 11.50 ms
──────────────────────────────────────────────────────────────────────────────
```

> Os números acima são ilustrativos. Os resultados reais dependem do hardware,
> do SO e de qual back-end (io_uring ou epoll) está ativo no Linux.

## Interpretando os resultados

- **Keep-alive é 4–6× mais rápido** que nova conexão na maioria dos ambientes:
  o custo do handshake TCP (e TLS) é amortizado ao longo de muitas requisições.
- **P99 >> P50** indica jitter do escalonador do SO na máquina de teste;
  execute o benchmark em um host dedicado (sem browser, sem IDE) para obter
  resultados mais limpos.
- Para isolar o overhead do Poseidon do overhead do cliente, execute o benchmark
  e o servidor em máquinas separadas conectadas via LAN de baixa latência.

## Ajustando o benchmark

| Constante | Padrão | Efeito |
|-----------|--------|--------|
| `WORKERS` | 50 | Workers / conexões concorrentes |
| `REPS_KEEPALIVE` | 1 000 | Requisições por worker keep-alive |
| `REPS_NEWCONN` | 200 | Requisições por worker de nova conexão |

Aumente `WORKERS` para simular mais clientes simultâneos; aumente `REPS_*`
para uma janela de medição em regime permanente mais longa.
