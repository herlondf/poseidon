# Ciclo de vida da conexão

## Fases

```
Accept TCP
    ↓
[Parse Proxy Protocol]   — se ProxyProtocol ≠ ppDisabled
    ↓
[Handshake TLS]          — se SSL configurado
    ↓
[Negociação ALPN]        — h2 ou http/1.1
    ↓
Acumulação de requisição — bytes chegam via recv/IOCP
    ↓
Despacho da requisição   — callback do handler (worker thread)
    ↓
Envio da resposta        — único WSASend / send
    ↓
[Keep-alive: volta para acumulação de requisição]
    ↓
Fechamento da conexão    — timeout de idle / Connection: close / GOAWAY
    ↓
Ref-count chega a 0      — TNativeConn liberado
```

## TNativeConn (tempo de vida com ref-count)

Cada conexão é representada por um objeto `TNativeConn` com um inteiro `FRefCount`
gerenciado por `AddRef`/`Release`. O servidor mantém uma referência do accept ao close;
cada operação IOCP em-flight mantém uma referência adicional durante sua duração.
O objeto é liberado quando o contador chega a zero — nunca enquanto um pacote IOCP
estiver na fila.

## Sweep de idle

Uma thread de background (`FIdleSweepThread`) escaneia todas as conexões a cada
5 segundos. Qualquer conexão cujo timestamp `LastActivity` for mais antigo que
`IdleTimeoutMs` (padrão 10 000 ms) é fechada. O timer é reiniciado a cada byte recebido.

Defina `IdleTimeoutMs := 0` para desabilitar o sweep completamente.

## Keep-alive

Conexões HTTP/1.1 com `Connection: keep-alive` reutilizam a mesma conexão TCP para
múltiplas requisições. O buffer de acumulação (`AccumBuf`) é mantido entre requisições
e reutilizado sem realocação.

## TCP half-close no shutdown (R-6)

Quando `_CloseConn` é chamado, o Poseidon realiza um **TCP half-close** antes de
`closesocket` / `close(fd)`:

```
shutdown(socket, SD_SEND / SHUT_WR)   — para de enviar; peer ainda pode ler
closesocket / close(fd)                — encerra após o peer drenar
```

`SD_SEND` (Windows) / `SHUT_WR` (Linux) sinaliza ao peer remoto que não haverá mais
envios, mas o socket permanece aberto para leitura. Isso permite que o cliente receba
os bytes que já estão no buffer de envio do kernel antes de a conexão ser completamente
encerrada — prevenindo perda silenciosa de dados em shutdowns abruptos.

Esse comportamento é automático e não requer configuração.

## GOAWAY HTTP/2 no shutdown (R-2)

Quando o servidor é parado enquanto uma conexão HTTP/2 está ativa, o Poseidon envia
um frame `GOAWAY` antes de fechar o socket. O `GOAWAY` carrega o último stream ID
processado e o código `NO_ERROR`, sinalizando ao cliente que pode com segurança
reattempt streams com IDs maiores que o último processado em uma nova conexão.

O callback de fechamento (`FCloseProc`) é adiado até que todos os streams ativos
tenham terminado de enviar suas respostas. Se `DrainTimeoutMs` expirar primeiro,
a conexão é fechada incondicionalmente.

## Upgrade para WebSocket / HTTP/2

Quando o dispatcher detecta um upgrade WebSocket (`Upgrade: websocket`) ou um upgrade
h2c (`Upgrade: h2c`), transiciona a conexão para o handler de protocolo respectivo.
Após o upgrade, o `TNativeConn` não é mais usado para despacho HTTP/1.1 e é conduzido
por `TWebSocketConn` ou `TH2Conn`.
