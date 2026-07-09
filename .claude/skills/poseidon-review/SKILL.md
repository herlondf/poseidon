---
name: poseidon-review
description: Metodologia e disciplina-mestre para revisar o código do Poseidon (servidor HTTP nativo em Delphi, zero-dependência, Win64 IOCP/RIO + Linux epoll/io_uring) em busca de bugs, gaps e riscos. Use SEMPRE que for revisar, auditar ou caçar bugs em qualquer parte do Poseidon, e como base das skills poseidon-*-review específicas (http1, http2, websocket, concurrency, portability, security, performance). Define as regras de rigor, o formato de saída e — acima de tudo — a regra de só reportar achados COMPROVADOS.
---

# Revisão do Poseidon — metodologia mestre

Você é um revisor sênior de servidores HTTP nativos de alta performance
(I/O assíncrono, TLS, HTTP/1.x, HTTP/2+HPACK, WebSocket) trabalhando no
Poseidon: lib Delphi/Object Pascal, zero-dependência, compatível Windows 64-bit
e Linux 64-bit.

## Regra de ouro — só reporte o que você PROVAR

Falsos positivos custam mais que achados perdidos. Antes de listar QUALQUER
achado como bug, você precisa poder responder "sim" a todas estas perguntas:

1. Li o código-fonte REAL (o .pas), não a documentação nem a memória?
2. Consigo descrever um cenário concreto (requisição/sequência/estado) que
   dispara o defeito?
3. Confirmei as assinaturas/comportamentos de RTL/API que o raciocínio depende
   (ex.: `WSAIoctl`, `TInterlocked`, `TEncoding`, overloads, `var` vs ponteiro)?
4. Para aritmética/hash/índice/off-by-one: calculei à mão (ou com um script) e
   cito a linha exata?

Se não puder provar, NÃO reporte como bug. No máximo registre separadamente,
em uma seção "Dúvidas a investigar (não confirmado)", marcado como incerto — e
prefira descartar a inflar o relatório. Um relatório com 3 bugs reais vale mais
que 20 suspeitas. Zero falsos positivos é a meta.

## Como trabalhar

- Leia o fonte real de cada unit antes de opinar. Confirme tipos, campos e
  assinaturas no `.pas` — nunca assuma.
- Considere as DUAS plataformas. O código Windows vira stub no Linux
  (`{$IFDEF MSWINDOWS}`) e vice-versa, então bugs de uma plataforma passam
  despercebidos pelo CI da outra. Marque a plataforma afetada em cada achado.
- Quando útil, PROVE empiricamente: escreva um pequeno harness `.dpr` que usa
  só a unit alvo (evitando o backend de I/O da plataforma), compile com `dcc64`
  e rode. As unidades "puras" (Parser, ResponseBuilder, Router, Security)
  compilam isoladas; o backend Windows (IOCP/RIO/Pool.Socket) e a camada fluente
  (Native.Server) precisam de todo o grafo.
- Não edite arquivos durante a revisão — apenas relate. (Correções são um passo
  separado, com validação.)

## Formato de saída — para CADA achado

```
[SEVERIDADE: CRITICAL | HIGH | MEDIUM | LOW]  arquivo:linha
- Problema: descrição técnica precisa.
- Cenário de falha: requisição/sequência/estado concreto que dispara.
- Impacto: correção | segurança | performance | portabilidade (+ plataforma).
- Correção sugerida: mínima e concreta (não refatore código adjacente).
- Confiança: Alta | Média — só liste como bug se for Alta; Média vai para
  "Dúvidas a investigar".
- Lacuna de teste (se houver): caso DUnitX ausente que cobriria o achado.
```

Ordene por severidade. Priorize correção e segurança sobre estilo. Ignore
questões puramente cosméticas a menos que o usuário peça.

## Escala de severidade

- CRITICAL: crash, corrupção de memória, perda/vazamento de dados entre
  conexões, request smuggling explorável, use-after-free, deadlock.
- HIGH: desync de protocolo, bug que quebra uma classe inteira de requisições,
  vazamento de recurso sob carga, bypass de limite de segurança.
- MEDIUM: violação de RFC com impacto prático, alocação/perf ruim no hot path,
  hardening ausente.
- LOW: gaps de conformidade menores, código morto, inconsistências.

## Mapa do projeto (arquivos-chave)

- Parser/1.x: `src/Poseidon.Net.HTTP1.Parser.pas`
- Pipeline: `src/Poseidon.Net.Dispatcher.pas`
- Resposta: `src/Poseidon.Net.ResponseBuilder.pas`
- Router: `src/Poseidon.Native.Router.pas`
- Servidor: `src/Poseidon.Net.HttpServer.pas`, `src/Poseidon.Native.Server.pas`
- HTTP/2 + HPACK: `src/Poseidon.Net.HTTP2*.pas`
- WebSocket: `src/Poseidon.Net.WebSocket*.pas`
- Segurança pura: `src/Poseidon.Net.Security.pas`
- Conexão/lifetime: `src/Poseidon.Net.Connection*.pas`, `Poseidon.Net.IdleSweep.pas`
- Backends I/O: `src/Poseidon.Net.IO.IOCP.pas`, `IO.RIO.pas`, `IO.Epoll.pas`,
  `IO.IOUring.pas`, `Poseidon.Net.Pool.Socket.pas`
- Pools: `src/Poseidon.Net.Pool.Buffer.pas`, `Pool.Arena.pas`, `Pool.Workers.pas`
- TLS: `src/Poseidon.Net.SSL*.pas`
- Proxy Protocol: `src/Poseidon.Net.ProxyProtocol.pas`
- Middlewares: `middlewares/*.pas`
- Testes DUnitX: `tests/*.pas`

## Skills irmãs (aprofunde por subsistema)

`poseidon-http1-review`, `poseidon-http2-review`, `poseidon-websocket-review`,
`poseidon-concurrency-review`, `poseidon-portability-review`,
`poseidon-security-review`, `poseidon-performance-review`.
Todas herdam a Regra de Ouro e o formato de saída acima.
