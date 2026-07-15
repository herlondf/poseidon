# Poseidon — Avaliação de Maturidade (2026-07-15) — #11/#3/#199 resolvidos

> Continuação do documento vivo `MATURIDADE-2026-07-14.md`. Esta reavaliação cobre
> a sessão que **fechou os três fatores que a avaliação de 07-14 apontou como os
> que mais seguravam a nota**: #11 (corrupção TLS sob carga), Autobahn (WebSocket)
> e half-closed(remote).

## Âncora
**100** = servidor battle-tested tipo nginx/Envoy: anos em produção crítica em
escala, fuzzado, passando suites de conformidade (h2spec, Autobahn), auditado por
terceiros. "Correto por leitura" ≠ "correto por prova".

## O que mudou nesta sessão (com evidência)

Em 07-14 os três fatores que "mais seguram a nota" eram: (1) #11 corrupção TLS sob
carga, (2) ausência de Autobahn, (3) send path fora da serialização por conexão.
**Os três foram fechados com prova nesta sessão.**

- **#11 corrupção de record TLS sob carga — RESOLVIDO** (`602635d`). A causa-raiz
  NÃO era epoll (backend nomeado no diagnóstico antigo), era o **io_uring** (backend
  Linux PADRÃO): múltiplas SQE de SEND independentes por conexão, sem ordenação →
  records TLS intercalavam → `bad record MAC`. Fix = **um send em voo por conexão +
  backlog ordenado**. Resultado provado: corrupção **19/20 runs → 0/20**. Isto
  também trouxe o send path para a serialização por conexão (o item P2 aberto).
- **#3 half-closed(remote) — RESOLVIDO** (subsumido). Os 3 testes h2spec flaky eram
  artefato da corrupção do #11; agora passam. **h2spec 143/146 → 145/146** (0 falha,
  1 skip).
- **#199 WebSocket / Autobahn — RESOLVIDO** (`0624238` + `8671463`). Autobahn|Test-
  suite: **core (1–8,10,11) = 247/247** e **9.\* large payload = 42/42**, ZERO falhas
  (245 de UTF-8/framing/close inclusos). Causa-raiz do >4 MB era `StepSizeCheck`
  aplicando `MaxRequestSize` a conexões WS (413 + close antes do echo).
- **Achados honestos NOVOS desta rodada (corrigidos, mas sinalizam mais no send
  path io_uring):** dois bugs de heap no SEND io_uring — (a) resubmit de `SEND_ZC`
  parcial fazia `Acquire` sem tamanho → **overflow de heap**; (b) `-EAGAIN` com
  socket buffer cheio **fechava a conexão**. Ambos em `8671463`. Regra de ouro:
  achar 2 bugs de memória no send path nesta rodada = há risco de mais → segura
  concorrência/memória.

**Ainda NÃO provado:** soak de horas (só ~50 min, sem leak — #205); o lock/backlog
por conexão **não foi benchmarkado rigorosamente** (ping leve deu 11.8K vs 10.6K =
sem regressão aparente, mas não é medição séria); HPACK fuzzing contínuo (#201);
Autobahn 9.7–9.9 e 12.*/13.* (permessage-deflate); suite de integração ainda
vermelha por ambiente (19 Winsock, #203). **v2 segue fora de produção.**

## Pontuação por dimensão (Δ vs 07-14)

| Dimensão | 07-14 | **07-15** | Justificativa com evidência |
|---|---:|---:|---|
| Arquitetura & design | 88 | **88** | Sem mudança; shared-nothing sólido. |
| Performance | 85 | **85** | Ainda não medido a sério; ping leve sem regressão pós-#11, mas o backlog de send **não foi benchmarkado** (incerteza mantida). |
| Correção HTTP/1.1 | 88 | **88** | Sem mudança; parser fuzzado (fuzz in-process). |
| Correção HTTP/2 | 80 | **84** | h2spec **143 → 145/146** (0 falha, 1 skip); half-closed fechado. Segura: HPACK sem fuzzing contínuo (#201); 1 skip. |
| Correção WebSocket | 81 | **86** | Autobahn **PROVADO 247/247 core + 42/42 large** (era "não rodado"). Segura: deflate 12/13 e 9.7–9.9 não testados. |
| Segurança | 83 | **83** | Sem auditoria nova (#209 aberto); frame-validation já contava. |
| Concorrência / thread-safety | 76 | **80** | Send path agora **serializado por conexão** (io_uring) — fecha o gap aberto em 07-14 + a corrupção #11 provada 0/20. Segura: 2 bugs de heap no send desta rodada = mais no path; #207 sem auditoria. |
| Segurança de memória / recursos | 78 | **79** | 2 overflow/UAF-adjacentes do send io_uring corrigidos; mas achá-los aqui indica superfície ainda quente. |
| Portabilidade | 85 | **85** | Sem mudança. io_uring confirmado como backend padrão Linux; epoll fallback. Compila 2 faces, testa 1. |
| Robustez / estabilidade | 78 | **81** | Corrupção TLS sob carga eliminada (0/20); -EAGAIN não derruba mais. Segura: sem soak de horas; v2 fora de prod. |
| Cobertura de testes | 73 | **77** | **Autobahn** entra (247/247+42/42); h2spec **145/146**; harness WS commitado. Falta soak-horas, HPACK fuzz contínuo, integração-verde. |
| API / DX | 82 | **82** | Sem mudança. |
| Documentação | 76 | **76** | Relatórios (#199, #11) bem documentados; falta ref de API/changelog (#210). |
| Ecossistema / features | 80 | **80** | Sem mudança. |
| Prontidão para produção | 66 | **71** | O **maior bloqueador (#11) caiu** com prova; WebSocket conforme; h2spec 145. Segura forte: sem soak de horas, lock não-benchmarkado, integração ambiental vermelha, **v2 ainda fora de prod**. |
| Qualidade / manutenibilidade | 83 | **83** | Fixes limpos, gate 2-faces + DUnitX sem regressão. |

## Nota geral honesta: **~82/100**

Média ponderada (reliability-critical ×3, importantes ×2, contexto ×1) ≈ **81,6**.
Subiu de ~80 para ~82 e a alta é **inteiramente lastreada em prova**: os três itens
que a própria avaliação anterior listou como "o que mais segura a nota" foram
fechados com evidência de conformidade (h2spec 145/146, Autobahn 247/247+42/42) e
com repro/regressão do #11 (0/20). Não é inflação — é o gate anterior cobrado.

**Por que não 84+:** nesta mesma rodada apareceram 2 bugs de heap no send io_uring
(sinal de superfície quente), o backlog de send não foi benchmarkado, não há soak
de horas, a suite de integração segue vermelha por ambiente e **o v2 nunca rodou em
produção**. Correção subiu muito; *prontidão* (71) continua sendo o teto real.

## Veredito
**Conformidade de protocolo agora é PROVADA nas três frentes (HTTP/2 145/146,
WebSocket 247/247, TLS estável sob carga), não por inspeção.** Poseidon é
production-grade para cargas não-críticas; **ainda não battle-hardened para crítico**
— falta soak de horas, benchmark do send path, auditoria de lifetime (#207) e,
sobretudo, quilometragem real em produção. META de 85 (#211) está perto, mas
depende de *operação/prova sustentada*, não de mais correção de protocolo.

## Top 3 fatores que mais seguram a nota (e o que move cada um)
1. **Prontidão (71) — sem soak de horas nem produção real.**
   Move: soak/endurance de horas em host Linux/CI (#205, contornar limite WSL) +
   colocar o v2 atrás de tráfego real de staging.
2. **Cobertura de testes (77) — falta fuzzing contínuo e integração verde.**
   Move: fuzzing HPACK (#201) e HTTP/1 smuggling (#200) em loop no CI; destravar a
   suite de integração ambiental (#203); CI 2 faces testando de fato (#204).
3. **Concorrência/memória (80/79) — send path io_uring ainda "quente".**
   Move: auditoria de lifetime/refcount (#207) focada no send io_uring (mexi em
   refcount lá) + benchmark rigoroso do backlog de send (regressão do #11).

## O que NÃO preocupa (fortes reais)
- **As três frentes fecharam de fato:** #11 com repro/regressão (0/20), Autobahn
  247/247, half-closed passando — tudo provado, não "sumiu com logging".
- **Conformidade de protocolo real** nas três camadas (HTTP/2 145/146, WS 247/247,
  HTTP/1 fuzzado).
- **Disciplina de validação:** cada fix passou por gate 2-faces + DUnitX sem
  regressão; a regressão indireta (overflow ZC) foi caçada e fechada na mesma rodada.
- **Arquitetura, HTTP/1.1, API** seguem fortes e estáveis.

## Plano de ação (atualizado)
- **Higiene imediata:** **fechar no GitHub** #11, #3, #199, #198, #213 (resolvidos,
  ainda OPEN) e atualizar #211 com o novo snapshot.
- **P0 correção/testes:** **#201** fuzzing HPACK, **#200** fuzzing HTTP/1 (as duas
  superfícies de smuggling/overflow ainda sem fuzzing contínuo); **#202** regressão
  dos fixes de julho.
- **P1 operacional:** **#205** soak de HORAS (host Linux/CI, não WSL); benchmark
  rigoroso do backlog de send; **#204** CI 2 faces testando; **#203** integração
  verde; **#206** auto-sync do vendor.
- **P2 concorrência:** **#207** auditoria de lifetime/refcount do send io_uring;
  fechar **#196** formalmente.
- **P4 segurança:** **#209** auditoria dirigida (TLS/FFI OpenSSL, JWT/Digest, DoS).
