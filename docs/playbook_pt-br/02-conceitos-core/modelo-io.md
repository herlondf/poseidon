# Modelo de I/O

O Poseidon usa I/O assíncrono nativo nas duas plataformas suportadas:

| Plataforma | Mecanismo | Descrição |
|------------|-----------|-----------|
| Windows 64-bit | IOCP (I/O Completion Ports) | O kernel posta operações de I/O concluídas em uma fila; workers as dequeiam |
| Linux 64-bit | epoll(7) level-triggered + `EPOLLONESHOT` | O kernel notifica prontidão; o worker lê e rearma o fd |

## Propriedades principais

- **Zero overhead de thread por conexão** — conexões são file descriptors em um conjunto do kernel, não threads bloqueadas.
- **Um único send por resposta** — a resposta HTTP completa (headers + body) é montada em um único buffer e enviada com uma única chamada `WSASend`/`send`. Isso elimina as travagens de Nagle/delayed-ACK que afetam servidores com múltiplas escritas em loopback.
- **Pool de workers** — a conclusão de I/O é tratada por uma thread de I/O dedicada. Workers apenas executam callbacks de aplicação. Os dois pools de threads nunca se bloqueiam mutuamente.

## Windows: IOCP

`WSARecv` e `WSASend` são postados com uma estrutura `OVERLAPPED`. Quando o OS
completa a operação, posta um pacote de conclusão no handle IOCP.
Worker threads chamam `GetQueuedCompletionStatus` em loop e despacham de acordo.

Cada operação em-flight mantém uma referência no objeto `TNativeConn`
(`AddRef`/`Release`). Isso garante que a conexão não seja liberada enquanto um
pacote IOCP ainda estiver na fila do kernel.

## Linux: epoll

O servidor cria um fd epoll na inicialização. Cada socket aceito é adicionado com
`EPOLLONESHOT | EPOLLIN`. Quando o epoll reporta prontidão, um worker lê os bytes
disponíveis e rearma o fd com `EPOLL_CTL_MOD`.

`EPOLLONESHOT` garante que apenas um worker processe um dado fd por vez, eliminando
contenção de lock no objeto de conexão.

## Veja também

- [Ciclo de vida da conexão](ciclo-vida-conexao.md)
- [Worker threads](../04-operacao-e-runtime/worker-threads.md)
