---
name: poseidon-http2-src
description: Especialista em IMPLEMENTAR e corrigir HTTP/2 e HPACK do Poseidon — Poseidon.Net.HTTP2, Poseidon.Net.HTTP2.HPACK, Poseidon.Net.HTTP2.Manager (upgrade h2c, ALPN). Use ao aplicar patches de poseidon-http2-review (overflow HPACK, flow-control sem teto, rapid-reset CVE-2023-44487, header block split, HPACK bomb) ou adicionar features de HTTP/2. Herda regras de poseidon-src.
---

# Implementação HTTP/2 + HPACK — invariantes duros

Escopo: `src/Poseidon.Net.HTTP2.pas`, `src/Poseidon.Net.HTTP2.HPACK.pas`,
`src/Poseidon.Net.HTTP2.Manager.pas`. Regras gerais em `poseidon-src`.

## Invariantes que ATACANTE explora se você quebrar

- **Aritmética unsigned para tamanhos de HPACK e frames**. `Integer` cast de
  `LongWord` com bit 31 setado vira negativo, passa bounds-check assinado,
  aloca ~2GB. HPACK `_HpackDecodeInt` e `HPACK.pas:590` são o exemplo real.
  Use `UInt32`/`UInt64` e detecte overflow ANTES da comparação.
- **Frame size validado contra o VALOR PRÓPRIO de SETTINGS_MAX_FRAME_SIZE**,
  não o do peer. E validar cedo — na leitura do header do frame, antes de
  alocar payload.
- **MAX_CONCURRENT_STREAMS imposto**. Cada `HEADERS` sem RST_STREAM subsequente
  consome slot. Sem limite → OOM.
- **Rapid-reset (CVE-2023-44487)**: contar RST_STREAM por janela; exceder →
  GOAWAY + fecha conexão. Sem essa defesa o cliente abre/reseta streams
  indefinidamente.
- **MAX_HEADER_LIST_SIZE**: soma de `nome.len + valor.len + 32` sobre TODOS os
  headers do bloco. Ultrapassou → REFUSED_STREAM. HPACK bomb = 1 byte
  referencia entrada de 4KB N vezes.
- **Body sem teto = OOM**. Flow-control WINDOW_UPDATE auto-reabastece — se você
  reabastece sem checar limite de corpo, cliente único derruba servidor.
  Limite lógico do request corpo é aplicado ANTES de mandar WINDOW_UPDATE.

## Estado de stream (máquina RFC 7540 §5.1)

- Cliente stream-id ÍMPAR, servidor push PAR. ID recebido do cliente PAR →
  connection error (PROTOCOL_ERROR). Colisão par com push interno = crash;
  valide na entrada.
- `END_STREAM` no HEADERS chega ANTES do CONTINUATION que completa o bloco.
  Persistir a flag até o bloco fechar; se você resetar em CONTINUATION,
  perde o fim do body → hang.
- Preservar ordem: header block é contíguo (HEADERS + CONTINUATIONs).
  Nenhum frame de outro stream pode se intercalar.

## HPACK

- Tabela dinâmica: **decoder** aplica tamanho ditado pelo encoder (peer). Mas
  se o cliente manda size = enorme, você tem que ACEITAR até o máximo que
  ANUNCIOU em SETTINGS_HEADER_TABLE_SIZE. Nunca acima.
- Huffman: rejeitar sequências com padding inválido (não deve ser aceitável
  arbitrário — `EOS` embutido é erro).
- Pseudo-headers (`:method`, `:scheme`, `:authority`, `:path`): validar
  presença, ordem (todos antes dos regulares), sem duplicata. Não validar =
  risco de smuggling h2→h1 no downgrade.
- Encoding com `_HpackDecodeInt`: usar UInt32 e detectar overflow no laço de
  continuation bytes.

## h2c / ALPN (Manager)

- Upgrade via `Upgrade: h2c` + `HTTP2-Settings` + preface `PRI * HTTP/2.0`.
  Só aceitar se todos presentes e no primeiro request da conexão.
- ALPN: string protocolo negociada = `h2`. Rejeitar se cliente não ofereceu.

## Flow control

- Duas janelas: connection-level e stream-level. Ambos limitam envio.
- Janela INICIAL = SETTINGS_INITIAL_WINDOW_SIZE (default 65535). Se anunciar 0,
  cliente bufferiza indefinido esperando WINDOW_UPDATE.
- Ao mudar `SETTINGS_INITIAL_WINDOW_SIZE`, aplicar diff a TODAS as streams
  abertas (delta pode ser negativo).

## Bugs típicos

- `Integer(LLen) > ABufLen` com `LLen: LongWord` alto (assinado vs unsigned).
- Reset de END_STREAM em CONTINUATION.
- Contar streams SEM aplicar limite → OOM lento.
- Contar RST sem janela temporal → falso positivo/negativo (use tempo, não
  contagem absoluta).
- Deflate na Huffman aceitando padding trivial.

## Arquivos no escopo

`src/Poseidon.Net.HTTP2.pas`, `src/Poseidon.Net.HTTP2.HPACK.pas`,
`src/Poseidon.Net.HTTP2.Manager.pas`.

Cross-skill: TLS/ALPN → `poseidon-security-src` (SSL). Refcount de stream
context → `poseidon-concurrency-src`.
