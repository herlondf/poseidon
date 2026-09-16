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

_(none yet — fill in after running on a host that can link, per above)_

| Variant | ops/sec | Host | Date |
|---|---|---|---|
| FastMM (default) | — | — | — |
| libc malloc/free | — | — | — |
