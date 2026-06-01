# Benchmark de Throughput

O suite completo de benchmark está em [`benchmark/`](../../../benchmark/).
Ele sobe quatro configurações do Poseidon em portas dedicadas e executa 14 cenários
cobrindo tamanho de payload, concorrência e simulação de I/O bloqueante.

## Configurações testadas

| Nome | Porta | Descrição |
|------|-------|-----------|
| `Workers=4` | 19990 | 4 threads de worker IOCP fixas |
| `Workers=auto` | 19991 | Workers = número de CPUs lógicas |
| `Gzip` | 19992 | `Workers=auto` + compressão de resposta |
| `SSL` | 19993 | `Workers=auto` + TLS (requer OpenSSL + certificados) |

## Execução

```
cd benchmark
build.bat          # compila diretamente com dcc64 (sem MSBuild)
bin\Poseidon.Benchmark.exe
```

O relatório HTML é salvo em `bin\poseidon-bench.html`.

## Matriz de cenários

| Categoria | Cenário | Requisições | Threads |
|-----------|---------|-------------|---------|
| Payload | Tiny (28 B) GET /ping | 500 | 1 |
| Payload | Small (256 B) POST /echo | 300 | 1 |
| Payload | Medium (~1 KB) GET /medium | 300 | 1 |
| Payload | Large (~50 KB) GET /large | 100 | 1 |
| Payload | XLarge (~512 KB) GET /xlarge | 30 | 1 |
| Payload | Upload grande (256 KB) POST /echo | 50 | 1 |
| Concorrência | 10 threads × /ping | 500 | 10 |
| Concorrência | 50 threads × /ping | 1 000 | 50 |
| Concorrência | 100 threads × /ping | 1 000 | 100 |
| Concorrência | Download grande (20 threads) | 100 | 20 |
| FakeDAO | GET /users/1 (5 ms simulados) | 50 | 1 |
| FakeDAO | GET /users lista (10 ms simulados) | 30 | 1 |
| FakeDAO | Concorrente 20 threads × /users/1 | 100 | 20 |
| Misto | 10 threads × /ping | 700 | 10 |

## Resultados de referência (Windows 11, i7 12ª geração, loopback)

### Tamanho de payload — sequencial

| Cenário | Workers=4 | Workers=auto | Gzip |
|---------|-----------|--------------|------|
| Tiny (28 B) | 2 577 rps / avg 0,39 ms / P99 0,53 ms | 2 674 rps / avg 0,37 ms / P99 0,53 ms | 2 717 rps / avg 0,37 ms / P99 0,54 ms |
| Small (256 B) | 2 308 rps / avg 0,43 ms / P99 0,58 ms | 2 344 rps / avg 0,43 ms / P99 0,58 ms | 2 362 rps / avg 0,42 ms / P99 0,55 ms |
| Medium (~1 KB) | 2 703 rps / avg 0,37 ms / P99 0,49 ms | 2 752 rps / avg 0,36 ms / P99 0,46 ms | 2 752 rps / avg 0,36 ms / P99 0,49 ms |
| Large (~50 KB) | 1 282 rps / avg 0,78 ms / P99 0,99 ms | 1 316 rps / avg 0,77 ms / P99 0,92 ms | 1 333 rps / avg 0,75 ms / P99 0,86 ms |
| XLarge (~512 KB) | 54 rps / avg 18,7 ms / P99 45,2 ms | 54 rps / avg 18,6 ms / P99 44,4 ms | 47 rps / avg 21,1 ms / P99 45,2 ms |
| Upload (256 KB) | 94 rps / avg 10,6 ms / P99 24,5 ms | 80 rps / avg 12,5 ms / P99 39,7 ms | 92 rps / avg 10,9 ms / P99 26,6 ms |

### Concorrência

| Cenário | Workers=4 | Workers=auto | Gzip |
|---------|-----------|--------------|------|
| 10 threads | 4 065 rps / avg 1,55 ms / P99 25,1 ms | 4 386 rps / avg 1,35 ms / P99 22,7 ms | 3 846 rps / avg 1,70 ms / P99 22,8 ms |
| 50 threads | 5 618 rps / avg 3,56 ms / P99 37,2 ms | 4 717 rps / avg 3,90 ms / P99 42,6 ms | 6 494 rps / avg 3,26 ms / P99 30,7 ms |
| 100 threads | 5 848 rps / avg 3,59 ms / P99 27,9 ms | **7 143 rps** / avg 3,36 ms / P99 30,4 ms | 6 579 rps / avg 3,41 ms / P99 29,9 ms |
| Large 20t | 1 613 rps / avg 6,56 ms / P99 31,0 ms | 1 163 rps / avg 7,74 ms / P99 56,4 ms | **2 326 rps** / avg 4,24 ms / P99 24,4 ms |

### FakeDAO (simulação de I/O bloqueante)

| Cenário | Workers=4 | Workers=auto | Gzip |
|---------|-----------|--------------|------|
| GET /users/1 (5 ms) | 2 632 rps / avg 0,39 ms | 2 500 rps / avg 0,41 ms | 2 500 rps / avg 0,40 ms |
| GET /users lista | 2 308 rps / avg 0,44 ms | 2 500 rps / avg 0,43 ms | 2 500 rps / avg 0,42 ms |
| Concorrente 20t (5 ms) | 1 667 rps / avg 6,72 ms | 1 449 rps / avg 8,33 ms | 1 136 rps / avg 7,55 ms |

## Interpretando os resultados

- **Gzip vence em downloads paralelos grandes** (Concorrente Large 20t): Gzip 2 326 vs
  Workers=auto 1 163 rps — a compressão reduz bytes no loopback, diminuindo o tempo
  total de I/O apesar do overhead de CPU.
- **Workers=auto vence em alta concorrência** (100 threads): o auto-dimensionamento
  mapeia um worker por CPU, evitando o overhead de troca de contexto do fixo-4.
- **Picos de P99** em alta concorrência refletem jitter do escalonador do SO no loopback;
  medido em host dedicado via LAN, a latência de cauda será mais estreita.
- **Cenários XLarge / Upload** são dominados pela capacidade do buffer do socket,
  não pelo overhead de CPU do Poseidon — os resultados são similares em todas as configurações.
