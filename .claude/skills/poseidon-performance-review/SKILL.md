---
name: poseidon-performance-review
description: Revisão de performance do hot path do Poseidon — alocações e cópias evitáveis no parser e no ResponseBuilder, concatenação de string em O(n²), trabalho duplicado, busca linear onde caberia hash, syscalls por requisição e falso compartilhamento de cache line. Use ao auditar throughput/latência ou antes de otimizar. Diferente das outras skills, aqui o alvo é custo, não correção — mas ainda vale a Regra de Ouro (só afirme regressão/custo que você consiga justificar).
---

# Revisão de performance do Poseidon

Escopo: caminho quente por requisição — `Poseidon.Net.HTTP1.Parser.pas`,
`Poseidon.Net.ResponseBuilder.pas`, `Poseidon.Net.Dispatcher.pas`,
`Poseidon.Net.HttpServer.pas` (recv/send), pools. O Poseidon é otimizado para
zero-cópia e fragmentos pré-codificados — meça o custo contra esse padrão.

## O que caçar
- **Alocações no laço do parser**: `LowerCase`/`Trim`/`Copy`/`Pos` por header;
  materialização de strings quando um scan por bytes bastaria; `SetLength`
  redundante.
- **Cópias de buffer**: `Move` evitáveis; construir resposta concatenada quando
  há envio vetorizado (headers + body separados); cópia do body no hot path.
- **Concatenação de string O(n²)**: montar blocos de header com `S := S + ...`
  em laço; construir a mesma string duas vezes (sizing + escrita — deve ser uma
  vez só).
- **Busca linear vs hash**: varredura onde um dicionário/hash resolveria
  (headers, rotas). Rotas param são O(n) por design — confirme n pequeno.
- **Syscalls por requisição**: `GetTickCount`/relógio por request (usar vDSO/
  cache), múltiplos send/recv onde um só bastaria (Nagle/delayed-ACK), flush.
- **Trabalho por resposta**: formatação de `Date` a cada resposta (deve ser
  cache por segundo, ex.: threadvar); recomputar fragmentos constantes.
- **Cache-line / false sharing**: contadores atômicos quentes
  (`FInFlightCount`) sem padding; campos mutáveis compartilhados na mesma linha.
- **Pool churn**: acquire/release desnecessário; arena thread-local vs pool
  global no SyncDispatch.

## Como avançar com segurança
- Toda otimização deve preservar comportamento — cheque contra os testes
  (`tests/Poseidon.Tests.HTTP1Parser`, `Tests.ResponseBuilder`, `Tests.Dispatcher`).
- Quando possível, meça (benchmark) antes/depois em vez de assumir; mudanças de
  layout de memória ou de I/O têm risco de regressão — trate como `breaking-risk`.
- Não troque clareza por micro-otimização sem ganho comprovado.

## Regra de reporte
Aponte o custo com um raciocínio concreto (quantas alocações/cópias/syscalls por
requisição e por quê). "Parece lento" não é achado. Se não tiver certeza do
ganho, proponha como experimento a medir, não como bug.
