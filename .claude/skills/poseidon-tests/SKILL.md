---
name: poseidon-tests
description: Especialista em IMPLEMENTAR testes do ecossistema Poseidon com DUnitX — testes unitários de units puras (Parser, ResponseBuilder, Router, Security, HPACK, Validation, Problem) e testes de integração de servidor (HTTP/1.x, h2c, WebSocket) com porta dedicada, readiness por evento e cliente RTL/winsock. Use ao adicionar cobertura para um achado de revisão, um novo provider/middleware, ou uma unit sem teste; ao criar mocks; ou ao registrar/rodar a suíte (Poseidon.Tests.dpr/.dproj). Diferente das skills de review, aqui você ESCREVE e roda testes — não audita.
---

# Implementação de testes do Poseidon (DUnitX)

Você constrói testes reais que compilam e passam — não é uma revisão. Alvo:
fechar lacunas de cobertura (em especial as "Lacuna de teste" apontadas pelas
skills de review) e cobrir cada unit/provider/middleware novo.

## Regras do projeto (de CLAUDE.md — obrigatórias)
- Framework: **DUnitX**. Sempre `[TestFixture]`, `[Test]`, e para integração
  `[SetupFixture]`/`[TeardownFixture]`.
- Arquivos de teste: `Poseidon.Tests.<Modulo>.pas` em `tests/`.
  Mocks: `tests/mocks/Poseidon.Mock.<Tipo>.pas`.
- Nome do teste = comportamento: `<Ação>_<Contexto>_<Resultado>`
  (ex.: `Get_Ping_Returns200WithBody`, `Smuggling_CLAndChunked_ReturnsBadRequest`).
- **Um `[Test]` testa uma única coisa.** Sem asserts múltiplos não relacionados.
- **Sem `Sleep` fixo** para esperar o servidor subir — usar `TEvent` (readiness)
  ou poll com timeout.
- Integração NUNCA na porta padrão (9000) — porta dedicada **acima de 19000**,
  uma por fixture (`const CIntestPort = 190xx`).
- Todo provider novo → `Poseidon.Tests.Integration.<Provider>.pas` cobrindo:
  GET simples, parâmetro de rota, POST com body, rota inexistente (404),
  override de status.
- Toda unit de lógica pura (sem I/O) → teste unitário.
- Ao criar um `.pas` de teste, **registrar imediatamente** em `Poseidon.Tests.dpr`
  e `Poseidon.Tests.dproj` (senão não entra na suíte). Não deixar caminho
  absoluto de máquina no `.dproj` (regra de commit).

## Padrões estabelecidos (siga os arquivos existentes)

### Teste unitário de unit pura (modelo: `Poseidon.Tests.HTTP1Parser.pas`)
- Opera sobre `TBytes` crus — sem rede, sem servidor. Um helper `MakeReq(text):
  TBytes` converte o texto do request.
- `{$M+}` ao redor das classes de fixture (necessário p/ RTTI dos métodos `[Test]`).
- Cobrir: caminho feliz, incompleto (retorna False, NÃO bad request), malformado
  (bad request), limites exatos (no-limite e acima), e os casos de segurança
  (smuggling CL+chunked → 400).
- Unidades que compilam isoladas p/ teste rápido: Parser, ResponseBuilder, Router,
  Security, HPACK, Validation, Problem, BufferPool, Workers.

### Teste de integração de servidor (modelo: `Poseidon.Tests.HttpServer.pas`)
- Uma fixture por preocupação, cada uma com sua porta (19001 básico, 19003
  segurança/reliability, 19005 drain, 19006 WS, 19007 h2c...).
- `[SetupFixture]` sobe o servidor numa `TThread`, sinaliza `FEvent: TEvent` quando
  `Listen` está pronto; os testes fazem `FEvent.WaitFor(timeout)` antes de conectar.
  `[TeardownFixture]` chama `Stop`/`Free`.
- Cliente HTTP: `System.Net.HttpClient` (RTL, sem dep externa). Para WS e h2c
  (que precisam de bytes crus): `Winapi.Winsock2` sockets bloqueantes.
- Muitos controles de segurança migraram para middleware — os testes desses vivem
  em `Poseidon.Tests.Middleware.<Nome>.pas`, não no fixture do servidor.

### Mocks (modelo: `tests/mocks/Poseidon.Mock.SSLProvider.pas`, `Poseidon.Mock.Context.pas`)
- Implementam as interfaces de `Poseidon.Net.Interfaces` (`ISSLProvider`,
  `IBufferPool`) ou montam um `TNativeRequestContext` para exercitar middleware
  sem rede. Injete o mock pelo construtor do servidor (passar a interface;
  `nil` = default real).

## Fluxo ao adicionar um teste
1. Leia o `.pas` alvo e um teste vizinho do mesmo tipo para copiar o padrão.
2. Escreva `Poseidon.Tests.<Modulo>.pas` com nomes de teste comportamentais.
3. Registre no `.dpr` (`uses ... in '...'`) e no `.dproj`.
4. Compile e rode a suíte; cole a saída real (passou/falhou). Nunca declare
   "passou" sem rodar.

### Como buildar/rodar (Windows)
- Há scripts em `tests/` (`build_tests.bat`). O runner é `Poseidon.Tests.exe`
  (console DUnitX). Rode e capture o sumário (`Tests Found / Passed / Failed`).
- Para uma unit pura, um harness `.dpr` mínimo em `sandbox/` compilado com `dcc64`
  valida rápido sem subir o backend de I/O. `sandbox/` nunca entra no `.dproj`
  principal (regra de CLAUDE.md).

## Prioridade de cobertura (lacunas conhecidas das reviews)
Ao ser chamado após uma revisão, priorize os casos que os revisores marcaram como
"Lacuna de teste" — eles são o teste de regressão do bug corrigido. Ex.: request
sem headers (`GET / HTTP/1.0\r\n\r\n`), octeto de IP > 255 no `IsIPInCIDR`, HPACK
com comprimento de string ≥ 2³¹, HTTP/2 com header block dividido + END_STREAM,
XFF forjado gerando buckets distintos no RateLimit.

## Não faça
- Não usar `Sleep(500)` "pra garantir". Não reusar a porta 9000. Não deixar
  `.pas` de teste fora do `.dpr`/`.dproj`. Não criar arquivos de teste fora de
  `D:\IA\Projetos\Delphi\`. Não afirmar verde sem a saída do runner.
