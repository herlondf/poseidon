# Poseidon — Avaliação de Maturidade & Plano de Ação (2026-07-10)

Baseado em: revisão profunda de todo o `src/` + `middlewares/` (rodadas 07-08/07-09/07-10),
primeiro benchmark real (ping, WSL2/Docker), e **evidência de produção** (logs AWS ECS
Fargate `docfiscal-nfce-api-prd` — API fiscal NFC-e em produção).

## Calibração
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em escala,
fuzzado, passando em suites de conformidade (h2spec, Autobahn), auditado por terceiros.
Não é "código bonito" — é "eu confiaria a transação de um banco nisso hoje".

## Pontuação por dimensão

| Dimensão | Nota | Justificativa (evidência) |
|---|---:|---|
| Arquitetura & design | 88 | Shared-nothing per-core, IOCP/RIO + epoll/io_uring (SEND_ZC), pools, SOLID/GoF. Topo. |
| Performance | 85 | Nativo, hot-path quase zero-alloc, **6× o Horse** na mesma caixa, memória minúscula. Teto alto; medido pela 1ª vez agora. |
| Correção HTTP/1.1 | 85 | Defesas de smuggling verificadas, chunked, edge cases sólidos. |
| Correção HTTP/2 | 70 | Bom hardening, mas **nunca rodou h2spec**; achei gaps de conformidade (stream-id, CONTINUATION, índice HPACK). "Correto por leitura", não por suite. |
| Correção WebSocket | 78 | Conforme RFC 6455/7692 após esta sessão — **Autobahn não rodado**. |
| Segurança | 78 | Fortes (smuggling, CIDR fail-close, JWT alg/const-time, Digest replay). Mas achei bugs reais hoje (JWT leak DoS, cache cross-user). Sem fuzzing/auditoria. |
| Concorrência / thread-safety | 74 | Refcount/atômicos cuidadosos, mas achei **UAF CRITICAL** + io_uring ZC + SSL drain; **#196 (close diferido) = UAF latente aberto**. |
| Segurança de memória / recursos | 75 | Bem gerido, mas leaks encontrados; disciplina manual (sem GC). |
| Portabilidade | 80 | Dual-face genuíno; validei as duas em cada fix. CI compila 1 face por vez (latente). |
| Robustez / estabilidade | **68** | Muitos edge cases tratados; loop de DoS em erro / UAF no shutdown corrigidos. Mas #171 (validação Linux formal) aberto e **o v2 NÃO está em produção** (o que está em prod é o v1). Estabilidade do v2 sob carga real = não provada. |
| Cobertura de testes | 55 | ~430 testes DUnitX (unit sólido), mas **integração não passa localmente**, **zero fuzzing/h2spec/Autobahn**, sem soak em CI, maioria dos fixes sem regressão. **Elo mais fraco.** |
| API / DX | 82 | Fluent limpa, 20 middlewares, fachada, RFC 7807, validação por atributos. |
| Documentação | 74 | README bilíngue + playbook + skills. Falta referência de API, changelog. |
| Ecossistema / features | 80 | TLS/mTLS, gzip/brotli, WS, H2, proxy protocol, graceful reload, Horse-compat. Alguns dormentes. |
| **Prontidão para produção** | **56** | O que está em prod (ECS Fargate, API fiscal NFC-e) é o **v1**, não o v2 revisado — prova a intenção de produção + capacidade de ops do time, **não o código do v2**. v2: sem soak, sem CI-matrix das 2 faces, sem auditoria, drift da cópia vendorizada. |
| Qualidade / manutenibilidade | 83 | SOLID, padrões, nomenclatura consistente, legível; skills impõem disciplina. |

## Nota geral honesta: **~74/100**

Ponderando correção/segurança/concorrência/robustez/testes mais pesado.
(Correção: o v1 em produção não valida o v2 — sem esse crédito, geral = 74, não 76.)

**Veredito:** framework impressivo e bem-arquitetado, com performance/design de nível alto
— "production-grade para uso não-crítico". O v2 **ainda não** foi validado em produção
(o v1 é que está lá). O caminho para 85+ **não é reescrever**; é **PROVAR** (conformidade
+ fuzzing + validação formal + soak) o que hoje está "correto por inspeção".

---

# 🎯 META: ≥85 como GATE para subir o v2 em produção

**Regra:** a nota não sobe por decreto — sobe quando a evidência sobe. Cada ponto
abaixo é um artefato/prova concreta. Marque só quando FEITO e VERDE.

## Perfil-alvo (o que cada dimensão precisa virar → média ponderada ≥85)

| Dimensão | Hoje | Alvo | O que fecha o gap (a PROVA) |
|---|---:|---:|---|
| Cobertura de testes | 55 | **85** | h2spec + Autobahn + fuzzing parser/HPACK + regressão dos fixes + integração VERDE |
| Prontidão produção | 56 | **82** | v2 em soak (staging) + CI das 2 faces + #171 + observabilidade validada |
| Robustez | 68 | **85** | #171 (Linux epoll+io_uring real sob carga) + #196 + soak sem leak/crash |
| Concorrência | 74 | **85** | #196 (close diferido) + auditoria dedicada de lifetime/refcount |
| Correção HTTP/2 | 70 | **88** | **h2spec passando** |
| Correção WebSocket | 78 | **88** | **Autobahn passando** |
| Segurança | 78 | **85** | fuzzing + auditoria dirigida (TLS/FFI, auth, DoS) |
| Memória/recursos | 75 | **84** | auditoria de lifetime + testes de leak/soak |
| Portabilidade | 80 | **85** | CI compilando+testando as 2 faces |
| Performance | 85 | **88** | teto real medido fora do bridge (host-net/bare-metal) + gate de regressão (#98) |
| HTTP/1.1 | 85 | **90** | fuzzing do parser (sela as defesas de smuggling) |
| Docs / API / Ecossistema / Qualidade / Arquitetura | 74-88 | +2-4 | referência de API + changelog; polir DX; #197 |

Com esse perfil, a **média ponderada passa de 85 folgado**. Sem os P0/P1, não passa —
inflar o número seria mentir para si mesmo antes de um deploy fiscal.

## Ordem de execução (gate)
1. **P0 testes/conformidade** — maior alavanca (move testes, HTTP/2, WS, segurança, robustez de uma vez).
2. **P1 operacional** — CI 2 faces + #171 + soak do v2 em staging.
3. **P2 concorrência** — #196 + auditoria de lifetime.
4. **P3/P4** — quick wins (#197, log-level) + auditoria de segurança.

Só depois que P0+P1+P2 estiverem VERDES a nota chega a 85+ **de verdade** — e aí sim
o deploy do v2 está justificado.

---

# Plano de ação (priorizado por quanto move a agulha)

## P0 — Provar correção (maior alavanca; sobe HTTP/2, WS, testes, robustez)
- [ ] **h2spec** contra o servidor HTTP/2 → fechar os gaps que aparecerem.
- [ ] **Autobahn TestSuite** contra o WebSocket → conformidade provada.
- [ ] **Fuzzing do parser** HTTP/1 (e HPACK) — libFuzzer/AFL sobre `ParseHTTP1Request`/`DecodeHeaders`.
- [ ] **Teste de regressão para cada fix** desta sessão (hoje a maioria não tem) — travar o que foi corrigido.
- [ ] Fazer os testes de **integração passarem** em ambiente real (hoje 7 fail/12 error — #171).

## P1 — Maturidade operacional
- [ ] **#171** — validação formal em Linux (epoll **e** io_uring) sob carga; documentar.
- [ ] **CI compilando as DUAS faces** (Win IOCP/RIO + Linux epoll/io_uring) — hoje bugs de plataforma ficam latentes.
- [ ] **Sync automatizado** `vendor/poseidon-v2` ← canônico no repo Benchmark (evitar drift que já enganou medições).
- [ ] **Benchmark contínuo** (gate de regressão de perf) — fechar #98; medir teto real fora do bridge WSL/Docker.

## P2 — Concorrência / lifetime
- [ ] **#196** — refactor de close diferido no HTTP/2 (eliminar o UAF latente / leitura de flag em memória liberada).
- [ ] Auditoria dedicada de lifetime/refcount (o ritmo de achados sugere que ainda há).

## P3 — Quick wins (baixo esforço, valor real)
- [ ] **Log de idle-close em nível ERROR → INFO/DEBUG** (`IdleSweep.pas`: `FOnLog(llError, '[sweep] idle close...')`). Visto poluindo o log de erro em produção.
- [ ] Fechar itens do **#197** (perf M14/M25/HPACK-O(n²), q-value Cache/Compression, io_uring P2 comp-thread) — agora benchmark-gated.

## P4 — Segurança
- [ ] Auditoria de segurança dedicada (ou externa) — foco em TLS/FFI OpenSSL, auth (JWT/Digest), e superfície de DoS.

---

## Issues abertas relacionadas
- **#171** — validação de ambiente (P0/P1). **#196** — close diferido HTTP/2 (P2). **#197** — umbrella LOW/perf (P3). **#98** — benchmark contínuo (P1).

_Documento vivo — reavaliar após cada rodada. Skill `poseidon-maturity` gera a nota atualizada sob demanda._
