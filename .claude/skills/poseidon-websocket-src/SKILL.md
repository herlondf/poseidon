---
name: poseidon-websocket-src
description: Especialista em IMPLEMENTAR e corrigir WebSocket do Poseidon — Poseidon.Net.WebSocket, Poseidon.Net.WebSocket.Manager (handshake de upgrade, frames, fragmentação, ping/pong/close, permessage-deflate). Use ao aplicar patches de poseidon-websocket-review (bomba de deflate, fragmentação/continuation, controle >125, unmasked aceito) ou adicionar features WS. Herda regras de poseidon-src.
---

# Implementação WebSocket — invariantes duros (RFC 6455)

Escopo: `src/Poseidon.Net.WebSocket.pas`,
`src/Poseidon.Net.WebSocket.Manager.pas`. Regras gerais em `poseidon-src`.

## Handshake de upgrade (RFC 6455 §4)

- Validar `Upgrade: websocket` + `Connection: Upgrade` + `Sec-WebSocket-Key`
  presente + `Sec-WebSocket-Version: 13` **exato** (13, não outro).
- Resposta: `Sec-WebSocket-Accept = base64(SHA1(key + GUID_RFC))` — GUID
  `258EAFA5-E914-47DA-95CA-C5AB0DC85B11`.
- Falha na validação = 400/426. Nunca fecha silencioso.

## Frames — invariantes

- Cliente→servidor: **MASK obrigatório**. Frame não-mascarado do cliente →
  fechar conexão com close code 1002 (protocol error). Regra dura.
- Servidor→cliente: MASK proibido. Não confunda o sentido.
- Frames de CONTROLE (Close/Ping/Pong, opcode ≥0x8): payload ≤125 bytes E
  `FIN=1` (não podem ser fragmentados). Violação = 1002 + close.
- Frames de DADOS podem ser fragmentados (`FIN=0`). Sequência:
  `text/binary(FIN=0) → continuation(FIN=0)* → continuation(FIN=1)`. Qualquer
  outra sequência (dois text seguidos sem FIN, continuation sem primário) =
  1002.
- Opcodes reservados (0x3–0x7, 0xB–0xF): fechar com 1002.

## Text vs Binary

- Text (opcode 0x1) **exige UTF-8 válido** em TODO o conteúdo final
  (concatenado após defragmentação). UTF-8 malformado → close 1007. Não é
  opcional.
- Binary (opcode 0x2) = bytes crus. Não valide.

## Close (opcode 0x8)

- Payload vazio OU >=2 bytes (código de close em big-endian). 1-byte payload
  = 1002.
- Após receber Close, enviar Close eco e fechar TCP. Não enviar novos frames.
- Códigos válidos: 1000–1015 (com exceções: 1004, 1005, 1006, 1015 NÃO podem
  ser enviados pelo endpoint).

## Ping/Pong

- Ping recebido → responder Pong com MESMO payload. Não gerar Pong sem Ping
  prévio (permitido, mas inútil).

## permessage-deflate (RFC 7692)

- Negociação em `Sec-WebSocket-Extensions` no handshake.
- Cada frame comprimido tem RSV1 setado. Descomprimir com **teto** de tamanho
  — bomba de deflate infla 1KB em MBs. Rejeitar excedendo → 1009 (message
  too big).
- Reset do contexto per-message se `client_no_context_takeover` negociado.

## Fragmentação — armadilha central

Se você recebe:
1. `text/binary(FIN=0)` — abrir buffer de mensagem, guardar opcode inicial.
2. `continuation(FIN=0)*` — append no buffer.
3. `continuation(FIN=1)` — fechar buffer, entregar. Validar UTF-8 se opcode
   inicial era text.
4. Frames de CONTROLE podem se intercalar entre passos (permitido pela spec).
   Você DEVE processá-los inline sem afetar o buffer de dados.

Bug clássico: reset do buffer ao receber controle → mensagem perdida.

## Manager (upgrade + lifecycle)

- `WebSocket.Manager.pas` faz o upgrade sobre a conexão HTTP/1 já parseada.
  Ao promover, transfira ownership do socket do dispatcher HTTP → handler WS.
  Não deixe dois lados achando que possuem.
- Refcount da conexão continua valendo (fronteira IO ↔ worker).

## Bugs típicos

- Reset de FIN em control frame recebido no meio da fragmentação.
- Aceitar unmasked do cliente por default.
- Aceitar Version diferente de 13.
- Não validar UTF-8 em text.
- Descomprimir permessage-deflate sem teto → OOM.

## Arquivos no escopo

`src/Poseidon.Net.WebSocket.pas`, `src/Poseidon.Net.WebSocket.Manager.pas`.

Cross-skill: compressão → `poseidon-compression-src`. Refcount →
`poseidon-concurrency-src`. Handshake TLS → `poseidon-security-src`.
