# Modelo de I/O

O Poseidon usa I/O assíncrono nativo nas plataformas suportadas:

| Plataforma | Mecanismo | Seleção |
|------------|-----------|---------|
| Windows 64-bit | IOCP (I/O Completion Ports) | sempre |
| Linux 64-bit — kernel ≥ 5.1 | **io_uring** | automática (preferida) |
| Linux 64-bit — kernel < 5.1 | epoll(7) + `EPOLLONESHOT` | fallback automático |

A seleção do backend Linux ocorre **uma única vez** na construção de
`TPoseidonNativeServer`: se `io_uring_setup` (syscall 425) retornar sucesso, o
`TIOUringBackend` é criado; caso contrário (`ENOSYS` ou `EPERM`), o servidor usa
`TEpollBackend` em silêncio. Zero overhead por requisição.

## Propriedades principais

- **Zero overhead de thread por conexão** — conexões são file descriptors em um conjunto do kernel, não threads bloqueadas.
- **Um único send por resposta** — headers + body montados em um único buffer e enviados com uma única chamada `WSASend`/`send`. Elimina travagens de Nagle/delayed-ACK em loopback.
- **Backend plugável** — `IIOBackend` separa o servidor da plataforma de I/O; a seleção é feita no constructor sem nenhum `{$IFDEF}` no path de requisição.

## Windows: IOCP

`WSARecv` e `WSASend` são postados com uma estrutura `OVERLAPPED`. Quando o OS
completa a operação, posta um pacote de conclusão no handle IOCP.
Worker threads chamam `GetQueuedCompletionStatus` em loop e despacham de acordo.

## Linux: io_uring (preferido, kernel ≥ 5.1)

`TIOUringBackend` mantém um único ring `io_uring`. `PostRecv` submete um SQE
`IORING_OP_RECV` com um buffer heap-alocado por requisição. Uma thread de
conclusão dedicada chama `io_uring_enter(GETEVENTS)` em loop, drena os CQEs
disponíveis e despacha `OnRecv` / `OnSendComplete` / `OnConnError`.

Vantagens sobre epoll: sends zero-copy via `IORING_OP_SEND`, sem syscall de
`recv()` por requisição (o kernel preenche o buffer diretamente).

## Linux: epoll (fallback)

O servidor cria um fd epoll na inicialização. Cada socket aceito é adicionado com
`EPOLLONESHOT | EPOLLIN`. Quando o epoll reporta prontidão, um worker lê os bytes
disponíveis e rearma o fd com `EPOLL_CTL_MOD`.

`EPOLLONESHOT` garante que apenas um worker processe um dado fd por vez.

## Veja também

- [Ciclo de vida da conexão](ciclo-vida-conexao.md)
- [Worker threads](../04-operacao-e-runtime/worker-threads.md)
