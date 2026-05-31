# Throughput Benchmark

The runnable benchmark is in [`samples/08-benchmark/`](../../../samples/08-benchmark/).

## What it measures

| Scenario | Connections | Requests | Notes |
|----------|-------------|----------|-------|
| A — keep-alive | 50 persistent | 1 000 per worker | One TCP connection per worker, 50 000 total |
| B — new-connection | 50 × new | 200 per worker | Fresh TCP handshake every request, 10 000 total |

Metrics reported: **throughput** (req/s), **P50** and **P99** latency (ms).

## Running

```
cd samples\08-benchmark
# Build in Release mode, then:
bin\Release\Poseidon.Sample.Benchmark.exe
```

Sample output:

```
Poseidon Sample 08 — HTTP/1.1 Throughput Benchmark
Server: 127.0.0.1:9090   Workers: 200
──────────────────────────────────────────────────────────────────────────────
Scenario                        Requests    Throughput   P50 Latency   P99 Latency
──────────────────────────────────────────────────────────────────────────────
Running A: keep-alive (50x1000) ... done
A: keep-alive (50x1000)           50000 req   42 000 req/s   P50= 0.80 ms   P99=  3.10 ms
Running B: new-conn (50x200) ... done
B: new-conn (50x200)              10000 req    8 200 req/s   P50= 4.20 ms   P99= 11.50 ms
──────────────────────────────────────────────────────────────────────────────
```

> Numbers above are illustrative. Actual results depend on hardware, OS, and
> whether io_uring or epoll is active (Linux).

## Interpreting results

- **Keep-alive is 4–6× faster** than new-connection in most environments: TCP
  and TLS handshake cost is amortised over many requests.
- **P99 >> P50** spikes indicate OS scheduling jitter on the test machine;
  running the benchmark on a dedicated host (no browser, no IDE) gives cleaner
  numbers.
- To isolate Poseidon overhead from client overhead, run the benchmark and the
  server on separate machines connected via a low-latency LAN.

## Adjusting the benchmark

| Constant | Default | Effect |
|----------|---------|--------|
| `WORKERS` | 50 | Concurrent workers / connections |
| `REPS_KEEPALIVE` | 1 000 | Requests per keep-alive worker |
| `REPS_NEWCONN` | 200 | Requests per new-connection worker |

Increase `WORKERS` to simulate more concurrent clients; increase `REPS_*` for
a longer steady-state measurement window.
