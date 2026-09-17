# Memory manager micro-benchmark (#256)

Compares Delphi's default memory manager (FastMM) against
`Poseidon.MemoryManager.Linux` (redirects `GetMem`/`FreeMem`/`ReallocMem` to
glibc `malloc`/`free`/`realloc` on Linux) under concurrent small/medium
allocation churn — the question [#256](https://github.com/herlondf/poseidon/issues/256)
raised: that unit existed but was never linked into a `.dpr`, and its header
comment used to claim "8.6x more throughput than FastMM" with no benchmark or
experiment anywhere in this repo to back it. Treat that number as unverified
until this sample has actually been run and a real result recorded here.

## Build

Same source, one compiler define toggles which memory manager is active:

```bash
# FastMM (default)
dcclinux64 samples/11-memory-manager-bench/memmgr_bench.dpr

# libc malloc/free (Poseidon.MemoryManager.Linux)
dcclinux64 -DUSE_LIBC_MM samples/11-memory-manager-bench/memmgr_bench.dpr
```

Needs a host that can fully **link** a Linux64 binary — this repo's own bare
Windows dev boxes cannot (see `ci/build-both-faces.ps1`'s comment on
link-skipped compile checks: no Linux SDK/PAServer sysroot configured on
them). The CI runner can (it links `ci-both-faces.yml` fully), or any real
Linux box with the Delphi Linux RTL `.o` files installed.

## Run

```bash
./memmgr_bench       # whichever variant you just built
```

Run both binaries back to back on the **same otherwise-idle machine**
(debian-bench, not a dev box doing something else) and compare the printed
`ops_per_sec`. 8 threads × 2,000,000 iterations each, size classes
32/128/512/4096 bytes, ~1-in-7 iterations reallocs to double size — a
small/medium allocation churn shape, not a single fixed size.

## Scope

This isolates the general-purpose allocator itself. It says nothing about
whether swapping it would help or hurt a real Poseidon deployment, whose hot
network path already avoids the general-purpose allocator via the buffer
pools — that would need a separate, application-shaped benchmark (see the
issue's own suggestion: isolate a real handler, e.g. FireDAC + XML parsing,
from the plaintext hot path).

## Recorded results

Run on debian-bench (Debian 13, kernel 6.12, 4 vCPU), 3 runs each, binaries
built with the exact commands above (`-O<BDS lib path>` + `--libpath` at
`Benchmark/tools/linux_stubs`, see the `poseidon-benchmark` skill for the
full cross-compile recipe):

| Variant | ops/sec (3 runs) | Host | Date |
|---|---|---|---|
| FastMM (default) | 26,101,141 / 18,390,804 / 19,417,475 | debian-bench | 2026-09-17 |
| libc malloc/free | 22,889,842 / 21,505,376 / 25,000,000 | debian-bench | 2026-09-17 |

**The "8.6x" claim is false.** The two ranges overlap entirely (roughly
18-26M ops/sec either way) — no statistically meaningful difference for this
allocation shape (small/medium sizes, concurrent churn across 8 threads).
The claim has been removed from `Poseidon.MemoryManager.Linux.pas`'s header
comment (done earlier, see #256); this confirms removing it was correct
rather than just cautious.

This does not mean the unit is useless — it may still matter for a
different workload shape (e.g. very large allocations, or a single-threaded
pattern where FastMM's lock-free-per-thread design has less to offer), but
that would need its own targeted measurement, not an extrapolation from this
result.
