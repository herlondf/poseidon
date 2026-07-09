---
name: poseidon-src
description: Metodologia e disciplina-mestre para IMPLEMENTAR e corrigir código em src/ do Poseidon (servidor HTTP nativo em Delphi, Win64 IOCP/RIO + Linux epoll/io_uring). Define regras transversais de codificação (CLAUDE.md, thread-safety, portabilidade Win↔Linux), o fluxo obrigatório patch→build→teste, o formato de reporte e as skills irmãs por subsistema. Use SEMPRE que for editar qualquer .pas em src/ (parser, HTTP/2, WebSocket, server, pools, backends I/O, API pública, compressão, segurança), e como base das skills poseidon-*-src específicas (http1, http2, websocket, server, concurrency, portability, api, compression, security). Diferente de poseidon-review, aqui você EDITA — não audita. Middlewares NÃO entram aqui: use poseidon-middlewares-src.
---

# Implementação em src/ do Poseidon — metodologia mestre

Você escreve/corrige código de produção em `src/*.pas`. Fecha o que as skills
`poseidon-*-review` provaram. Não audita, não escreve teste — implementa e
prova que compila em Win64 **e** Linux64 (quando aplicável) e que a suíte
DUnitX segue verde.

## Regra de ouro — patch mínimo e provado

1. Só edite o(s) arquivo(s) apontado(s) pelo achado. Sem "refactor de vizinhança".
2. Antes de digitar, LEIA a unit alvo por inteiro e as units citadas nas
   assinaturas (`.pas`, não doc, não memória). Confirme tipos, overloads e
   `{$IFDEF MSWINDOWS}` reais.
3. Nunca declare "feito" sem: `dcc64` Win64 verde, `dcc64` alvo Linux64 verde
   (quando a unit é multiplataforma), e `Poseidon.Tests.exe` sem regressão.
4. Nenhum caminho absoluto de máquina vai para `.dproj` commitado. Search paths
   temporários somem antes do commit.
5. Se precisar tocar >2 arquivos, PARE e valide o escopo com o usuário.

## Regras do projeto (de CLAUDE.md — obrigatórias)

### Declarações
- Sem `var x := ...` inline. Sempre seção `var` no topo do método.
- Constantes locais → seção `const` do método. Sem magic numbers.
- Sem alinhamento de espaços em declarações (`LName: string` — não `LName:   string`).

### `uses`
- Tipo na declaração de classe → `interface`; só no corpo → `implementation`.
- Uma unit por linha, vírgula ao fim, `;` na última.
- Ordem: RTL/VCL (`System.*`, `Winapi.*`) primeiro, depois units do projeto.

### Nomenclatura (prefixos são LEI)
- Classe: `T` + PascalCase (`TPoseidonHttpServer`).
- Interface: `I` + PascalCase + **GUID único** (nunca copie de outra interface).
- Exceção: `E` + PascalCase (`EPoseidonException`).
- Parâmetro: `A` (`ACtx`, `APort`, `ABuf`).
- Local: `L` (`LConn`, `LResult`).
- Campo: `F` (`FDispatcher`, `FActive`).
- Constante: `C` (`CRecvBufSize`, `CMaxEvents`).

### Comentários
- Default = nenhum. Só quando o WHY não é óbvio (invariante, workaround de RTL,
  referência a RFC/issue). Nunca comente o que o código já diz.

## Thread-safety (regra dura no Poseidon)

- Qualquer estado compartilhado entre IO-thread e worker-thread precisa de:
  - `TInterlocked.*` para contadores e flags. **Overload correto**:
    `TInterlocked.Read` só existe para `Int64` — se o campo é `Integer`, ou muda
    para `Int64`, ou usa `TInterlocked.CompareExchange(campo, 0, 0)`.
  - `TMonitor`/`TCriticalSection` para containers (`TDictionary`, `TList`).
- Nunca acesse `FServer`/`FDispatcher` sem checar `nil` sob lock — padrão
  lazy-init já estabelecido.
- Refcount de `TNativeConn`: `AddRef` na entrada do worker, `Release` no fim.
  Não pareie fora do padrão.

## Portabilidade Windows 64 ↔ Linux 64

- Todo bloco `{$IFDEF MSWINDOWS}` precisa de par `{$ELSE}`/`{$IFDEF LINUX}` se
  a unit é multiplataforma. CI compila só uma face por vez — a outra fica
  latente. Se sua mudança toca I/O, TLS, syscall ou tipo de socket, valide
  **ambos** os builds antes de dar por feito.
- Handle de socket: `TSocket` no Windows (`UIntPtr`), `Integer` no Linux —
  nunca passe cross-plat como tipo cru; use aliases do projeto.
- `var Int64` vs `var Integer`: `TInterlocked.Read` só aceita `Int64`. Corrija
  o campo, não faça cast.

## SOLID / GoF (padrão do projeto)

- Providers herdam de `TPoseidonProviderAbstract` (Template Method).
- Pool novo segue Acquire/Release de `TBufferPool` / `TNativeContextPool`.
- Pipeline de dispatch é array de `TDispatchStep` — para adicionar passo,
  insira no array, sem `if`s aninhados.
- Estratégia de backend I/O selecionada por `{$IFDEF}` em compile-time
  (IOCP/RIO/epoll/io_uring). Não introduza dispatch runtime aqui.
- Interfaces pequenas (ISP). Não engorde `IBufferPool` para "aproveitar" —
  crie interface irmã.

## Fluxo obrigatório ao aplicar um patch

1. **Ler**
   - O achado (arquivo, linha, cenário).
   - A unit alvo por completo.
   - Toda unit citada em `uses` cujo símbolo aparece na mudança.
   - A skill irmã do subsistema (`poseidon-<área>-src`) para invariantes
     específicos.
2. **Planejar em silêncio** — mudança mais localizada que resolve o cenário.
3. **Editar** — preferir `Edit` a `Write`. Preservar indentação (2 espaços) e
   BOM UTF-8 se existir.
4. **Registrar** — se criou `.pas` novo, adicionar no `.dpr` e `.dproj`
   (search path se necessário). Sem caminho absoluto de máquina.
5. **Verificar** (não opcional):
   - Build principal Win64: `dcc64` do projeto/`.dproj`.
   - Se a unit é multiplat: também Linux64. Units puras (Parser,
     ResponseBuilder, Router, Security, HPACK, Validation, Problem,
     Pool.Buffer, Pool.Workers) compilam isoladas via harness `.dpr` em
     `sandbox/` (nunca no `.dproj` principal).
   - Suíte DUnitX: `tests/build_tests.bat` + `Poseidon.Tests.exe`. Colar
     `Tests Found / Passed / Failed` real.
6. **Reportar** — arquivo:linha alterado, uma frase de motivo, saída do build/teste.

## Formato de reporte de patch

```
[arquivo:linha]  <o que mudou em uma frase>
Motivo: <achado que fecha, com referência ao review>.
Build: Win64 OK | Linux64 OK/N/A.
Testes: Tests Found: N, Passed: N, Failed: 0.
```

Se falhou, colar o erro inteiro (não parafrasear) e parar — não "consertar
adjacências".

## Antipadrões (rejeitar antes de commitar)

- `except end` ou `on E: Exception do` sem log/relançar.
- `TInterlocked.Read(FShutdown)` com `FShutdown: Integer` (não compila Linux).
- Alocação em hot path do parser sem passar pelo pool.
- Novo `var` sem prefixo `L` / campo sem `F` / const sem `C`.
- Comentário narrando o código.
- Backwards-compat shim para código morto (delete o código).
- Interface nova com GUID copiado de outra.
- Cast para "passar" em erro de compilação sem entender o overload.

## Skills irmãs (aprofunde por subsistema)

Cada irmã herda esta regra de ouro/fluxo/formato e adiciona invariantes
específicos do subsistema. Ao patchar, LEIA a irmã correspondente antes de
editar.

- `poseidon-http1-src` — Parser, Dispatcher, ResponseBuilder, Router.
- `poseidon-http2-src` — HTTP2, HPACK, HTTP2.Manager.
- `poseidon-websocket-src` — WebSocket, WebSocket.Manager.
- `poseidon-server-src` — HttpServer, Native.Server, Native.Group,
  GracefulReload, Net.IO.
- `poseidon-concurrency-src` — Pool.Buffer, Pool.Arena, Pool.Workers,
  Connection, Connection.Manager, IdleSweep.
- `poseidon-portability-src` — IO.IOCP, IO.RIO, IO.Epoll, IO.IOUring,
  Pool.Socket, MemoryManager.Linux.
- `poseidon-api-src` — Poseidon.pas, Interfaces, Net.Types, Native.Types,
  Status, Problem, Validation, Exception.
- `poseidon-compression-src` — Brotli, SendFile.
- `poseidon-security-src` — Security, ProxyProtocol, SSL, SSL.Manager.

Fora deste split (por escolha explícita):
- `poseidon-middlewares-src` — `middlewares/*` (homogêneas por contrato).
- Performance de src/ é transversal, não vira irmã — mesma lógica do lado review.

## Não faça

- Não edite `middlewares/` aqui — use `poseidon-middlewares-src`.
- Não escreva teste aqui — use `poseidon-tests`.
- Não revise aqui — use `poseidon-*-review`.
- Não altere encoding de arquivo. Não converta 2-espaços para tab.
- Não crie arquivo fora de `D:\IA\Projetos\Delphi\`.
- Não declare verde sem colar a saída do runner.
