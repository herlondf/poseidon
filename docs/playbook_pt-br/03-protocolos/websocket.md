# WebSocket

Handlers de WebSocket são registrados por caminho via `RegisterWSHandler`.
A mesma instância de servidor lida com tráfego HTTP e WebSocket na mesma porta.

## Registrando um handler

```pascal
uses Poseidon.Net.WebSocket;

LServer.RegisterWSHandler('/ws',
  procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
  begin
    if AFrame.Opcode = OPCODE_TEXT then
      AConn.Send('echo: ' + TEncoding.UTF8.GetString(AFrame.Payload))
    else if AFrame.Opcode = OPCODE_BINARY then
      AConn.SendBinary(AFrame.Payload)
    else if AFrame.Opcode = OPCODE_CLOSE then
      AConn.Close(1000);
  end);
```

## Campos de TWebSocketFrame

| Campo | Tipo | Descrição |
|-------|------|-----------|
| `Opcode` | `Byte` | Tipo do frame — use as constantes `OPCODE_*` |
| `Payload` | `TBytes` | Payload bruto do frame |
| `FinFlag` | `Boolean` | True quando este é o fragmento final |

## Constantes OPCODE

| Constante | Valor | Significado |
|-----------|-------|-------------|
| `OPCODE_TEXT`   | `$1` | Mensagem de texto UTF-8 |
| `OPCODE_BINARY` | `$2` | Mensagem binária |
| `OPCODE_CLOSE`  | `$8` | Encerramento da conexão |
| `OPCODE_PING`   | `$9` | Ping (tratado automaticamente) |
| `OPCODE_PONG`   | `$A` | Pong (tratado automaticamente) |

## Métodos de IPoseidonWSConn

| Método | Descrição |
|--------|-----------|
| `Send(AText: string)` | Envia um frame de texto UTF-8 |
| `SendBinary(AData: TBytes)` | Envia um frame binário |
| `Close(ACode: Word = 1000)` | Envia frame de close e encerra a conexão |
| `RemoteAddr: string` | Endereço IP remoto (propriedade somente leitura) |
| `Closed: Boolean` | True se a conexão já foi encerrada (propriedade somente leitura) |

## Limite de tamanho de frame (R-3)

Use `MaxWSFrameSize` para rejeitar payloads muito grandes antes de processá-los:

```pascal
LServer.MaxWSFrameSize := 1024 * 1024;  // 1 MB — fecha com código 1009 se excedido
```

O padrão é `0` (ilimitado). Quando um frame excede o limite, a conexão é fechada
com o código WebSocket `1009` (Message Too Big) e o handler não é chamado.

## Trabalhando com payloads de texto

`Payload` é sempre `TBytes`. Decodifique para string explicitamente:

```pascal
LText := TEncoding.UTF8.GetString(AFrame.Payload);
```

## Observações

- Frames Ping são respondidos automaticamente com Pong — seu handler não é chamado para Ping.
- Frames Close: chame `AConn.Close(1000)` para completar o handshake. Após essa chamada, a
  conexão é encerrada e qualquer envio posterior em `AConn` é ignorado.
- O handler é chamado a partir de um worker thread; estado compartilhado deve ser protegido.
- `TWebSocketUtils` expõe os helpers de protocolo bruto (`ParseFrame`, `BuildFrame`,
  `HandshakeAccept`) para controle de nível mais baixo.

## Compressão permessage-deflate (RFC 7692)

O Poseidon negocia automaticamente o `permessage-deflate` quando o cliente o anuncia
no header `Sec-WebSocket-Extensions` durante o handshake de upgrade. Nenhuma
configuração é necessária — a extensão é ativada por conexão quando ambos os lados concordam.

Quando ativo:

- Chamadas de saída `Send` e `SendBinary` comprimem o payload com DEFLATE bruto
  (windowBits = -15, sem estado — `no-context-takeover` em ambos os lados).
- Frames recebidos com o bit RSV1 definido são descomprimidos transparentemente antes
  de o handler os receber.
- `TWebSocketFrame.RSV1` é `True` para frames comprimidos, caso precise detectá-los.

Para verificar se a compressão está ativa em uma conexão:

```pascal
LServer.RegisterWSHandler('/ws',
  procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
  begin
    if AConn.DeflateEnabled then
      // compressão está ativa nesta conexão
    AConn.Send('pong');
  end);
```

A classe `TWSDeflateUtils` em `Poseidon.Net.WebSocket` expõe os helpers brutos
`Compress` / `Decompress` caso precise usá-los de forma independente.

## Internos da codificação de frames

`TextFrame` e `CloseFrame` usam estratégia zero-copy: os bytes do payload são
alocados uma vez e o cabeçalho RFC 6455 é prefixado **in-place**, deslocando o
payload para a direita na mesma alocação (`_PrependHeader`).  
`BuildFrame` (usado por `BinaryFrame` e `PongFrame`) faz uma cópia convencional
em duas regiões. O caminho zero-copy evita uma segunda alocação heap nos casos
mais comuns (text/close).
