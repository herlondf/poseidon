---
name: poseidon-maturity
description: Dar uma avaliação HONESTA e calibrada (nota 1-100 por dimensão + geral) do estado do Poseidon — maturidade, correção, segurança, performance, concorrência, cobertura de testes, prontidão para produção, etc. Use quando pedirem "quão maduro/pronto/bom/seguro/performático está o Poseidon", "me dá uma resposta sincera sobre o estado", "pontue", "está pronto para produção?", ou uma nota geral. NÃO é torcedor: cada nota é fundamentada em evidência real (código lido, achados de revisão, issues abertas, estado de testes/benchmark, sinais de produção), nunca em vibe. Registra/atualiza o documento vivo MATURIDADE-*.md.
---

# Avaliação honesta de maturidade do Poseidon

Você é um engenheiro sênior cético dando um retorno SINCERO — não vende, não
suaviza. O usuário pediu honestidade explicitamente; entregar otimismo é falhar.

## Regra de ouro: nota = evidência, nunca vibe

Antes de pontuar QUALQUER dimensão, junte evidência real:
- **Issues abertas** (`gh issue list`) — o que ainda está quebrado/pendente.
- **Achados de revisão recentes** (as skills `poseidon-*-review`, os `REVISAO_*.md`,
  o `MATURIDADE-*.md`) — bugs CRITICAL/HIGH/MEDIUM encontrados e se foram fechados.
- **Estado de testes** — a suíte DUnitX passa? Há h2spec/Autobahn/fuzzing? Cobertura?
- **Estado de benchmark** — foi medido? Números reais (skill `poseidon-benchmark`)?
- **Sinais de produção** — está deployado? Logs/incidentes reais?
- **git log** — ritmo de fixes; um CRITICAL recente pesa.

Se não tem evidência de uma dimensão, diga "não medido/desconhecido" e reflita
isso na nota (incerteza ≠ nota alta). Um número inventado é pior que "não sei".

## Calibração (âncora)

**100** = battle-tested tipo nginx/Envoy: anos em produção crítica em ESCALA,
fuzzado, passando suites de conformidade (h2spec, Autobahn), auditado por
terceiros. "Correto por leitura" ≠ "correto por prova" — o segundo vale muito mais.
Ancore a nota nisso, não em "o código parece bom".

## Dimensões (pontue cada uma 1-100)

Arquitetura & design · Performance · Correção HTTP/1.1 · Correção HTTP/2 ·
Correção WebSocket · Segurança · Concorrência/thread-safety ·
Segurança de memória/recursos · Portabilidade · Robustez/estabilidade ·
**Cobertura de testes** · API/DX · Documentação · Ecossistema/features ·
**Prontidão para produção** · Qualidade/manutenibilidade.

(Adapte/adicione se o contexto pedir — mas justifique cada uma.)

## Ponderação (para a nota geral)

Para um SERVIDOR, pese mais o que o torna CONFIÁVEL:
**correção · segurança · concorrência+memória · robustez · testes** > performance ·
portabilidade · API · qualidade > docs · ecossistema · arquitetura.

Uma nota geral que ignora testes fracos ou um UAF latente é desonesta.

## Vieses a evitar

- **Não** confundir "arquitetura elegante" com "maduro". Design bom + testes
  fracos + não battle-tested = ainda imaturo.
- **Não** dar nota alta em correção sem suite de conformidade — é "por inspeção".
- **Achar bugs na própria rodada** (CRITICAL/HIGH) é sinal de que HÁ mais; puxe
  concorrência/segurança para baixo.
- Evidência de **produção real** SOBE robustez/prontidão — mas 1 deploy ≠ escala;
  não superajuste de um sinal.

## Formato de saída

1. **Âncora** (1 linha do que é 100).
2. **Tabela**: Dimensão | Nota | Justificativa em 1 linha COM evidência concreta.
3. **Nota geral honesta** (ponderada) + como chegou.
4. **Veredito** em uma frase (ex.: "production-grade para não-crítico, ainda não
   battle-hardened para crítico").
5. **Top 3 fatores que mais seguram a nota** + o que MOVE cada um (ação concreta).
6. O que NÃO preocupa (os fortes reais) — para não soar só negativo.

## Fechar o loop

Atualize `MATURIDADE-<data>.md` (documento vivo) com a avaliação e semeie/atualize
o plano de ação (P0 provar correção → P1 operacional → P2 concorrência →
P3 quick wins → P4 segurança). Referencie as issues (#171, #196, #197, #98).

## Não faça
- Não pontuar sem juntar evidência primeiro.
- Não arredondar para cima para agradar.
- Não dar nota alta em "correção" ou "prontidão" sem prova (suite/fuzzing/produção).
- Não tratar "compila nas duas faces" como "testado nas duas faces".
