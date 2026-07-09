---
name: poseidon-http2-review
description: Revisão focada da implementação HTTP/2 e HPACK do Poseidon (Poseidon.Net.HTTP2*, incluindo HPACK e o manager/upgrade h2c). Use ao auditar frames, controle de fluxo, gerência de streams, tabela dinâmica HPACK, ALPN/h2c, ou defesas contra DoS de HTTP/2. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão HTTP/2 + HPACK do Poseidon

Escopo: `src/Poseidon.Net.HTTP2.pas` e correlatos (`HTTP2.Manager`, HPACK).
Aplique a Regra de Ouro de `poseidon-review`. HTTP/2 é rico em contadores e
janelas — PROVE cada afirmação de limite/aritmética com o fonte e um cenário.

## O que caçar (RFC 9113 + RFC 7541)

### Framing
- Validação de `length` do frame vs `SETTINGS_MAX_FRAME_SIZE`; frame maior →
  FRAME_SIZE_ERROR; leitura parcial entre reads (estado do decodificador).
- Tipos/flags: DATA, HEADERS, PRIORITY, RST_STREAM, SETTINGS, PUSH_PROMISE,
  PING, GOAWAY, WINDOW_UPDATE, CONTINUATION — tratamento de tipo desconhecido.
- Padding: `Pad Length` > payload → erro; padding subtraído corretamente do
  tamanho de DATA/HEADERS.
- Connection preface exigido; frame na conexão em estado errado.

### Streams e estado
- Numeração de stream (ímpar do cliente, monotônica); reuso/regressão de id.
- Máquina de estados (idle/open/half-closed/closed); DATA/HEADERS em stream
  fechado; RST_STREAM em stream idle.
- `SETTINGS_MAX_CONCURRENT_STREAMS` aplicado; RST_STREAM flood / rapid reset
  (CVE-2023-44487) — há limite de reset por conexão?
- CONTINUATION flood (headers sem fim) — há limite de tamanho acumulado?

### Controle de fluxo
- Janela de conexão E de stream; WINDOW_UPDATE com incremento 0 → erro;
  overflow da janela (> 2^31-1) → FLOW_CONTROL_ERROR; janela negativa após
  SETTINGS reduzir `INITIAL_WINDOW_SIZE`.
- DATA que excede a janela; contabilidade ao enviar/receber.

### HPACK (RFC 7541)
- Tabela dinâmica: evicção por tamanho; `SETTINGS_HEADER_TABLE_SIZE` e
  dynamic table size update; índice fora de faixa → erro de compressão.
- Bomba de descompressão (header huge via referências repetidas) — limite de
  tamanho total de header list?
- Huffman: sequência inválida/padding EOS incorreto → erro.
- Índice 0, literais never-indexed, integer overflow no varint HPACK.

### h2c / ALPN
- Upgrade h2c só via GET, sem TLS; ALPN "h2" cria a conexão; `HTTP2-Settings`.
- GOAWAY: envio no shutdown; não aceitar novos streams após GOAWAY.

## Lacunas comuns
Trailers (HEADERS após DATA com END_STREAM), 0-length DATA, priorização
(dependências circulares), PING de tamanho ≠ 8, SETTINGS ACK.

## Não reporte sem provar
Uma "falha de controle de fluxo" só é bug se você mostrar a sequência de frames
(com números de janela) que leva a janela negativa/estouro ou a envio além do
permitido. Confirme o tipo dos contadores (Cardinal/Integer/Int64) no fonte.
