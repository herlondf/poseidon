---
name: poseidon-websocket-review
description: Revisão focada do WebSocket do Poseidon (Poseidon.Net.WebSocket*, incluindo o manager e o handshake de upgrade) e do handshake TLS quando relevante. Use ao auditar o handshake de upgrade, parsing/geração de frames, mascaramento, fragmentação, close/ping/pong ou limites de payload. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão WebSocket do Poseidon

Escopo: `src/Poseidon.Net.WebSocket.pas`, `WebSocket.Manager.pas` e o caminho de
upgrade no dispatcher/servidor. Aplique a Regra de Ouro de `poseidon-review`.

## O que caçar (RFC 6455)

### Handshake de upgrade
- Só via GET (case-sensitive) HTTP/1.1; `Upgrade: websocket` + `Connection`
  contendo Upgrade; `Sec-WebSocket-Key` presente.
- `Sec-WebSocket-Accept` = base64(SHA1(key + GUID)) — confira o GUID mágico
  `258EAFA5-E914-47DA-95CA-C5AB0DC85B11` e o cálculo.
- `Sec-WebSocket-Version: 13`; versão diferente → 426.
- Transição de estado da conexão (WSMode := CCMWebSocket) e re-arm de recv.

### Parsing de frame
- Bits FIN/RSV (RSV≠0 sem extensão → falha); opcode válido (0x0-0xA); opcodes
  reservados → falha.
- **Máscara**: frames do cliente DEVEM ser mascarados; frame não-mascarado →
  fechar (1002). Unmasking aplicado corretamente (XOR com masking-key rotativa).
- Comprimento: 7-bit / 16-bit / 64-bit; bit alto do 64-bit deve ser 0; limite
  de payload (`MaxWSFrameSize`) → close 1009; **atenção a overflow/OOM ao
  alocar** o payload antes de validar o tamanho.
- Frames de controle (close/ping/pong): payload ≤ 125, não fragmentáveis
  (FIN=1); ping → pong com mesmo payload.
- Fragmentação: primeiro frame opcode ≠ 0, continuações opcode 0, controle pode
  interleave; opcode inválido no meio da fragmentação.
- Close: código válido (1000-1015 exceto reservados; 3000-4999), payload UTF-8;
  handshake de close (responder close).
- Text frames: validação de UTF-8.

### Geração / envio
- Frames do servidor NÃO mascarados; header de comprimento correto por faixa;
  sem cópia desnecessária do payload no hot path.

### Estado / lifetime
- `TPoseidonWSConn` invalidado no close da conexão; sem uso após invalidar;
  buffers de pool devolvidos; reentrância do dispatch de frames.

## Não reporte sem provar
Um "bug de mascaramento" precisa do frame de bytes concreto e do resultado do
XOR. Um "OOM por payload" precisa mostrar que a alocação ocorre ANTES da checagem
de `MaxWSFrameSize`. Confirme os tipos de comprimento (Int64) no fonte.
