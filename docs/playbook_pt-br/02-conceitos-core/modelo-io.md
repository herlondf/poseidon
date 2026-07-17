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
- **Send vetorizado** — `PostSendV` envia headers + body em uma única syscall via scatter-gather I/O (`writev` no Linux, `WSASend` com múltiplos `WSABUF` no Windows). Sem necessidade de concatenar buffers. `PostSend` também está disponível para respostas de buffer único.
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

## Selecao de Backend de I/O

### Backends disponíveis

**IOCP — I/O Completion Ports (Windows, padrão)**

Backend **padrão e validado** do Windows. Usa a API clássica de completion
ports (`AcceptEx` + `WSARecv`/`WSASend` com `OVERLAPPED`; sockets reciclados via
`DisconnectEx`). Totalmente suportado a partir do Windows XP.

**RIO — Registered I/O (Windows, opt-in via FORCE_RIO)**

Mecanismo de menor overhead introduzido no Windows 8 / Server 2012, porém
**opt-in** (`{$DEFINE FORCE_RIO}`) e ainda não validado ponta-a-ponta (hoje
aceita com `accept()` simples, cujos sockets não são RIO-capable). Usa polling
direto sobre um buffer de conclusão compartilhado com o kernel; buffers
pré-registrados via `RIORegisterBuffer`.

Características:
- Uma CQ dedicada por worker thread — sem contenção cross-thread
- Buffers de send/recv pré-registrados (512 × 32 KB cada) — zero-copy de userspace para kernel
- Batch dequeue de até 256 completions por chamada

**io_uring (Linux, preferido, kernel ≥ 5.1)**

Ring assíncrono compartilhado entre userspace e kernel.
O backend do Poseidon usa `IORING_REGISTER_FILES` para registrar file
descriptors de socket no ring — evita uma lookup no kernel por operação.
`IORING_OP_ACCEPT` no modo **multishot** (`IOSQE_ACCEPT_MULTISHOT` no campo
`ioprio`) mantém um único SQE de accept ativo que gera um CQE para cada nova
conexão, sem precisar repostar o SQE. Se o kernel cancela o multishot
(indicado pela ausência de `IORING_CQE_F_MORE`), o backend re-submete
automaticamente.

Características:
- Arquivo registrado: elimina lookup fd→file por operação
- Multishot accept: um SQE serve N conexões
- SQPOLL opcional: kernel poll thread elimina syscalls no hot path
- Pool de recv pré-alocado (512 contextos × 32 KB)

**epoll (Linux, fallback)**

Modelo shared-nothing por core: cada worker thread mantém seu próprio fd epoll
e escuta em um socket com `SO_REUSEPORT`. O kernel distribui conexões entre os
workers sem contenção de lock. Cada fd é adicionado com `EPOLLONESHOT | EPOLLIN`
para garantir processamento exclusivo por um único worker.

### Seleção automática vs. forçada

A seleção ocorre uma única vez na inicialização, no constructor de
`TPoseidonNativeServer`. Não há decisão de backend por requisição.

No Windows: **IOCP por padrão**; RIO é opt-in via `FORCE_RIO`.

Ordem de preferência no Linux:
1. io_uring (se `io_uring_setup` syscall 425 retornar sucesso)
2. epoll (fallback silencioso em `ENOSYS` ou `EPERM`)

Para forçar um backend específico, use as defines de compilação:

| Define | Efeito |
|--------|--------|
| `FORCE_RIO` | Opta pelo RIO no Windows (senão, IOCP é o padrão) |
| `FORCE_EPOLL` | Pula io_uring e usa epoll diretamente (Linux) |

Exemplo no `.dproj` ou linha de compilação:

```
dcc64 MeuApp.dpr -dFORCE_EPOLL
```

Use `FORCE_EPOLL` em ambientes Linux onde io_uring está disponível mas restrito
por seccomp (ex.: alguns runtimes de container). Use `FORCE_RIO` apenas onde o
RIO estiver validado ponta-a-ponta.

## Veja também

- [Ciclo de vida da conexão](ciclo-vida-conexao.md)
- [Worker threads](../04-operacao-e-runtime/worker-threads.md)
