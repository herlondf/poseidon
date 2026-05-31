# Controle de Fluxo HTTP/2

O Poseidon implementa o modelo completo de controle de fluxo do RFC 7540 §6.9 para conexões HTTP/2.

## Visão geral

O controle de fluxo impede que um emissor rápido sobrecarregue um receptor lento.
O HTTP/2 mantém duas janelas independentes:

| Janela | Escopo | Valor inicial |
|--------|--------|--------------|
| Janela de envio da conexão | Todos os streams da conexão | 65 535 bytes |
| Janela de envio do stream | Stream individual | `INITIAL_WINDOW_SIZE` do peer (padrão 65 535) |

Um frame DATA só pode ser enviado quando **ambas** as janelas são positivas e o
frame cabe no `MAX_FRAME_SIZE` do peer.

## Lado de recepção: WINDOW_UPDATE automático

Quando o Poseidon entrega o corpo de uma requisição à aplicação, ele decrementa
as janelas de recepção por stream e por conexão.
Assim que qualquer janela cai abaixo de 50% do tamanho inicial, o Poseidon envia
automaticamente um frame `WINDOW_UPDATE` para restaurar a janela completa.

```
Janela inicial   = 65 535
Limiar de 50%    = 32 767
Crédito WINDOW_UPDATE = inicial − atual
```

Nenhum código de aplicação é necessário.

## Lado de envio: backpressure

Quando `SendResponse` tem mais bytes a enviar do que a janela disponível permite,
o restante é armazenado em `PendingBody` do stream.
A transmissão é retomada automaticamente quando o peer envia um frame `WINDOW_UPDATE`.

```
janela de envio do stream: 16 384
corpo da resposta:         100 000 bytes

→ envia os primeiros 16 384 bytes imediatamente
→ armazena os 83 616 bytes restantes em PendingBody
→ chega WINDOW_UPDATE(32 768) do peer
→ envia próximos 32 768 bytes, armazena 50 848 restantes
→ ...
```

O objeto do stream permanece vivo em `FStreams` até todos os bytes pendentes serem enviados.

## Negociação de SETTINGS

O Poseidon envia seus valores preferidos no frame SETTINGS inicial.
Você pode configurá-los via propriedades do servidor:

```pascal
LServer.H2MaxConcurrentStreams := 128;   // SETTINGS_MAX_CONCURRENT_STREAMS
LServer.H2InitialWindowSize    := 65535; // SETTINGS_INITIAL_WINDOW_SIZE
```

Quando um SETTINGS do peer altera `INITIAL_WINDOW_SIZE`, o Poseidon atualiza a janela
de envio de cada stream existente pelo delta (positivo ou negativo) e verifica overflow
(RFC 7540 §6.9.2).

## Limites

- O tamanho máximo de frame enviado respeita o `SETTINGS_MAX_FRAME_SIZE` do peer.
- A janela de recepção rastreia o corpo por stream independentemente da janela da conexão.
- Um `WINDOW_UPDATE` com incremento 0 é rejeitado com `PROTOCOL_ERROR`.
- Um overflow de janela (> 2³¹ − 1) é rejeitado com `FLOW_CONTROL_ERROR`.
