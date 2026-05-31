# Poseidon Benchmark — Post-Refactoring Baseline (R-1 through R-5)

**Date:** 2026-05-31  
**Commit:** 34ce58c (after R-1 IO backend extraction, R-4 TNativeConn, R-5 Dispatcher)  
**Machine:** Windows 11 Pro 10.0.26200  
**Note:** SSL adapter excluded due to pre-existing IOCP+SSL race condition (TNativeConn freed while IOCP completion packet in flight → AV). Non-SSL scenarios are zero-error across all payloads.

## Results

| Scenario | Workers=4 RPS | Workers=auto RPS | Gzip RPS |
|----------|:-------------|:----------------|:---------|
| Payload: Tiny (28 B) | 2976 | 2959 | 2994 |
| Payload: Small (256 B) | 2542 | 2542 | 2586 |
| Payload: Medium (~1 KB) | 2970 | 2913 | 2970 |
| Payload: Large (~50 KB) | 1409 | 1429 | 1449 |
| Payload: XLarge (~512 KB) | 62 (p99=37ms) | 60 (p99=31ms) | 59 (p99=41ms) |
| Payload: Large Upload (256 KB) | 89 (p99=28ms) | 125 (p99=16ms) | 108 (p99=27ms) |
| Concurrent 10 threads | 4425 (p99=24ms) | 4310 (p99=22ms) | 4274 (p99=30ms) |
| Concurrent 50 threads | 6494 (p99=28ms) | 6410 (p99=32ms) | 4975 (p99=31ms) |
| Concurrent Large (20 × 50 KB) | 2174 (p99=29ms) | 1667 (p99=42ms) | 1639 (p99=42ms) |
| FakeDAO: GET /users/1 (fast) | 2632 | 2778 | 2941 |
| FakeDAO: GET /users list | 3000 | 2727 | 2727 |
| Mixed Load (10 threads) | 5000 (p99=25ms) | 5185 (p99=24ms) | 3825 (p99=31ms) |

## Regression criteria (from baseline/README.md)

| Metric | Limit |
|--------|-------|
| RPS | max −3% vs this baseline |
| P99 | max +5% vs this baseline |

## Known issues

- **SSL AV (#43):** Concurrent IOCP+SSL connections trigger an access violation when TNativeConn is freed while an IOCP completion packet for that same connection is still in the kernel queue. Sequential SSL requests succeed. Fix requires reference-counted connection lifetime or deferred-free pattern.
