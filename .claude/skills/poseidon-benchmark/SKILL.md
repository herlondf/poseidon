---
name: poseidon-benchmark
description: Medir performance do Poseidon (throughput req/s, latência p50/p99, saturação/knee, uso de CPU/memória, vazamento sob carga) e perfilar hot paths, dirigindo o harness externo do repositório Benchmark (D:\IA\Projetos\Delphi\Benchmark — k6 + wrk + Docker + Nginx LB + Grafana/InfluxDB/Tempo/SigNoz). Use SEMPRE que pedirem para benchmarkar/medir/perfilar o Poseidon, comparar v1↔v2 ou Horse↔Poseidon, verificar se uma mudança regrediu performance, ou decidir se um item de perf "vale a pena" (benchmark-gated). É uma skill-PONTE: faz o preparo do lado Poseidon e delega a execução às 11 skills benchmark-* do repo Benchmark. NÃO duplica o harness.
---

# Benchmark & profiling do Poseidon — skill-ponte

O harness NÃO vive aqui. Ele está em **`D:\IA\Projetos\Delphi\Benchmark`**
(builds PowerShell no Windows; runs em WSL, distro `Benchmark` Ubuntu; alvos em
Docker; k6/wrk nativos). Este repositório (`D:\IA\Projetos\Delphi\Poseidon`) é a
**fonte canônica** do código v2. Esta skill: (1) faz o preparo do lado Poseidon,
(2) mapeia objetivo → script/skill certo do Benchmark, (3) fecha o loop
resultado → código do Poseidon.

## ⚠️ REGRA DE FERRO nº1 — sincronizar antes de medir

`Benchmark\vendor\poseidon-v2\` é uma **cópia rastreada, NÃO sincronizada** (não
é submódulo, nenhum script a atualiza) e **frequentemente está atrasada** em
relação a este repo. Medir sem sincronizar = medir código VELHO — foi exatamente
isso que fez rodadas anteriores obterem 9.6K req/s onde o esperado era ~128K
(ver `Benchmark\docs\PROMPT-COMO-COMPILAR-POSEIDON-V2.md`, histórico).

Antes de QUALQUER build/run:

```bash
# 1. Espelhar o código canônico na cópia vendorizada
cp -r "D:/IA/Projetos/Delphi/Poseidon/src/."         "D:/IA/Projetos/Delphi/Benchmark/vendor/poseidon-v2/src/"
cp -r "D:/IA/Projetos/Delphi/Poseidon/middlewares/." "D:/IA/Projetos/Delphi/Benchmark/vendor/poseidon-v2/middlewares/"
# 2. Purgar objetos velhos — dcclinux64 reusa .o/.dcu silenciosamente (binário stale)
find "D:/IA/Projetos/Delphi/Benchmark/vendor/" -name "*.o"   -delete
find "D:/IA/Projetos/Delphi/Benchmark/vendor/" -name "*.dcu" -delete
```

Confirme que casou: `diff -rq D:/IA/Projetos/Delphi/Poseidon/src D:/IA/Projetos/Delphi/Benchmark/vendor/poseidon-v2/src` deve sair vazio.
`build.ps1` auto-descobre todo `vendor/**/*.pas` no search path — copiar basta,
sem editar path.

## As 11 skills do Benchmark (delegue, não reimplemente)

Rodam DENTRO do repo Benchmark (skills são project-scoped). As três centrais para
esta ponte: **benchmark-linux-build**, **benchmark-infra-stack**,
**benchmark-run-scenario**.

- `benchmark-run-scenario` — escolhe qual `run-*.sh`, mapeia framework→binário→k6, VUs/duração/instâncias, pré-checa infra+binário. **Ponto de entrada da execução.**
- `benchmark-linux-build` — cross-compile Linux64 (dcclinux64), defines por framework, diagnóstico de binário stale / Runtime error 217.
- `benchmark-infra-stack` — sobe/derruba o Docker Compose (Postgres, Redis, InfluxDB, Tempo, Grafana, Nginx), datasources, reset de volumes.
- `benchmark-saturation-test` — breakpoint/knee via k6 `ramping-arrival-rate` (modelo aberto). Saturação NUNCA se mede com VU fixo.
- `benchmark-resource-leak` — CPU/mem por instância + leak vs pooling (docker stats → InfluxDB).
- `benchmark-results-report` — escreve o relatório comparativo em `docs/BENCHMARK-*.md` (todo número precisa de causa-raiz).
- `benchmark-troubleshoot` — runbook sintoma→causa→fix (comece por `docker logs bench-app-1 | tail -30`).
- `benchmark-k6-scenario` — criar script k6 novo em `infra/k6/bench-*.js`.
- `benchmark-new-sample` — criar sample novo em `samples/delphi/` (mexe em 4 lugares).
- `benchmark-dashboard-export` — exportar dashboard Grafana em PNG.

## Objetivo → workflow

| Objetivo | Build (PowerShell, no dir Benchmark) | Run (WSL, em `infra/`) | Framework |
|---|---|---|---|
| Throughput HTTP puro | `build-community-bench.ps1 -Mode poseidon-v2` | `./run-ping.sh poseidon-v2 <nome> [vus=500] [dur=2m] [inst=1]` | `poseidon-v2` |
| Throughput sob **cap de CPU/RAM** (wrk) | `build-community-bench.ps1 -Mode poseidon-v2` | `./run-ping-limited.sh poseidon-v2` (LIMIT_CPUS/LIMIT_MEMORY) | `poseidon-v2` |
| Carga com DB (CRUD) | `build.ps1 -Sample compat-poseidon-v2 -Platform Linux64` | `./run-crud.sh poseidon-v2 <nome> [vus] [dur] [inst] [limites]` | `poseidon-v2` |
| Workload realista NFCe | `build_nfce_linux.ps1 -Mode poseidon` | `./run-nfce.sh poseidon <nome> [vus] [dur]` | `poseidon` |
| Saturação / knee | (build ping ou crud) | `benchmark-saturation-test` → `bench-crud-saturation.js` (arrival-rate) | — |
| Vazamento / soak | (build crud) | `benchmark-resource-leak` / `bench-crud-soak.js` | — |
| v1↔v2 ou Pool4D↔Triton | (builds correspondentes) | `./run-pool-comparison.sh [vus] [dur]` | vários |
| Horse↔Poseidon | build ambos | `./run-crud.sh horse-epoll ...` e `./run-crud.sh poseidon-v2 ...` | `horse-epoll`/`poseidon-v2` |

Regra: **containeriza o alvo, nunca o gerador de carga.** `run-ping-limited` usa
**wrk** (só terminal, sem Grafana); os demais usam **k6** (→ InfluxDB → Grafana).

## Caminho feliz canônico (medir o Poseidon atual)

1. **Sincronizar+purgar** (Regra de Ferro nº1 acima).
2. **Build**: escolher o `.ps1` da tabela conforme o objetivo → produz ELF sem
   extensão em `Benchmark\samples\delphi\bin\linux\` (delegar a `benchmark-linux-build`).
3. **Infra**: `cd Benchmark/infra && docker compose up -d`; confirmar
   postgres+influxdb+tempo+grafana healthy (delegar a `benchmark-infra-stack`).
4. **Seed** (só CRUD/NFCe): aplicar schema (`build.ps1` menu "Seed" ou `psql`).
5. **Run**: em WSL, `cd infra/` e chamar o `run-*.sh` da tabela com `poseidon-v2`
   (ou `poseidon` p/ NFCe) + VUs/duração/instâncias (delegar a `benchmark-run-scenario`).
6. **Ler**: Grafana `http://localhost:16300`, dashboard uid `bench-overview`
   (tiles 101-105, percentis 111-115, throughput 11, latência 12, status 14).
   Cada teste cria um DB InfluxDB `<nome>` = datasource novo.

## Fechar o loop — resultado → código do Poseidon

O valor da skill é traduzir o número/flamegraph num ponto do código:

- **p99 alto / knee cedo** → modelo de dispatch (async `Post` = +1 thread-hop;
  ver `Poseidon.Net.HttpServer._DispatchAccumBuf` / SyncDispatch) e backend
  (epoll vs io_uring). Comparar `SyncDispatch` on/off.
- **CPU alta / baixo req/s no ping** → alocações por request (hot path:
  `HTTP1.Parser`, `ResponseBuilder`, `Native.Router.MakeKey`) — casa com os
  itens de perf abertos (issue #197) e os levers de zero-alocação.
- **Escala ruim com concorrência (não com CPU)** → contenção de MM ou lock
  (Pool.Workers, buffer pool). Considerar arenas por-thread.
- **Memória não volta ao baseline** → leak vs pooling (`benchmark-resource-leak`).
- **Horse ganha no ping** → historicamente era single-listen+single-epoll+queue;
  o v2 canônico já tem shared-nothing per-core epoll — confirmar que está ativo
  (ver `docs/PROMPT-POSEIDON-V2-OPTIMIZATION.md`, histórico/aspiracional).

## Profiling (flamegraph) — não é pré-fiado no harness

O Benchmark entrega req/s, latência e CPU/mem (docker stats), mas NÃO um
flamegraph. Para perfilar CPU do binário sob carga:
- Linux/container: `perf record -g -F 999 -p <pid do server no container> -- sleep 30`
  → `perf report`/FlameGraph; precisa `perf` no host + símbolos (compilar com
  debug info). `perf stat -p <pid>` p/ ciclos/IPC/cache-miss; `strace -f -c -p <pid>`
  p/ syscalls/resposta.
- É uma extensão razoável ao harness (poderia virar um `run-*-profile.sh`).

## Regra de ouro de perf (igual à das reviews)

Só afirme um ganho/gargalo com NÚMERO. Otimizar hot path sem medir é o risco que
mantém os itens M12/M14/M25/HPACK-O(n²) como **benchmark-gated** — rodar aqui é
o que destrava decidi-los.

## Gotchas (os que mais mordem)

- Binário stale → **sempre** purgar `vendor/` `.o`/`.dcu` antes de buildar.
- Poseidon morre logo após subir → a main thread termina após `Listen`; o DPR de
  bench já tem `while True do TThread.Sleep(60000)` — se criar sample novo, incluir.
- 99% de erro a 200+ VUs → Postgres `max_connections=100`; subir p/ 500 no compose.
- InfluxDB cai sob carga → `INFLUXDB_HTTP_MAX_BODY_SIZE=0`.
- Runtime error 217 no container → lib nativa faltando (libicu74 p/ Horse etc.);
  `strace -e trace=file ./server 2>&1 | grep ENOENT`.
- Datasource novo por teste → adicionar em `grafana/provisioning/datasources/` +
  `docker restart bench-grafana`.

## Não faça
- Não medir sem sincronizar `vendor/poseidon-v2` (Regra de Ferro nº1).
- Não medir saturação com VU fixo (use arrival-rate).
- Não reimplementar as 11 skills do Benchmark aqui — delegue.
- Não containerizar o gerador de carga.
- Não afirmar regressão/ganho de perf sem o número do Grafana/wrk.
