---
name: poseidon-portability-src
description: Especialista em IMPLEMENTAR e corrigir backends de I/O e código plataforma-específico do Poseidon — IO.IOCP, IO.RIO (Windows), IO.Epoll, IO.IOUring (Linux), Pool.Socket, MemoryManager.Linux. Use ao aplicar patches de poseidon-portability-review (TInterlocked.Read Int64 vs Integer, tipo de handle, sub/dif de var vs ponteiro, unit-resolution ambígua) ou modificar syscalls/ifdefs. Herda regras de poseidon-src. CI só compila uma face por vez — valide AMBAS as plataformas.
---

# Implementação de backends I/O e portabilidade — invariantes

Escopo: `src/Poseidon.Net.IO.IOCP.pas`, `src/Poseidon.Net.IO.RIO.pas`,
`src/Poseidon.Net.IO.Epoll.pas`, `src/Poseidon.Net.IO.IOUring.pas`,
`src/Poseidon.Net.Pool.Socket.pas`, `src/Poseidon.MemoryManager.Linux.pas`.
Regras gerais em `poseidon-src`.

## Regra dura — CI compila só uma face

Windows CI não compila epoll/io_uring; Linux CI não compila IOCP/RIO. Bug em
uma plataforma fica LATENTE — só ativa em deploy. Ao editar:

- Se a unit é multiplataforma (`{$IFDEF MSWINDOWS}...{$ELSE}...{$ENDIF}`),
  valide `dcc64` Win64 E Linux64 antes de dar por feito.
- Se a unit é single-plataforma, ainda assim confirme que ninguém do outro
  lado a inclui em `uses`.

## TInterlocked.Read — armadilha canônica

Só há overload `Int64`. `TInterlocked.Read(FShutdown: Integer)` = E2033 em
Linux64. IOCP/RIO já usam `Int64` — Epoll/IOUring precisam mudar (CRITICAL
ativo no review). Ou muda campo para `Int64`, ou usa
`TInterlocked.CompareExchange(FShutdown, 0, 0)`.

## Handle de socket

- Windows: `TSocket = UIntPtr` (Winsock2). 64-bit no Win64.
- Linux: `Integer` (fd). 32-bit.

Nunca passe cross-plat como tipo cru; use aliases do projeto (defina em
`Poseidon.Net.Types.pas` se ainda não). Overload de `SocketClose` /
`SocketRecv` / `SocketSend` deve resolver certo em cada plataforma — se você
mudar assinatura, cheque unit-resolution nos dois OSs.

## IOCP (Windows)

- Lifetime do `OVERLAPPED`: struct vive até `GetQueuedCompletionStatus`
  retornar a operação. Solte antes = corrupção.
- `WSAIoctl` para `SIO_LOOPBACK_FAST_PATH`, extensões RIO, etc. Confirme
  overloads na `Winapi.Winsock2` — várias assinaturas.
- `PostQueuedCompletionStatus` para acordar workers manualmente.

## RIO (Registered I/O)

- Buffers registrados: `RIORegisterBuffer` só uma vez, liberar com
  `RIODeregisterBuffer` no shutdown.
- Completion queue tem limite fixo por thread — dimensionar cedo.

## Epoll (Linux)

- Edge-triggered vs level-triggered: Poseidon usa edge (EPOLLET). Consequência:
  DEVE ler até `EAGAIN` a cada notificação, senão dados ficam parados até a
  próxima transição.
- `EPOLLONESHOT` re-arm: após processar, `epoll_ctl(MOD)` com nova máscara.
  Esquecer = worker morto para essa fd.

## io_uring (Linux 5.1+)

- SQE (submission) / CQE (completion): ownership da SQE passa ao kernel após
  `io_uring_submit`. Não toque depois.
- `user_data` em CQE = ponteiro para contexto. Precisa refcount até CQE
  chegar.
- `io_uring_get_sqe` pode retornar `nil` se anel cheio — bufferize ou
  bloqueie.

## Pool.Socket

- Pool de sockets pré-alocados para `AcceptEx` (Windows). Em Linux, socket é
  cheap — pool não faz sentido, evite espelhar.
- Se pool cross-plat, ao menos `{$IFDEF LINUX}` degrade para no-op.

## MemoryManager.Linux

- Se ponteiros do MM ficam `nil` (visto no review), qualquer `GetMem` durante
  init falha com AV. Ordem de init do RTL importa — o `MemoryManager` DEVE
  estar registrado ANTES de qualquer alocação.
- Se você adicionar hook aqui, o handler NÃO pode alocar via mesmo MM
  (recursão infinita ou AV).

## Bugs típicos

- `TInterlocked.Read(Int32)` (E2033 Linux).
- Handle passado como `Integer` para função esperando `TSocket` (silencioso
  em 32-bit, truncamento em Win64).
- `{$IFDEF MSWINDOWS}` sem `{$ELSE}` deixa símbolo indefinido no outro lado.
- Edge-triggered epoll sem loop de leitura até EAGAIN.
- SQE de io_uring mutado após submit.
- Free do `OVERLAPPED` antes da completion chegar.

## Fluxo de validação obrigatório

1. Editar.
2. `dcc64` alvo Windows OK.
3. `dcc64` alvo Linux OK (harness `.dpr` em `sandbox/` com search path da
   plataforma-alvo se necessário).
4. Rodar testes DUnitX na plataforma disponível localmente.
5. Se tocar em código só-Linux, marcar no report que a validação Win é N/A
   (mas Linux precisa estar verde).

## Arquivos no escopo

`src/Poseidon.Net.IO.IOCP.pas`, `src/Poseidon.Net.IO.RIO.pas`,
`src/Poseidon.Net.IO.Epoll.pas`, `src/Poseidon.Net.IO.IOUring.pas`,
`src/Poseidon.Net.Pool.Socket.pas`, `src/Poseidon.MemoryManager.Linux.pas`.

Cross-skill: fachada de seleção → `poseidon-server-src` (`Net.IO.pas`).
Refcount na fronteira → `poseidon-concurrency-src`.
