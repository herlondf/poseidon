# Poseidon — Avaliação de Maturidade (2026-07-14) — #213 resolvido

> Continuação do documento vivo `MATURIDADE-2026-07-10.md` (com adendos 07-11 e
> 07-13). Esta reavaliação cobre a sessão que **reenquadrou e corrigiu o #213** —
> o portão declarado para passar de 80.

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade (h2spec, Autobahn), auditado por
terceiros. "Correto por leitura" ≠ "correto por prova".

## O que mudou nesta sessão (com evidência)

O #213 era descrito (07-13) como um "heisenbug crash de TLS no Linux, h2spec
1/146". Reenquadrado por repro (gdb + h2spec) e **corrigido** — 8 commits em
master (`fa8cf6d`..`0e23df0`):

- **Causa-raiz real:** acesso concorrente ao mesmo `SSL*`/`H2Conn`/`AccumBuf`
  entre a thread de IO (epoll) e o worker pool → corrupção de heap. Corrigido com
  **lock por conexão** serializando a trilha SSL.
- **UAF do H2Conn** no teardown durante o dispatch (confirmado por backtrace gdb)
  — corrigido deferindo a liberação ao `TNativeConn.Destroy` (endereça a classe
  do #196).
- **SIGPIPE** ignorado globalmente (o servidor era morto por reset de conexão).
- **ALPN** passou a negociar `h2` (bug de ordem `ConfigureSSL`/`EnableHTTP2`).
- **Conformidade HTTP/2**: validação de frames RFC 7540, erros HPACK/content-
  length/pseudo-header, dyn-table-size, flow-control drain, fragmento truncado.

**Resultado provado:** h2spec **1/146 → 143/146**, **ZERO crashes** (146 testes ×
múltiplas runs), processo estável sobre TLS no Linux. DUnitX **426/445** (as 19
são ambientais de Winsock, #203), gate de 2 faces **PASSED**, sem regressão.

**Achado NOVO honesto (não corrigido):** sob ~100 streams rápidos sobre TLS há
**corrupção de record TLS** (`bad record MAC` / `received record with version
XXX`) — testes `concurrent-stream-limit` e `DATA-not-open`. Uma tentativa de fila
de envio no epoll **não eliminou** a corrupção (só mudou de forma) e foi
revertida (hot path, não-benchmarkável agora). Causa-raiz mais profunda que o
buffer — provável interação SSL BIO/record. **Não é crash** (processo estável),
mas é risco de correção sob carga. Regra de ouro: achar bug nesta rodada = há
mais → segura concorrência/prontidão.

## Pontuação por dimensão (Δ vs 07-13)

| Dimensão | 07-13 | **07-14** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança; shared-nothing sólido. |
| Performance | 85 | **85** | Não medido nesta sessão; o lock por conexão **adiciona custo no hot path SSL — não benchmarkado** (incerteza). |
| Correção HTTP/1.1 | 88 | **88** | Sem mudança; parser fuzzado. |
| Correção HTTP/2 | 72 | **80** | h2spec **1/146 → 143/146** = conformidade PROVADA (não por inspeção). Segura em 80: não-verde + corrupção TLS sob carga aberta. |
| Correção WebSocket | 81 | **81** | Sem mudança; **Autobahn ainda não rodado**. |
| Segurança | 83 | **83** | Frame-validation fecha superfícies de abuso, mas sem auditoria/fuzzing novo desta sessão. |
| Concorrência / thread-safety | 72 | **76** | Corrida/UAF do #213 **eliminada e provada** (zero-crash). Segura: corrupção TLS sob carga (#11) + gap do send path (EPOLLOUT fora do lock) abertos. |
| Segurança de memória / recursos | 76 | **78** | UAF do H2Conn corrigido; lifetime de conexão endurecido. |
| Portabilidade | 85 | **85** | Sem mudança; SIGPIPE é correção Linux. Gate compila 2 faces; testa 1. |
| Robustez / estabilidade | 72 | **78** | Crash eliminado (provado sob h2spec); SIGPIPE (sobrevive a resets); estável sobre TLS. Segura: sem soak, v2 fora de prod, #11. |
| Cobertura de testes | 69 | **73** | h2spec REAL a 143/146 (era 1/146); testes DUnitX HTTP2/HPACK atualizados. Falta Autobahn/soak/integração-verde. |
| API / DX | 82 | **82** | Sem mudança. |
| Documentação | 75 | **75** | Commits bem documentados; falta ref de API/changelog. |
| Ecossistema / features | 80 | **80** | Sem mudança. |
| Prontidão para produção | 60 | **66** | TLS-Linux **estável** (era "not production-ready"); zero crash; h2spec 143/146. Segura forte: #11 sob carga, sem soak, lock não-benchmarkado, v2 ainda fora de prod. |
| Qualidade / manutenibilidade | 83 | **83** | Fixes limpos, testados, sem regressão. |

## Nota geral honesta: **~80/100**

Média ponderada (reliability-critical ×3, importantes ×2, contexto ×1) ≈ **79,5**.
O **portão #213 está objetivamente resolvido** — o bloqueador específico foi
corrigido e provado (zero-crash, 143/146). Mas a nota fica **no piso de "passou"**,
não confortavelmente acima: nesta mesma rodada surgiu um problema real de
correção sob carga (#11) e o fix de concorrência tem um custo de hot path
**ainda não benchmarkado**. Inflar para 82+ seria desonesto.

## Veredito
**Passou o portão de 80 — TLS/HTTP2 no Linux deixou de ser "quebrado por prova"
e virou "conforme por prova (143/146) e estável".** Ainda **não** é
battle-hardened para crítico: falta fechar a corrupção TLS sob carga extrema,
Autobahn, soak, e benchmarkar o lock. A META de 85 (#211) continua distante.

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **Prontidão (66) — o #11 (corrupção TLS sob carga) + ausência de soak.**
   Move: fechar #11 com packet-capture/inspeção SSL, depois soak em staging (#205).
2. **Cobertura de testes (73) — sem Autobahn nem soak; integração ambiental.**
   Move: rodar Autobahn no Linux (mesma infra WSL do h2spec) (#199) + soak (#205).
3. **Concorrência (76) — #11 aberto + send path (EPOLLOUT) fora do lock de conexão.**
   Move: fechar #11 e trazer o send path do epoll para a serialização por conexão,
   com benchmark.

## O que NÃO preocupa (fortes reais)
- **O #213 acabou de fato** — o crash de TLS/HTTP2 no Linux foi eliminado e
  provado sob h2spec (zero WORKER_EX em 146 testes × runs), não "sumiu com
  logging".
- **Conformidade HTTP/2 real** (143/146), não mais por inspeção.
- **Arquitetura, HTTP/1.1 (fuzzado), Performance** seguem fortes.
- **Disciplina de validação:** cada fix passou por gate 2-faces + DUnitX sem
  regressão; os testes que afirmavam comportamento não-conformante foram
  corrigidos, não contornados.

## Plano de ação (atualizado)
- **P0 correção:** fechar **#11** (corrupção TLS sob carga — packet-capture +
  estado SSL + benchmark do send path); **#199** Autobahn (WebSocket).
- **P1 operacional:** **#205** soak/endurance; benchmarkar o lock por conexão
  (regressão de perf do #213).
- **P2 concorrência:** trazer o send path do epoll (EPOLLOUT) para o lock de
  conexão; **#207** auditoria de lifetime/refcount; fechar **#196** formalmente.
- **P3 quick wins:** máquina de estados half-closed (3 testes h2spec flaky);
  **#210** ref de API/changelog.
- **P4 segurança:** **#209** auditoria dirigida (TLS/FFI OpenSSL, JWT/Digest, DoS).
