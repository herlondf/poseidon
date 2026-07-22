# Poseidon — Avaliação de Maturidade (2026-07-22) — fuzzing contínuo + N-rings io_uring

> Continuação do documento vivo `MATURIDADE-2026-07-17.md`. Esta reavaliação
> cobre o que mudou desde então: fuzzing contínuo mergeado (#217, PR #222),
> a correção de escala do io_uring (#220), e duas descobertas de processo
> feitas NESTA sessão (não estavam documentadas em 07-17).

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade, auditado por terceiros.
"Correto por leitura" ≠ "correto por prova".

## O que mudou desde 07-17 (com evidência)

- **#217 fuzzing contínuo — FECHADO e MERGEADO (PR #222).** CI gate por push +
  job nightly (`fuzz-nightly.yml`, `FUZZ_SCALE`/`FUZZ_SEED`) + nova fixture
  `TFuzzWebSocketUtf8Tests` (RFC 3629). **Reexecutei localmente nesta sessão**:
  build limpo (`dcc64`, só hints pré-existentes) e **24/24 fixtures passando**
  em duas rodadas — seed determinístico (escala 1) e seed novo `0xC0FFEE` em
  escala 25× (espaço de entrada bem maior). Zero crash/hang/leak de exceção.
- **#220 io_uring não escalava — bug real encontrado E corrigido, com números.**
  O backend io_uring (default Linux) ficava **flat em ~13k RPS / 2,3 cores**
  de 16 a 512 conexões — um ponto de serialização real (1 ring/1 completion
  thread). Refatorado para **N rings shared-nothing** (1 por core real via
  `sched_getaffinity`, multishot accept por ring, sem SQPOLL). Depois: RPS
  cresce com a concorrência (32,0k em c=64, +137%), CPU sobe de ~2,3 para
  ~4,1 cores. Regressão zero revalidada pelo autor (DUnitX 342/342, h2spec
  145/146, Autobahn 247/247+42/42) — **não reexecutei h2spec/Autobahn nesta
  sessão** (sem ambiente Linux aqui); tomo como evidência de segunda mão,
  não como prova direta minha.
- **Ctx.Defer / IPoseidonResponder — nova superfície de concorrência.**
  Resposta assíncrona cross-thread (handler devolve depois, de qualquer
  thread). Mecanismo: `AddRef`/`InFlightPool`, flag atômico `Closed`,
  teardown via CAS. 7 testes dedicados (`Poseidon.Tests.DeferredResponse.pas`
  + runner `DeferOnly`), todos verdes. **Não há registro de uma revisão de
  concorrência independente sobre esta feature especificamente** — é código
  novo e sensível a race condition, auto-descrito e auto-testado, mas sem o
  segundo par de olhos que #207 (lifetime do send io_uring) recebeu.
- **Suite completa cresceu e segue 100% verde.** Rebuild + rerun local nesta
  sessão: **480/480 testes DUnitX, 0 falha, 0 erro, 0 leak** (era 342 em
  07-17→07-21, cresceu com Defer + fuzz). Prova direta minha, não só citação.
- **fix(core): middlewares globais agora rodam para paths sem rota casada**
  — bug de dispatch real que existia até 07-20 (dois dias atrás).

### Duas descobertas de PROCESSO feitas nesta sessão (novas, não estavam em 07-17)

1. **CI configurado mas NÃO executa.** `gh api repos/herlondf/poseidon/actions/runners`
   → `total_count: 0`. Os workflows (`build-both-faces`, `compile-and-test`,
   `fuzz-nightly`) exigem `runs-on: [self-hosted, windows, delphi]` (precisam
   de `dcc64`) e **não há nenhuma máquina registrada**. O PR #222 ficou com
   2/3 checks vermelhos por **timeout de 24h esperando runner** — não por
   bug. Ou seja: o gate de "CI dual-face + fuzz nightly" que embasa parte da
   nota de Cobertura de testes e Prontidão **existe no papel, mas está
   dormente** até uma máquina Windows+Delphi ser registrada.
2. **Branch protection exige 1 review, mas é rotineiramente contornada.**
   `required_approving_review_count: 1`, mas o autor não pode aprovar o
   próprio PR e não há segundo revisor humano no projeto. O merge do #222
   nesta sessão só foi possível via `gh pr merge --admin` (bypass, já que
   `enforce_admins: false`). Isso é esperado para um projeto solo, mas é uma
   lacuna real de processo que a configuração do repo não deixa óbvia —
   "review obrigatório" é hoje um checkbox sem efeito prático.

## Pontuação por dimensão (Δ vs 07-17)

| Dimensão | 07-17 | **07-22** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança estrutural; N-rings segue o mesmo padrão Strategy já usado pelo epoll. |
| Performance | 85 | **86** | Bug real de escala encontrado e corrigido com números antes/depois (wrk, medianas de 3 reps); mas ainda sem benchmark pesado/rigoroso (#218 aberto) e o próprio autor documenta ~3-4× de gap de custo-por-request vs mORMot2 — honesto, não escondido. |
| Correção HTTP/1.1 | 88 | **88** | Sem mudança nesta janela (fix de middleware é de dispatch/roteamento, não do parser). |
| Correção HTTP/2 | 85 | **85** | Sem mudança nesta janela. |
| Correção WebSocket | 86 | **87** | Fuzzing contínuo de UTF-8 (RFC 3629) fecha um gap real de validação de frame texto/close; 3/24 fixtures novas verificadas por mim nesta sessão. |
| Segurança | 84 | **84** | Sem mudança nesta janela. |
| Concorrência / thread-safety | 83 | **82** | Ctx.Defer adiciona superfície cross-thread nova (AddRef/CAS/flag atômico) sem revisão de concorrência independente registrada; N-rings io_uring é reescrita recente do modelo de threads do backend Linux default — ainda sem tempo de maturação equivalente ao que o single-ring tinha. |
| Segurança de memória / recursos | 83 | **81** | O soak de 5,4h que provou "memória flat" (`SOAK-205`) rodou **antes** do refactor N-rings (#220, fechado 4 dias depois). A prova de ausência de leak vale para a arquitetura ANTIGA do io_uring — a atual (N completion threads, ring ownership por conexão) ainda não tem seu próprio soak. |
| Portabilidade | 87 | **87** | Sem mudança nesta janela (#219 FPC follow-ups seguem abertos). |
| Robustez / estabilidade | 85 | **84** | Mesma ressalva acima: o headline de endurance (5,4h/5,4M req/0 falha) é sobre um binário que já não é o que roda em `master` no backend io_uring — não invalida a prova, mas ela não cobre 100% do código atual. |
| Cobertura de testes | 82 | **84** | Suite cresceu 342→**480 testes, 100% verde** (rodei eu mesmo, não só citação); fuzzing agora tem WS UTF-8 + infra de nightly com FUZZ_SCALE/SEED. Ressalva: o nightly **não roda de fato ainda** (sem runner) — é cobertura configurada, não exercitada em produção de CI. |
| API / DX | 82 | **83** | Ctx.Defer/IPoseidonResponder é uma capacidade nova real (resposta assíncrona cross-thread) com 7 testes dedicados; sample 10 (dashboard) somado. |
| Documentação | 78 | **79** | `FUZZING.md` novo + playbook EN/PT-BR atualizados em sincronia para #217. |
| Ecossistema / features | 80 | **81** | Sample 10 (dashboard tempo real) + Ctx.Defer como capacidade nova de app. |
| Prontidão para produção | 77 | **76** | O bloqueador nº1 (produção real / soak do app completo, #215) segue sem mover. Nesta sessão descobri que o "gate de CI" que sustentava parte da confiança em Prontidão **não executa** (zero runners) e que "review obrigatório" é bypassado por padrão — a disciplina de processo é mais fraca na prática do que a configuração sugere. |
| Qualidade / manutenibilidade | 84 | **83** | Mesma razão: branch protection com review obrigatório existe só no papel para um projeto solo; isso não é um defeito de código, mas é uma lacuna real de garantia de processo que eu não tinha visibilidade em 07-17. |

## Nota geral honesta: **~84/100 → ~84/100 (essencialmente estável)**

Média ponderada (reliability-critical ×3: correção HTTP/1-2-WS, segurança,
concorrência, memória, robustez, testes, prontidão; importantes ×2:
performance, portabilidade, API, qualidade; contexto ×1: arquitetura, docs,
ecossistema) ≈ **83,7**.

A nota fica praticamente **flat** — mas o "flat" esconde movimento real em
ambas as direções, não estagnação: fuzzing contínuo, correção de escala do
io_uring com prova numérica e crescimento saudável da suite (342→480, 100%
verde, verificado por mim) **empurram para cima**; a descoberta de que a
prova de endurance (#205) é anterior a uma reescrita relevante do backend
Linux, que Ctx.Defer é concorrência nova sem segundo revisor, e que o
próprio gate de CI/review não está de fato em vigor **empurram para baixo**
em quase a mesma medida. Isso não é uma crítica ao trabalho da semana — é
exatamente o tipo de achado que uma reavaliação honesta deve capturar em vez
de simplesmente somar "mais uma feature fechada = nota sobe".

## Veredito
**Poseidon segue production-grade para cargas não-críticas, com evidência real
de progresso em duas frentes concretas (fuzzing contínuo, escala do io_uring)
— mas dois pilares que sustentavam a confiança da avaliação anterior
(endurance provada, gate de CI) hoje cobrem uma fatia menor do código/processo
reais do que pareciam cobrir em 07-17.** Não regrediu de fato; ficou mais
honesto sobre o que ainda não está coberto.

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **Prontidão (76) — CI dormente + review sempre bypassado + sem produção
   real.** Move: registrar ao menos 1 runner self-hosted Windows+Delphi (esta
   própria máquina já tem RAD Studio 22.0) para o gate parar de ser só
   papel; soak do app completo (#215); tráfego real de staging.
2. **Robustez/Concorrência/Memória (84/82/81) — prova de endurance está
   desatualizada em relação ao master atual.** Move: novo soak de horas
   específico pós-N-rings (io_uring) + uma revisão de concorrência dedicada
   a Ctx.Defer (padrão #207).
3. **Performance (86, ainda não rigorosa) — falta benchmark pesado real
   (#218).** Move: carga pesada de verdade (não 300/s), comparativo vs
   nginx/mORMot2, fechar o gap de custo-por-request documentado no próprio
   #220.

## O que NÃO preocupa (fortes reais)
- **Disciplina de prova, não vibe:** o autor mede antes/depois com números
  reais (io_uring) e fecha bugs de escala com dados, não com "deve ter
  melhorado".
- **Suite crescendo e 100% verde**, verificado nesta sessão de forma direta
  (não citação de relatório antigo): 480/480, 24/24 fuzz em duas escalas.
- **Honestidade pré-existente no próprio código/issues:** o autor documenta o
  próprio gap de performance vs mORMot2 no texto do #220 em vez de esconder.
- **Zero regressão de conformidade** relatada ao longo do refactor de
  concorrência mais arriscado da janela (N-rings).

## Plano de ação (atualizado)
- **P0 processo:** registrar runner self-hosted (esta máquina serve) para o
  CI parar de ser dormente; decidir conscientemente se review obrigatório
  faz sentido para projeto solo ou se deve ser removido da branch protection
  (hoje é uma promessa não cumprida, pior que não ter a regra).
- **P0 concorrência:** soak de horas pós-N-rings (io_uring) + revisão de
  concorrência dedicada a Ctx.Defer.
- **P1 prontidão real:** #215 (soak do app completo) e tráfego de staging.
- **P1 perf:** #218 (benchmark pesado e comparativo).
- **P2 testes:** #216 (Autobahn 12/13 + 9.7-9.9, h2spec 146/146).
- **P2 FPC (#219):** async worker-pool sob FPC, suite DUnitX sob FPC, Lazarus.
- **Higiene:** atualizar #211 com este snapshot (~84, estável; achados de
  processo novos que a meta de 85 também precisa fechar, não só correção).
