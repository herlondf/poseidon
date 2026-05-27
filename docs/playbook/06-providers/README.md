# 06 — Providers

Providers bridge Poseidon with HTTP frameworks. They live in `providers/<framework>/`
and are optional — you only add the ones you use to your project's search path.

| Provider | File | Framework | Requires |
|----------|------|-----------|---------|
| [Horse](horse.md) | `providers/horse/Horse.Provider.Poseidon.pas` | [Horse](https://github.com/HashLoad/horse) ≥ 3.1.9 | `src/` + `providers/horse/` in search path, `HORSE_ASYNCIO` define |
