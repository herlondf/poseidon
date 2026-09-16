# Prometheus metrics

Poseidon exposes server metrics in
[Prometheus exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/) 0.0.4
through `MetricsMiddleware`, a regular middleware (not a `TPoseidonNativeServer`
property) - see [middlewares #10](../09-middlewares/README.md#10-metrics) for
the request/error/histogram side of it.

> **2026-09-16 correction:** this page used to document a `LServer.MetricsEnabled`
> / `LServer.Metrics.IncrementCounter` server-native API. That API does not
> exist in the current source tree (confirmed by a repo-wide search) - the
> only implementation is the middleware described below. If you have code
> written against the old API, it was never actually functional; switch to
> `MetricsMiddleware`.

## Enabling the endpoint

```pascal
uses Poseidon.Middleware.Metrics;

App.Use(MetricsMiddleware('/metrics'));  // '/metrics' is also the default
```

## Scraping

```
GET /metrics
```

Returns a plain-text response (`Content-Type: text/plain; version=0.0.4`) with
all exposed metrics. Standard Prometheus scrape interval is 15-60 s.

## Per-path metrics

`poseidon_requests_total`, `poseidon_errors_total` (status >= 400) and the
`poseidon_request_duration_ms` histogram, all labeled by `path`. See
[middlewares #10](../09-middlewares/README.md#10-metrics) for bucket bounds
and the path-cardinality cap.

## Process-level gauges

Added 2026-09-16, alongside the [heap diagnostics](../../../src/Poseidon.Diagnostics.pas)
that came out of a production memory-growth investigation in a downstream
deployment. One value per process, no `path` label - unlike everything else
this endpoint exposes:

| Metric | Source | Meaning |
|---|---|---|
| `poseidon_rss_kb` | `TPoseidonDiagnostics.RSSKB` | Resident set size. Includes shared library pages counted again in every other process mapping them. |
| `poseidon_malloc_inuse_kb` | `MallocInfo` (mallinfo2 `uordblks`) | Bytes glibc reports the app still holds live. Linux only, `-1` on Windows. |
| `poseidon_malloc_arena_kb` | `MallocInfo` (mallinfo2 `arena`) | Non-mmap heap footprint sbrk'd from the OS - includes freed-but-retained space. Linux only. |
| `poseidon_malloc_mmap_kb` | `MallocInfo` (mallinfo2 `hblkhd`) | Large allocations backed by mmap, returned to the OS immediately on free. Linux only. |
| `poseidon_delphi_heap_kb` | `DelphiHeapInUseKB` (`GetMemoryManagerState`) | Delphi's own memory manager, bytes in use. Windows/OSX only, `-1` on Linux (there, `SysGetMem` already calls `malloc` directly - `poseidon_malloc_inuse_kb` covers that case fully). |
| `poseidon_fd_count` | `OpenFDCount` (`/proc/self/fd` count) | Open file descriptors. Linux only. |
| `poseidon_private_dirty_kb` | `PrivateDirtyKB` (`/proc/self/smaps_rollup`) | Memory only this process wrote and holds, shared library pages excluded - tighter than `poseidon_rss_kb` for "how much would this instance's exit actually free up." Linux only. |

**Reading them together, the question each pair answers:**

- `poseidon_malloc_inuse_kb` flat while `poseidon_rss_kb` climbs → the
  allocator is retaining freed-but-unreturned memory (fragmentation), not
  leaking. Look at glibc's `MALLOC_TRIM_THRESHOLD_`/`MALLOC_MMAP_THRESHOLD_`
  tuning before assuming a code-level leak.
- `poseidon_malloc_inuse_kb` climbing too → a real leak in native/C-level
  code (sockets, OpenSSL, zlib, libcurl, or anything else calling `malloc`
  directly) - not in Delphi-managed objects.
- `poseidon_delphi_heap_kb` climbing on Windows while `poseidon_malloc_inuse_kb`
  stays flat → the leak is Delphi-level (an object/string/interface not
  released) - this split does not apply on Linux (see the table above).
- `poseidon_fd_count` climbing with `poseidon_rss_kb` → probably "not closing
  something" (a connection, a stream, a handle), not a pure allocator
  question - a leaked socket/stream almost always drags its own buffers along.

Same log-line pattern as `[health]` (see the server's periodic heartbeat) -
these gauges are the same numbers, just in a scrapeable form instead of a
text log line.

## Forcing a heap trim attempt

If `poseidon_malloc_arena_kb - poseidon_malloc_inuse_kb` (retained-but-unused
heap) has grown large, `TPoseidonDiagnostics.TryMallocTrim` (Linux only)
forces glibc to attempt returning that space to the OS right now, instead of
waiting for its own trim threshold to be crossed on its own:

```pascal
if TPoseidonDiagnostics.TryMallocTrim then
  // freed something back to the OS
else
  // nothing to trim right now
```

This is a diagnostic/operational tool, not a fix — if the gap keeps growing
back right after a successful trim, that is recurring retention/fragmentation,
not something to paper over by calling this on a timer. Tune
`MALLOC_TRIM_THRESHOLD_`/`MALLOC_MMAP_THRESHOLD_` instead (see the Dockerfile
comments in a deployment that has already tuned these, if one exists in your
stack) so the kernel gets the memory back on its own.

Poseidon does not install a signal handler for this itself — following the
same pattern as [graceful reload](../05-recipes/graceful-reload.md) (`SIGUSR2`
is application-level, not forced by the library), wire it to a spare signal
in your own `.dpr` if you want an operator-triggerable trim without a
restart:

```pascal
{$IFNDEF MSWINDOWS}
uses Posix.Signal;

procedure TrimSignalHandler(ASigNum: Integer); cdecl;
begin
  // Signal-handler-safe: TryMallocTrim's only side effect from here is the
  // libc call itself. Log the result on the next [health] line instead of
  // logging inline, the same reasoning InstallCrashHandler documents for
  // why _CrashHandler avoids allocating string types from signal context.
  TPoseidonDiagnostics.TryMallocTrim;
end;

// during startup, alongside InstallCrashHandler:
signal(SIGUSR1, @TrimSignalHandler);
{$ENDIF}
```

Then `kill -USR1 <pid>` triggers a trim attempt on demand.

## Notes

- Metrics are updated atomically; the `/metrics` endpoint is safe to scrape concurrently.
- The endpoint is served by the same worker pool as regular requests.
- Do not expose `/metrics` on a public port without a reverse-proxy ACL or
  network-level restriction (there is no built-in CIDR allowlist in the
  current middleware, unlike what an earlier version of this page claimed).
