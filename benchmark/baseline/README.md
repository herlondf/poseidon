# Benchmark Baselines

This directory holds performance snapshots taken before and after structural refactoring.

## Naming convention

```
before-refactor-YYYY-MM-DD.json   ← raw results (machine-readable)
before-refactor-YYYY-MM-DD.md     ← summary table (human-readable)
after-refactor-YYYY-MM-DD.json
after-refactor-YYYY-MM-DD.md
```

## Regression criteria

A refactoring PR is acceptable when, comparing against the latest `before-refactor-*` snapshot:

| Metric | Maximum allowed regression |
|--------|---------------------------|
| RPS    | −3%                        |
| P99    | +5%                        |

Any scenario that exceeds these limits must be investigated before merge.

## How to capture a baseline

1. Build the benchmark executable:
   ```
   cd benchmark
   build.bat
   ```
2. Run the full benchmark suite:
   ```
   bin\Poseidon.Benchmark.exe
   ```
3. Copy the generated `bin\poseidon-bench.html` results into a JSON/MD snapshot
   using the `--save-baseline` flag (see Bench.Report.pas TODO).

## Current snapshots

_(none yet — run the benchmark to establish the first baseline)_
