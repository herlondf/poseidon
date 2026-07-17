# Poseidon — Avaliação de Maturidade (2026-07-17) — soak de horas + FPC

> Continuação do documento vivo `MATURIDADE-2026-07-15.md`. Esta reavaliação cobre
> duas evidências novas provadas com prova direta: (1) o **soak de horas** (#205),
> que era o **fator nº1 que mais segurava a nota** em 07-15, e (2) **portabilidade
> FPC** (compila+SERVE sob um segundo compilador em Win e Linux, #5).

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade, auditado por terceiros.
"Correto por leitura" ≠ "correto por prova".

## O que mudou desde 07-15 (com evidência)

- **#205 soak de HORAS — FECHADO com prova** (`SOAK-205-2026-07-17.md`). **5,4 h**
  de carga sustentada (`soak-containers.sh 18000 300`): **5.404.455 req, 0,00%
  falha**, checks 100%, p95 5,11 ms; **anon 2,14→4,52→4,51 MiB = PLATÔ (0,000
  MiB/h, +0,0 KiB em 259 min pós-warmup)**; fd 7–10 estável; rss flat; **0 crash /
  0 erro** no log do app. 15% via `/error/500` = ~810k exercícios do `Release` do
  refcount na exceção — **sem vazar**. Fecha o item que a própria avaliação de
  07-15 listou como "o que mais segura a nota" (Prontidão). Nota: o "soak de 3h"
  de 07-16 na verdade morreu ~49 min (lifetime WSL); a solução foi rodar tudo em
  container detached sob dockerd (independe de `wsl.exe`).
- **#5 FPC/Lazarus — servidor SERVE sob um segundo compilador, Win + Linux.** O
  Poseidon agora compila, linka e **atende HTTP** sob FPC 3.3.1 em Win64 (IOCP) e
  Linux-x86_64 (io_uring/epoll), além do Delphi. Prova de runtime nos dois: 2 ok /
  0 fail (`build-server-fpc.ps1` / `build-linux-fpc.sh`). Portar para uma segunda
  toolchain expôs zero bug de lógica (só divergências de binding) — sinal de
  portabilidade real, não só "compila 2 faces".
- **Contexto desde 07-15 (sessões anteriores, ver roadmap):** #200/#201 fuzzing
  (smuggling HTTP/1 + HPACK) FECHADOS com guardas determinísticos + fuzz runner
  socket-free; #203 (flake "Winsock") reenquadrado como **bug real de IOCP** e
  corrigido; #204 CI 2-faces; #207 (lifetime send io_uring) auditado limpo +
  ZC-EAGAIN validado em runtime (h2spec 145/146 + Autobahn 247/247+42/42 em kernel
  com ZC ativo); #209 auditoria de segurança (sem CRITICAL/HIGH).

## Pontuação por dimensão (Δ vs 07-15)

| Dimensão | 07-15 | **07-17** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança. |
| Performance | 85 | **85** | p95 5,11 ms sob 300/s por 5h é saudável, mas 300/s é carga leve — **não é benchmark de perf sério**; backlog de send segue não-benchmarkado. Incerteza mantida. |
| Correção HTTP/1.1 | 88 | **88** | Parser fuzzado; #200 smuggling com guardas + fuzz contínuo socket-free. |
| Correção HTTP/2 | 84 | **85** | #201 HPACK fuzzing fechado (invariantes + guardas). h2spec 145/146. Segura: 1 skip. |
| Correção WebSocket | 86 | **86** | Sem mudança; Autobahn 247/247+42/42 mantido; deflate 12/13 e 9.7–9.9 ainda não testados. |
| Segurança | 83 | **84** | #209 auditado (sem CRITICAL/HIGH; renegociação/flood/Digest endereçados). Falta auditoria de 3º. |
| Concorrência / thread-safety | 80 | **83** | Soak exercitou o path de exceção/refcount **~810k vezes em 5,4 h sem vazar**; #207 lifetime do send io_uring auditado limpo + ZC-EAGAIN validado em runtime. Segura: sem prova de produção real. |
| Segurança de memória / recursos | 79 | **83** | **anon flat por 4,3 h pós-warmup (0,000 MiB/h), fd estável, rss flat** sob 5,4 M req — prova forte de ausência de leak no core HTTP. Segura: leak-report de finalização RTL não capturado; soak do app com DB pendente. |
| Portabilidade | 85 | **87** | **Compila+SERVE sob 2 compiladores (Delphi+FPC) em 2 SOs.** Portar não achou bug de lógica. Segura: Lazarus/LCL e macOS fora. |
| Robustez / estabilidade | 81 | **85** | **5,4 h / 5,4 M req / 0 falha / 0 crash / memória flat** — a prova de endurance que faltava. Segura: escopo HTTP puro (sem DB), sem produção real. |
| Cobertura de testes | 77 | **82** | **Soak-horas** entra; #200/#201 fuzzing socket-free; #203 corrigido com repro de alta taxa; #204 CI 2-faces. Falta: soak app-completo, integração 100% verde, Autobahn 12/13. |
| API / DX | 82 | **82** | Sem mudança. |
| Documentação | 76 | **78** | #210 (ref de API + migração + changelog) fechado; relatórios de soak/FPC. |
| Ecossistema / features | 80 | **80** | Sem mudança. |
| Prontidão para produção | 71 | **77** | **O bloqueador nº1 (soak de horas) caiu com prova**; #203 flake era bug real e foi corrigido; CI 2-faces. Segura FORTE: **sem quilometragem em produção real**, sem soak do app completo (DB/NFCe), perf não benchmarkada. |
| Qualidade / manutenibilidade | 83 | **84** | Disciplina de gate 2-faces mantida ao longo do port FPC (nenhum commit quebrou Delphi). |

## Nota geral honesta: **~84/100**

Média ponderada (reliability-critical ×3, importantes ×2, contexto ×1) ≈ **83,8**.
Subiu de ~82 para ~84, **inteiramente lastreada em prova**: o soak de horas — o
item que a avaliação anterior nomeou como o que mais segura a nota — foi fechado
com 5,4 h / 5,4 M req / 0 falha / memória flat; e a portabilidade ganhou um
segundo compilador servindo HTTP em dois SOs. Não é inflação: é o gate anterior
cobrado e pago com evidência direta.

**Por que não 85+ (META #211):** falta o que dinheiro nenhum de teste substitui —
**quilometragem em produção real**. Além disso: o soak foi de `/ping` puro (o app
completo com DB/Postgres/NFCe não foi soakado), a performance nunca foi
benchmarkada a sério, e a suite de integração ainda não está 100% verde. Correção
e robustez estão fortes; *prontidão operacional real* (77) segue sendo o teto.

## Veredito
**Poseidon v2 agora tem prova de conformidade (HTTP/2 145/146, WebSocket 247/247,
HTTP/1 fuzzado) E prova de endurance (5,4 h, 5,4 M req, zero leak/crash) E
portabilidade real (2 compiladores × 2 SOs).** É **production-grade para cargas
não-críticas** e está **a um passo do battle-hardened**: o passo que falta não é
mais correção nem estabilidade sob teste — é **tráfego real de produção** e o soak
do app completo com banco. META de 85 (#211) está ao alcance de uma janela de
staging real.

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **Prontidão (77) — falta produção real e soak do app completo.**
   Move: colocar o v2 atrás de tráfego de staging real por dias; soak de horas do
   app COMPLETO (CRUD/Postgres/NFCe), não só `/ping`.
2. **Performance (85, mas não medida a sério) — sem benchmark rigoroso.**
   Move: benchmark before/after do backlog de send (#98) com carga pesada real,
   não 300/s; comparativo vs concorrentes.
3. **Cobertura de testes (82) — integração não-verde e Autobahn 12/13.**
   Move: destravar 100% da suite de integração; Autobahn permessage-deflate
   (12/13) e 9.7–9.9; fuzzing HPACK/HTTP1 em loop no CI.

## O que NÃO preocupa (fortes reais)
- **Endurance provada:** 5,4 h sob 5,4 M req, memória flat (0,000 MiB/h), 0 crash —
  não é mais "só ~50 min".
- **Conformidade de protocolo real** nas três camadas.
- **Portabilidade real:** um segundo compilador serve HTTP em Win e Linux sem bug
  de lógica — valida a disciplina de arquitetura/abstração.
- **Disciplina de validação:** gate 2-faces + DUnitX verdes ao longo de todo o
  port; soak com harness que sobrevive e verdito por regressão linear.

## Plano de ação (atualizado)
- **P0 prontidão real:** colocar v2 em staging com tráfego real; soak de horas do
  **app completo** (DB/NFCe), não só HTTP puro.
- **P1 perf:** benchmark rigoroso (#98) com carga pesada; comparativo (#47/#98).
- **P1 testes:** integração 100% verde; Autobahn 12/13 + 9.7–9.9; fuzzing em loop.
- **P2 FPC (follow-up #5):** async worker-pool sob FPC (bug de closure do
  compilador), suite DUnitX sob FPC, Lazarus/LCL.
- **Higiene:** atualizar #211 com este snapshot (~84, META 85 a um passo).
