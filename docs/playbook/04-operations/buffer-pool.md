# Buffer pool

Poseidon uses a multi-tier buffer pool (`TBufferPool`) to avoid per-request heap
allocations for I/O buffers and HTTP responses.

## Tiers

| Tier | Slot size | Pool slots | Typical use |
|------|-----------|-----------|-------------|
| 0 | 8 KB | 256 | Initial connection buffer, small requests, WebSocket ping |
| 1 | 64 KB | 64 | Medium requests, file uploads |
| 2 | 512 KB | 16 | Large responses, streaming |
| Heap | exact size | — | Oversized (> 512 KB) — bypasses pool entirely |

## How it works

`TBufferPool.Acquire(ASize)` returns the smallest tier whose slot size ≥ `ASize`.
`TBufferPool.Release(var ABuf)` detects the tier by buffer length and returns it to
the correct stack. Both operations are protected by `TMonitor` (lock-free fast-path
via `TStack<TBytes>`).

```pascal
var
  LBuf: TBytes;
begin
  LBuf := TBufferPool.Acquire(1024);   // returns an 8 KB slot
  try
    // ... use LBuf[0..1023] ...
  finally
    TBufferPool.Release(LBuf);         // returned to tier 0
  end;
end;
```

## Pooled HTTP response builder (P-4)

The hot path in `TProtocolDispatcher` uses `BuildHTTPResponsePooled` instead of
the regular `BuildHTTPResponse`. This writes the full HTTP response (status line +
headers + body) directly into a pool buffer with `Move()` calls — avoiding the
intermediate `TStringBuilder` and `TEncoding.UTF8.GetBytes` allocations.

The raw buffer is passed to the OS send function with `AActualLen` as the byte count,
then released back to the pool after the send completes.

## Dependency injection

The pool is exposed as `IBufferPool` so it can be replaced in tests:

```pascal
// Production: nil selects TBufferPool (the built-in multi-tier pool)
LServer := TPoseidonNativeServer.Create(nil, nil, nil);

// Test: inject a mock
LServer := TPoseidonNativeServer.Create(TMyMockBufferPool.Create, nil, nil);
```

## Tier 2 exhaustion (#245)

Tier 2 has only 16 **global** slots (shared by every thread) for 512 KB
buffers — the tier that matters most for large responses. Whether this
actually runs dry under real large-response traffic (as opposed to just
being theoretically possible) was an open question, not a confirmed
problem: bumping `POOL_TIER2_MAX` or adding a Tier 3 without evidence would
be an unvalidated tuning guess.

`TBufferPool.Tier2ExhaustedCount` and `.OversizedCount` answer this directly
- also exposed as Prometheus counters
(`poseidon_bufferpool_tier2_exhausted_total`,
`poseidon_bufferpool_oversized_total` - see [metrics.md](metrics.md)):

- **`Tier2ExhaustedCount`** climbing under load means a response that
  *should* have been pooled wasn't - both the calling thread's local cache
  and the global Tier 2 stack were empty, so it fell back to a heap
  `SetLength`. This is the actual signal to raise `POOL_TIER2_MAX` or add a
  Tier 3.
- **`OversizedCount`** is requests above 512 KB, which bypass the pool
  *by design* (see the tiers table above) - not a sizing problem on its
  own, shown alongside `Tier2ExhaustedCount` only for context (a large
  `OversizedCount` might mean your response sizes belong in a bigger tier
  entirely, rather than Tier 2 needing more slots).

See [Core Concepts — Buffer pool](../../02-core-concepts/buffer-pool.md) for the conceptual overview.
