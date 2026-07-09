---
name: poseidon-concurrency-src
description: Especialista em IMPLEMENTAR e corrigir concorrência, lifetime de conexão e memória do Poseidon — Pool.Buffer, Pool.Arena, Pool.Workers, Connection, Connection.Manager, IdleSweep. Use ao aplicar patches de poseidon-concurrency-review (refcount AddRef/Release, corridas de dados, UAF, double-free, vazamentos de buffer, itens perdidos em Pool.Workers.Shutdown) ou adicionar estruturas atômicas. Herda regras de poseidon-src.
---

# Implementação de concorrência — invariantes duros

Escopo: `src/Poseidon.Net.Pool.Buffer.pas`, `src/Poseidon.Net.Pool.Arena.pas`,
`src/Poseidon.Net.Pool.Workers.pas`, `src/Poseidon.Net.Connection.pas`,
`src/Poseidon.Net.Connection.Manager.pas`, `src/Poseidon.Net.IdleSweep.pas`.
Regras gerais em `poseidon-src`.

## Refcount na fronteira IO-thread ↔ worker-pool

Contrato para `TNativeConn`:
- Ao enfileirar trabalho para o worker: `AddRef` na IO-thread ANTES de
  `PostQueuedCompletion`/similar.
- No worker: `try ... finally Release; end` sempre. Nunca sair sem
  Release.
- `Release` que zera refcount executa o teardown (fechar socket, devolver
  buffers ao pool). Nunca faça o teardown fora do último Release.

Bug clássico: `Release` chamado 2x no mesmo caminho de erro → double-free.

## TInterlocked — overloads e armadilhas

- `TInterlocked.Read` só existe para `Int64`. Campo `Integer` → mude para
  `Int64` OU use `TInterlocked.CompareExchange(campo, 0, 0)` para leitura
  atômica.
- `TInterlocked.Increment`/`Decrement` retorna o novo valor. Use o retorno,
  não releia o campo (releitura não é atômica com o inc).
- Flag booleana atômica: use `Integer` (0/1) com `CompareExchange`. Não
  use `Boolean` — não há atômico para ele.

## Pool.Buffer / Pool.Arena

- Acquire retorna buffer ao chamador; Release devolve.
- Pareamento estrito: um Acquire = um Release, mesmo em caminho de exceção.
  `try/finally Release; end`.
- Buffer devolvido não pode ser tocado por quem devolveu. Se você guardou
  referência, ela virou dangling — outro Acquire pode pegar o mesmo.
- Pool custom via `IBufferPool` injetado: contabilidade separada do pool
  estático. Não misture (achado ativo do review).

## Pool.Workers

- `Enqueue`: item entra na fila. Se worker está livre, dispara.
- `Shutdown`: descartar itens enfileirados VAZA (o `AddRef` que os colocou lá
  nunca é pareado). Ao shutdown, ou drena a fila (executando handlers) ou
  chama `Release` explícito para cada item pendente.
- `FInFlightCount`: incrementa no dequeue, decrementa no fim do handler.
  Descartar item enfileirado sem decrementar bagunça o contador.

## IdleSweep

- Timer periódico varre conexões e fecha idle > threshold.
- Sweep é uma thread só, mas conexões estão sendo mutadas por workers.
  Ler campos de `TNativeConn` (LastActivityTicks) precisa ser atômico OU
  ler-uma-vez em variável local (evita leitura torn).
- Ao decidir fechar: passe pela mesma fronteira (`AddRef` antes de sinalizar
  worker), nunca chame teardown direto do timer thread.

## Connection.Manager

- Registra/desregistra `TNativeConn`. Enumeração concorrente com
  registro/remoção corrompe. Ou snapshot antes de iterar, ou lock durante
  toda a iteração.

## Bugs típicos (do review)

- `FShutdown: Integer` + `TInterlocked.Read` — não compila Linux.
- `Pool.Workers.Shutdown` descartando itens sem Release → vaza refcount.
- Static `TBufferPool` misturado com `IBufferPool` injetado — contabilidade
  quebra.
- `Release` chamado em caminho de erro depois de já ter sido pareado no
  finally.
- Leitura de `Boolean` compartilhado sem atômica.
- Buffer TLC de IO-thread não liberado em graceful reload (vaza no restart).

## False sharing (perf, mas listado aqui)

Contadores atômicos hot em struct compartilhada com outros contadores
podem falso-compartilhar cache line. Padding para 64 bytes onde importa.
Não é o foco principal — trate se profiling apontar.

## Arquivos no escopo

`src/Poseidon.Net.Pool.Buffer.pas`, `src/Poseidon.Net.Pool.Arena.pas`,
`src/Poseidon.Net.Pool.Workers.pas`, `src/Poseidon.Net.Connection.pas`,
`src/Poseidon.Net.Connection.Manager.pas`, `src/Poseidon.Net.IdleSweep.pas`.

Cross-skill: teardown do servidor invoca drain daqui →
`poseidon-server-src`. Backend I/O é quem dispara `AddRef` →
`poseidon-portability-src`.
