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

## Selecao de Backend de I/O

### Backends disponíveis

**RIO — Registered I/O (Windows, preferido)**

Mecanismo de alta performance introduzido no Windows 8 / Server 2012.
Difere do IOCP porque usa polling direto sobre um buffer de conclusão
compartilhado com o kernel — sem syscall `GetQueuedCompletionStatus` por
evento. Buffers são pré-registrados via `RIORegisterBuffer`, eliminando
cópias de kernel para userspace.

Características:
- Polling de completions sem syscall (leitura direta no ring buffer)
- Buffers de send/recv pré-registrados — zero-copy de userspace para kernel
- Latência p99 inferior ao IOCP em cargas de alta conexão simultânea

**IOCP — I/O Completion Ports (Windows, fallback)**

Backend padrão do Windows quando RIO não está disponível (ex.: VM sem suporte
ao recurso). Usa a API clássica de completion ports. Totalmente suportado em
todas as versões do Windows a partir do XP.

**io_uring (Linux, preferido, kernel ≥ 5.1)**

Ring assíncrono compartilhado entre userspace e kernel.
O backend do Poseidon usa `IORING_REGISTER_FILES` para registrar file
descriptors de socket no ring — evita uma lookup no kernel por operação.
`IORING_OP_ACCEPT` no modo **multishot** mantém um único SQE de accept ativo
que gera um CQE para cada nova conexão, sem precisar repostar o SQE.

Características:
- Arquivo registrado: elimina lookup fd→file por operação
- Multishot accept: um SQE serve N conexões
- Sends zero-copy via `IORING_OP_SEND`

**epoll (Linux, fallback)**

Modelo shared-nothing por core: cada worker thread mantém seu próprio fd epoll
e escuta em um socket com `SO_REUSEPORT`. O kernel distribui conexões entre os
workers sem contenção de lock. Cada fd é adicionado com `EPOLLONESHOT | EPOLLIN`
para garantir processamento exclusivo por um único worker.

### Seleção automática vs. forçada

A seleção ocorre uma única vez na inicialização, no constructor de
`TPoseidonNativeServer`. Não há decisão de backend por requisição.

Ordem de preferência no Windows:
1. RIO (se disponível no SO)
2. IOCP (fallback)

Ordem de preferência no Linux:
1. io_uring (se `io_uring_setup` syscall 425 retornar sucesso)
2. epoll (fallback silencioso em `ENOSYS` ou `EPERM`)

Para forçar um backend específico, use as defines de compilação:

| Define | Efeito |
|--------|--------|
| `FORCE_IOCP` | Pula RIO e usa IOCP diretamente (Windows) |
| `FORCE_EPOLL` | Pula io_uring e usa epoll diretamente (Linux) |

Exemplo no `.dproj` ou linha de compilação:

```
dcc64 MeuApp.dpr -dFORCE_EPOLL
```

Ou via `Project > Options > Delphi Compiler > Conditional defines`:

```
FORCE_IOCP
```

Use `FORCE_EPOLL` em ambientes Linux onde io_uring está disponível mas restrito
por seccomp (ex.: alguns runtimes de container). Use `FORCE_IOCP` para
reproduzir comportamento de VM sem suporte a RIO.

## Veja também

- [Ciclo de vida da conexão](ciclo-vida-conexao.md)
- [Worker threads](../04-operacao-e-runtime/worker-threads.md)
