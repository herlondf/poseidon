---
name: poseidon-server-src
description: Especialista em IMPLEMENTAR e corrigir a camada de servidor do Poseidon — HttpServer (start/stop/orquestração), Native.Server (API fluente), Native.Group (grupos de rotas), GracefulReload e Net.IO (fachada de backend). Use ao aplicar patches de poseidon-server-review (drain de worker pool, teardown SSL, SetSyncDispatch race, socket leak em except, graceful reload) ou modificar ciclo de vida do servidor. Herda regras de poseidon-src.
---

# Implementação de servidor e ciclo de vida — invariantes

Escopo: `src/Poseidon.Net.HttpServer.pas`, `src/Poseidon.Native.Server.pas`,
`src/Poseidon.Native.Group.pas`, `src/Poseidon.GracefulReload.pas`,
`src/Poseidon.Net.IO.pas`. Regras gerais em `poseidon-src`.

## Ordem de teardown — regra dura

`Stop()`/`Destroy()` DEVE:

1. **Parar** o accept loop (não aceitar novas conexões).
2. **Fechar** listen socket.
3. **Sinalizar** conexões ativas p/ terminar (close notify TLS + close TCP).
4. **Drenar** worker pool esperando refcount 0 — evento é **manual-reset** ou
   contador atômico chegando a 0. Nunca "auto-reset single fire" (perde
   trabalhador que finalizou depois).
5. **Só então** liberar recursos globais: SSL context, buffer pool, dispatcher.

Liberar SSL/dispatcher ANTES do drain = UAF garantido em TLS + handler lento.

## Race no SetSyncDispatch

Trocar `FDispatcher` sob tráfego: worker pode estar dereferenciando o antigo.
Requer:
- Guarda de `FActive`: se ativo, negar troca OU forçar barreira (todos
  workers idle) antes de trocar.
- `FreeAndNil(FDispatcher)` só após drain — mesma regra do Stop.

## Except em _OnNewSocket

Novo socket aceito, mas construção do context/handler falha (OOM, DoS de
allocação, TLS handshake init). O socket foi criado pelo `accept` — se você
sai do `except` sem chamar `SocketClose`, vaza fd. Sob DoS, exaure a tabela
de fds do processo.

Padrão:

```pascal
LSock := accept(...);
try
  ...construção...
except
  SocketClose(LSock);  // <-- obrigatório
  raise;
end;
```

## Native.Server (API fluente) + Native.Group

- Grupos aninhados: middlewares compostos por composição de closures.
  A ordem de aplicação é da OUTERMOST para INNERMOST (grupo pai roda antes do
  filho). Não inverter.
- Rota registrada em runtime: ver `poseidon-http1-src` sobre estabilidade de
  ponteiros do Router.
- Fluent → dispatcher: fronteira é a construção do `TDispatchStep[]` — depois
  disso é imutável no lifetime.

## GracefulReload

- Windows: sinal via Named Pipe/Event nomeado (SIGTERM não existe no Windows
  fora de console).
- Linux: SIGHUP/SIGTERM/SIGUSR2 depende do plano. Ignorar em ambiente sem TTY
  = sem reload.
- Reload duplo em rápida sucessão: idempotente ou serializado. Nunca duas
  transições concorrentes.
- Trocar handler/config em voo segue mesma regra do SetSyncDispatch (barreira
  antes da troca).

## Net.IO — fachada de backend

- Compile-time via `{$IFDEF}`: IOCP/RIO no Windows, epoll/io_uring no Linux.
- Não adicione dispatch runtime aqui. Se precisar de nova estratégia, ela
  vira `{$IFDEF}` com escopo bem definido.
- Detalhes de I/O ficam nas units backend específicas — veja
  `poseidon-portability-src`.

## Bugs típicos

- Evento de drain "single-fire": worker chega tarde, servidor já destruído.
- SSL liberado antes do worker terminar handshake pendente.
- `SetSyncDispatch` sob carga → dispatcher antigo dereferenciado.
- Except silencioso em `_OnNewSocket` → fd leak.
- Reload chamado 2x concorrente → estado inconsistente.

## Arquivos no escopo

`src/Poseidon.Net.HttpServer.pas`, `src/Poseidon.Native.Server.pas`,
`src/Poseidon.Native.Group.pas`, `src/Poseidon.GracefulReload.pas`,
`src/Poseidon.Net.IO.pas`.

Cross-skill: implementação real do I/O → `poseidon-portability-src`.
Refcount/pools → `poseidon-concurrency-src`. Teardown SSL →
`poseidon-security-src`.
