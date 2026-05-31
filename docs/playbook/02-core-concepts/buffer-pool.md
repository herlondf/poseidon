# Buffer pool (core concept)

Poseidon uses a multi-tier pool to avoid per-request heap allocations.
Each slot is a pre-allocated `TBytes` kept in a lock-guarded `TStack`.

## Tiers

| Tier | Size | Use |
|------|------|-----|
| 0 | 8 KB | Connection accumulation buffer, small requests |
| 1 | 64 KB | Medium requests / uploads |
| 2 | 512 KB | Large responses / streaming |

`Acquire(ASize)` returns the smallest tier ≥ `ASize`.
`Release` returns the buffer to the correct tier by its length.

For implementation details and advanced usage see
[04-operations/buffer-pool.md](../04-operations/buffer-pool.md).
