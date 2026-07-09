---
name: poseidon-concurrency-review
description: Revisão focada de concorrência, lifetime de conexão e gerência de memória do Poseidon — refcount AddRef/Release na fronteira IO-thread ↔ worker-pool, teardown no Stop()/Destroy(), idle sweep, pools (Buffer/Arena/Socket/Workers) e estruturas atômicas/lock-free. Use ao auditar threads, corridas de dados, use-after-free, double-free, vazamentos ou aquisição/liberação de buffers. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão de concorrência e lifetime do Poseidon

Escopo: `Poseidon.Net.Connection*.pas`, `Poseidon.Net.HttpServer.pas`
(_ProcessRecv/_DispatchAccumBuf/_CloseConn/Stop), `Poseidon.Net.IdleSweep.pas`,
`Poseidon.Net.Pool.Buffer.pas`, `Pool.Arena.pas`, `Pool.Socket.pas`,
`Pool.Workers.pas`. Aplique a Regra de Ouro de `poseidon-review`.

## Modelo mental
- IO threads (IOCP/RIO/epoll/io_uring) recebem bytes e ACUMULAM em `AccumBuf`;
  o handling pode rodar inline (SyncDispatch) ou ser postado no
  `TElasticWorkerPool`. `TNativeConn.AddRef/Release` mantém a conexão viva
  atravessando essa fronteira assíncrona. `InFlightPool` (contador) e
  `FInFlightCount` governam idle-sweep e backpressure/drain.

## O que caçar
- **Refcount**: todo AddRef tem Release pareado em TODOS os caminhos (inclusive
  exceção)? Post no pool faz AddRef antes e Release no `finally`? Um Release a
  mais → use-after-free; a menos → vazamento/conn presa.
- **Use-after-free / ABA**: `AccumBuf` ou `SSLHandle` acessado após `_CloseConn`;
  ponteiros internos de `TList` (router/conn list) usados após realocação;
  reordenação com pipelining (lambda N+1 postada enquanto N ainda no finally).
- **Ordem de teardown** em `Stop()`/`Destroy()`: shutdown de sockets → drain
  (evento) → cleanup sob lock → shutdown do worker pool → join dos IO workers.
  Procure janelas em que um worker toca um objeto já liberado, ou drain que
  retorna cedo enquanto há request em voo.
- **Idle sweep vs request em voo**: sweep não pode fechar conexão com
  `InFlightPool > 0`; `LastActivityTick` atualizado no momento certo.
- **Atomicidade**: `class var`/campos compartilhados protegidos por `TMonitor`/
  `TCriticalSection`; uso correto de `TInterlocked` (tipo do alvo casa com o
  overload — `Read` exige `var Int64`); leituras rasgadas de 64-bit.
- **Pools**: `Acquire`/`Release` simétricos; buffer de pool liberado em TODO
  caminho de erro (400/413/503/SSL fail); double-release; crescimento do
  `AccumBuf` (copia dados e devolve o antigo); arena thread-local não vaza entre
  requisições; deque lock-free do worker pool (roubo/tail/head) sem ABA.
- **Cache-line/false sharing**: campos "quentes" (contadores atômicos) isolados
  com padding — mudanças que quebrem o isolamento.

## Armadilhas conhecidas (Delphi)
- `New`/`Dispose` de record com campos gerenciados finaliza os campos — não
  libere manualmente duas vezes.
- Passar `const TBytes` para `Release(var TBytes)` não compila; o padrão é copiar
  para uma local (`LTmp := AData; Pool.Release(LTmp)`), o que devolve o mesmo
  bloco.
- `TInterlocked.Read` só existe para `Int64` na RTL 11 — um campo `Integer`
  usado com `Read` é erro de compilação (só pega no Win64/backend Windows).

## Não reporte sem provar
Uma "corrida" precisa de duas threads concretas e o entrelaçamento que corrompe.
Um "use-after-free" precisa da sequência liberação → acesso. Um "vazamento de
refcount" precisa do caminho onde falta o Release. Confirme no fonte, não presuma.
