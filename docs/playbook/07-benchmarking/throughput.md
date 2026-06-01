# Throughput Benchmark

The full benchmark suite is at [`benchmark/`](../../../benchmark/).
It starts four Poseidon configurations on dedicated ports and runs 14 scenarios
covering payload size, concurrency, and blocking I/O simulation.

## Configurations tested

| Name | Port | Description |
|------|------|-------------|
| `Workers=4` | 19990 | Fixed 4 IOCP worker threads |
| `Workers=auto` | 19991 | Worker count = logical CPU count |
| `Gzip` | 19992 | `Workers=auto` + response compression |
| `SSL` | 19993 | `Workers=auto` + TLS (requires OpenSSL + certs) |

## Running

```
cd benchmark
build.bat          # compiles with dcc64 directly (no MSBuild)
bin\Poseidon.Benchmark.exe
```

HTML report is saved to `bin\poseidon-bench.html`.

## Scenario matrix

| Category | Scenario | Requests | Threads |
|----------|----------|----------|---------|
| Payload | Tiny (28 B) GET /ping | 500 | 1 |
| Payload | Small (256 B) POST /echo | 300 | 1 |
| Payload | Medium (~1 KB) GET /medium | 300 | 1 |
| Payload | Large (~50 KB) GET /large | 100 | 1 |
| Payload | XLarge (~512 KB) GET /xlarge | 30 | 1 |
| Payload | Large Upload (256 KB) POST /echo | 50 | 1 |
| Concurrency | 10 threads × /ping | 500 | 10 |
| Concurrency | 50 threads × /ping | 1 000 | 50 |
| Concurrency | 100 threads × /ping | 1 000 | 100 |
| Concurrency | Large download (20 threads) | 100 | 20 |
| FakeDAO | GET /users/1 (5 ms simulated) | 50 | 1 |
| FakeDAO | GET /users list (10 ms simulated) | 30 | 1 |
| FakeDAO | Concurrent 20 threads × /users/1 | 100 | 20 |
| Mixed | 10 threads × /ping | 700 | 10 |

## Reference results (Windows 11, i7-12th gen, loopback)

### Payload size — sequential

| Scenario | Workers=4 | Workers=auto | Gzip |
|----------|-----------|--------------|------|
| Tiny (28 B) | 2 577 rps / 0.39 ms avg / 0.53 ms P99 | 2 674 rps / 0.37 ms avg / 0.53 ms P99 | 2 717 rps / 0.37 ms avg / 0.54 ms P99 |
| Small (256 B) | 2 308 rps / 0.43 ms avg / 0.58 ms P99 | 2 344 rps / 0.43 ms avg / 0.58 ms P99 | 2 362 rps / 0.42 ms avg / 0.55 ms P99 |
| Medium (~1 KB) | 2 703 rps / 0.37 ms avg / 0.49 ms P99 | 2 752 rps / 0.36 ms avg / 0.46 ms P99 | 2 752 rps / 0.36 ms avg / 0.49 ms P99 |
| Large (~50 KB) | 1 282 rps / 0.78 ms avg / 0.99 ms P99 | 1 316 rps / 0.77 ms avg / 0.92 ms P99 | 1 333 rps / 0.75 ms avg / 0.86 ms P99 |
| XLarge (~512 KB) | 54 rps / 18.7 ms avg / 45.2 ms P99 | 54 rps / 18.6 ms avg / 44.4 ms P99 | 47 rps / 21.1 ms avg / 45.2 ms P99 |
| Upload (256 KB) | 94 rps / 10.6 ms avg / 24.5 ms P99 | 80 rps / 12.5 ms avg / 39.7 ms P99 | 92 rps / 10.9 ms avg / 26.6 ms P99 |

### Concurrency

| Scenario | Workers=4 | Workers=auto | Gzip |
|----------|-----------|--------------|------|
| 10 threads | 4 065 rps / 1.55 ms avg / 25.1 ms P99 | 4 386 rps / 1.35 ms avg / 22.7 ms P99 | 3 846 rps / 1.70 ms avg / 22.8 ms P99 |
| 50 threads | 5 618 rps / 3.56 ms avg / 37.2 ms P99 | 4 717 rps / 3.90 ms avg / 42.6 ms P99 | 6 494 rps / 3.26 ms avg / 30.7 ms P99 |
| 100 threads | 5 848 rps / 3.59 ms avg / 27.9 ms P99 | **7 143 rps** / 3.36 ms avg / 30.4 ms P99 | 6 579 rps / 3.41 ms avg / 29.9 ms P99 |
| Large 20t | 1 613 rps / 6.56 ms avg / 31.0 ms P99 | 1 163 rps / 7.74 ms avg / 56.4 ms P99 | **2 326 rps** / 4.24 ms avg / 24.4 ms P99 |

### FakeDAO (blocking I/O simulation)

| Scenario | Workers=4 | Workers=auto | Gzip |
|----------|-----------|--------------|------|
| GET /users/1 (5 ms) | 2 632 rps / 0.39 ms | 2 500 rps / 0.41 ms | 2 500 rps / 0.40 ms |
| GET /users list | 2 308 rps / 0.44 ms | 2 500 rps / 0.43 ms | 2 500 rps / 0.42 ms |
| Concurrent 20t (5 ms) | 1 667 rps / 6.72 ms | 1 449 rps / 8.33 ms | 1 136 rps / 7.55 ms |

## Interpreting results

- **Gzip wins on large parallel downloads** (Concurrent Large 20t): Gzip 2 326 vs
  Workers=auto 1 163 rps — compression reduces bytes on the loopback, cutting total
  I/O time despite the CPU overhead.
- **Workers=auto wins at high concurrency** (100 threads): auto-sizing maps one worker
  per CPU, avoiding context-switch overhead with fixed-4.
- **P99 spikes** at high concurrency reflect OS scheduling jitter on loopback;
  measured on a dedicated host connected via LAN the tail latency will be tighter.
- **XLarge / Upload scenarios** are dominated by socket buffer throughput, not
  Poseidon CPU overhead — results are similar across all configurations.
