# 06 — Providers

Providers fazem a ponte entre o AsyncIO e frameworks HTTP. Ficam em `providers/<framework>/`
e são opcionais — adicione ao search path do projeto apenas os que usar.

| Provider | Arquivo | Framework | Requisitos |
|----------|---------|-----------|------------|
| [Horse](horse.md) | `providers/horse/Horse.Provider.AsyncIO.pas` | [Horse](https://github.com/HashLoad/horse) ≥ 3.1.9 | `src/` + `providers/horse/` no search path, define `HORSE_ASYNCIO` |
