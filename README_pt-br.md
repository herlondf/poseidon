# Poseidon

> *Deus dos mares — poder bruto, velocidade incomparavel.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  Framework HTTP de alta performance para Delphi e Free Pascal — IOCP/RIO no Windows, io_uring/epoll no Linux.<br/>
  128k RPS com arquitetura shared-nothing. Zero erros com 500 conexoes simultaneas.
</p>

---

## Inicio Rapido

```pascal
program MyServer;
{$APPTYPE CONSOLE}
uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"message":"pong"}');
      end);

    App.Get('/hello/:name',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"hello":"' + Ctx.Param('name') + '"}');
      end);

    App.Listen(9000, '0.0.0.0',
      procedure
      begin
        Writeln('Servidor pronto em http://localhost:9000');
        Readln;
        App.Stop;
      end);
  finally
    App.Free;
  end;
end.
```

## Por que Poseidon

| | Poseidon v2 | Horse Epoll 4.0 |
|---|---|---|
| **Throughput** (500 conn, 16 cores) | **127.532 RPS** | 3.780 RPS (61% erros) |
| **Latencia p50** | **1,92ms** | 103ms |
| **Latencia p99** | **5,51ms** | 287ms |
| **Erros** | **0** | 35K+ Non-2xx |
| **Arquitetura** | Shared-nothing per-core | Single epoll |
| **HTTP/2** | Integrado | Nao |
| **WebSocket** | Integrado | Nao |
| **SSL/TLS** | OpenSSL nativo (SNI, mTLS, ALPN) | Via Indy |
| **Middlewares** | 20 integrados | Comunidade |
| **API Nativa** | Zero-copy, baseada em instancia | N/A |

## Arquitetura: Shared-Nothing Per-Core

```
Kernel distribui via SO_REUSEPORT (hash de IP)
              │
    ┌─────────┼─────────┐
    ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐
│ Core 0 │ │ Core 1 │ │ Core N │
│ listen │ │ listen │ │ listen │  ← socket proprio
│ epoll  │ │ epoll  │ │ epoll  │  ← epoll fd proprio
│ accept │ │ accept │ │ accept │
│ recv   │ │ recv   │ │ recv   │  ← tudo inline
│ parse  │ │ parse  │ │ parse  │
│ handle │ │ handle │ │ handle │
│ send   │ │ send   │ │ send   │
└────────┘ └────────┘ └────────┘
  ~170 conn  ~170 conn  ~170 conn
```

Cada core faz tudo: accept, recv, parse, executa handler, envia resposta. Sem filas, sem locks, sem contencao. Escalamento linear com o numero de cores.

### Selecao de Backend de I/O

O backend e selecionado **uma unica vez** na inicializacao, com fallback automatico:

| Plataforma | Padrao | Alternativo | Forcar Alternativo |
|------------|--------|-------------|--------------------|
| **Windows** | IOCP | RIO (Registered I/O) | `{$DEFINE FORCE_RIO}` |
| **Linux** | io_uring (>= 5.1) | epoll | `{$DEFINE FORCE_EPOLL}` |

- **IOCP**: I/O assincrono padrao do Windows com completion ports (padrao)
- **RIO**: Filas de conclusao em memoria compartilhada, polling sem syscall, buffers pre-registrados (opt-in via `FORCE_RIO`)
- **io_uring**: I/O assincrono do Linux com arquivos registrados (`IORING_REGISTER_FILES`)
- **epoll**: Shared-nothing per-core com `SO_REUSEPORT`

---

## Funcionalidades

### Framework
| Funcionalidade | Status |
|----------------|--------|
| Router hash-map com suporte a `:param` (lookup O(1)) | ✅ |
| Pipeline de middleware (Use, Group, GroupBlock) | ✅ |
| Registro fluente de rotas (Get, Post, Put, Delete, Patch, Head, All) | ✅ |
| Contexto de requisicao stack-allocated (zero-copy) | ✅ |
| Binding de DTO com atributos de validacao | ✅ |
| OpenAPI 3.x + Swagger UI | ✅ |
| RFC 7807 Problem Details | ✅ |
| Cookies assinados (HMAC-SHA256) | ✅ |

### Engine
| Funcionalidade | Status |
|----------------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL), SNI, mTLS | ✅ |
| HTTP/2 (ALPN h2, h2c, server push, flow control) | ✅ |
| WebSocket (RFC 6455, permessage-deflate) | ✅ |
| Compressao gzip + Brotli | ✅ |
| Proxy Protocol v1/v2 | ✅ |
| Graceful reload (PID file, SIGTERM, zero-downtime) | ✅ |
| Windows 64-bit (IOCP / RIO) | ✅ |
| Linux 64-bit (io_uring / epoll) | ✅ |
| Compilador Delphi 11+ | ✅ |
| Free Pascal (FPC 3.3.1) / Lazarus — Win64 + Linux | ✅ |

### Engenharia de Performance
| Funcionalidade | Status |
|----------------|--------|
| Padding de cache-line em contadores atomicos | ✅ |
| Pool de reciclagem de sockets via DisconnectEx (Windows) | ✅ |
| Arquivos registrados no io_uring (Linux) | ✅ |
| I/O vetorizado (writev / WSASend) | ✅ |
| Arena de headers thread-local | ✅ |
| io_uring multishot accept | ✅ |
| Buffer pool (Acquire/Release, 8 KB) | ✅ |

### 20 Middlewares Integrados

| Middleware | Descricao |
|-----------|-----------|
| `Poseidon.Middleware.CORS` | Headers CORS |
| `Poseidon.Middleware.JWT` | Validacao de token Bearer HMAC-SHA256 |
| `Poseidon.Middleware.Logger` | Log de requisicoes |
| `Poseidon.Middleware.RateLimit` | Rate limiter por IP (janela fixa) |
| `Poseidon.Middleware.Compression` | Compressao gzip/deflate na resposta |
| `Poseidon.Middleware.Timeout` | Timeout por requisicao → 503 |
| `Poseidon.Middleware.BodyLimit` | Guarda de Content-Length → 413 |
| `Poseidon.Middleware.RequestID` | Echo/geracao de X-Request-ID |
| `Poseidon.Middleware.CircuitBreaker` | Circuit breaker com janela deslizante → 503 |
| `Poseidon.Middleware.Metrics` | Endpoint Prometheus /metrics |
| `Poseidon.Middleware.Static` | Servidor de arquivos estaticos (ETag, gzip, 304) |
| `Poseidon.Middleware.HealthCheck` | Endpoint /health |
| `Poseidon.Middleware.Security` | Headers de seguranca (HSTS, CSP, X-Frame) |
| `Poseidon.Middleware.Proxy` | Proxy reverso HTTP |
| `Poseidon.Middleware.Digest` | Autenticacao Digest (RFC 7616) |
| `Poseidon.Middleware.Guard` | Guarda de IP whitelist/blacklist |
| `Poseidon.Middleware.Validation` | Validacao de DTO com atributos |
| `Poseidon.Middleware.ProblemDetails` | Formatacao de erros RFC 7807 |
| `Poseidon.Middleware.OpenAPI` | Spec OpenAPI 3.x + Swagger UI |
| `Poseidon.Middleware.Cache` | Cache de resposta em memoria (LRU, ETag, 304) |

---

## Requisitos

- **Delphi 11 Alexandria ou superior**, ou **Free Pascal 3.3.1** (trunk)
- Windows 64-bit ou Linux 64-bit
- OpenSSL no PATH (apenas para HTTPS/HTTP2)

## Instalacao

Adicione `src/`, `src/compat/` e `middlewares/` ao search path do projeto:

```
<poseidon>\src
<poseidon>\src\compat
<poseidon>\middlewares
```

### Free Pascal / Lazarus

O Poseidon compila e serve sob FPC 3.3.1 no Win64 (IOCP) e Linux (io_uring/epoll)
alem do Delphi. Notas:

- Requer **FPC 3.3.1** (trunk) — `reference to` / metodos anonimos e RTTI de
  atributos nao existem no release 3.2.2. Compile com
  `-MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes`.
- No Linux, `cthreads` deve ser a **primeira** unit do programa (`{$IFDEF UNIX}`)
  para ativar o RTL com threads.
- Sob FPC o servidor usa **SyncDispatch** por padrao (dispatch inline); o modo
  async (worker pool) e best-effort no trunk atual do FPC.
- Gates de referencia: `tests/fpc/build-server-fpc.ps1` (Windows),
  `tests/fpc/build-linux-fpc.sh` (Linux).

## Exemplos de Uso

### Middleware

```pascal
uses
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Middleware.CORS,
  Poseidon.Middleware.JWT,
  Poseidon.Middleware.Logger;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;

  App.Use(CORSMiddleware);
  App.Use(LoggerMiddleware);
  App.Use(JWTMiddleware('meu-segredo'));

  App.Get('/api/dados',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Status := 200;
      Ctx.ContentType := 'application/json';
      Ctx.Body := TEncoding.UTF8.GetBytes('{"dados":"protegidos"}');
    end);

  App.Listen(9000);
end.
```

### Grupos de Rotas

```pascal
App.GroupBlock('/api/v1',
  procedure(G: TNativeGroup)
  begin
    G.Get('/users',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('[]');
      end);

    G.Post('/users',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 201;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"id":1}');
      end);
  end);
```

### WebSocket

```pascal
App.WebSocket('/ws',
  procedure(Conn: IPoseidonWSConn; MsgType: Byte; Data: TBytes)
  begin
    Conn.Send(Data);  // echo
  end);
```

### Graceful Reload (Linux)

```pascal
uses
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.GracefulReload;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  App.PIDFile := '/run/poseidon.pid';
  App.PerCoreAccept := True;
  App.DrainTimeoutMs := 5000;

  App.Get('/ping', MeuHandler);

  InstallSignalHandler(procedure begin App.Stop; end);

  App.Listen(8080);
end.
```

Script de deploy:

```bash
OLD_PID=$(cat /run/poseidon.pid)
./poseidon-novo &
sleep 2
kill -TERM $OLD_PID
```

### SSL/TLS

```pascal
App.ConfigureSSL('cert.pem', 'key.pem');
App.AddSSLCert('api.exemplo.com', 'api-cert.pem', 'api-key.pem');  // SNI
App.EnableHTTP2;
App.Listen(443);
```

## Estrutura do Codigo

```
src/
  Poseidon.Native.Server.pas          ← TPoseidonServer (API nativa, baseada em instancia)
  Poseidon.Native.Router.pas          ← router hash-map O(1) para API nativa
  Poseidon.Native.Types.pas           ← TNativeRequestContext, tipos de handler
  Poseidon.Native.Group.pas           ← grupos de rotas
  Poseidon.GracefulReload.pas         ← PID file + handler SIGTERM
  Poseidon.Net.HttpServer.pas         ← orquestrador do servidor HTTP assincrono
  Poseidon.Net.IO.Epoll.pas           ← shared-nothing per-core epoll
  Poseidon.Net.IO.IOCP.pas            ← backend IOCP Windows + reciclagem DisconnectEx
  Poseidon.Net.IO.IOUring.pas         ← backend io_uring Linux + arquivos registrados
  Poseidon.Net.IO.RIO.pas             ← backend RIO Windows (polling sem syscall)
  Poseidon.Net.Dispatcher.pas         ← pattern pipeline (9 etapas)
  Poseidon.Net.Connection.pas         ← estado por conexao (com padding de cache-line)
  Poseidon.Net.Connection.Manager.pas ← admissao de conexao, rastreamento por IP
  Poseidon.Net.SSL.Manager.pas        ← contexto SSL, SNI, mTLS
  Poseidon.Net.WebSocket.Manager.pas  ← handlers WS, upgrade, frames
  Poseidon.Net.HTTP2.Manager.pas      ← upgrade H2C, streams, push
  Poseidon.Net.IdleSweep.pas          ← timeout de conexao ociosa
  Poseidon.Net.ResponseBuilder.pas    ← fragmentos pre-codificados + headers vetorizados
  Poseidon.Net.Pool.Buffer.pas        ← buffer pool (8 KB, Acquire/Release)
  Poseidon.Net.Pool.Arena.pas         ← arena de headers thread-local
  Poseidon.Net.Pool.Socket.pas        ← reciclagem de sockets via DisconnectEx (Windows)
  Poseidon.Net.Pool.Workers.pas       ← pool de worker threads adaptativo
middlewares/
  Poseidon.Middleware.*.pas           ← 20 middlewares prontos para producao
samples/
  01-basic-http-server/               ← setup minimo com TPoseidonServer
  02-ssl-tls/                         ← HTTPS + SNI
  03-websocket/                       ← WebSocket echo
  04-http2/                           ← HTTP/2 com ALPN
  06-security/                        ← hardening de seguranca
  07-http2-server-push/               ← HTTP/2 server push
  08-benchmark/                       ← setup de benchmark
  09-graceful-reload/                 ← restart sem downtime
  10-metrics-dashboard/               ← Prometheus /metrics + dashboard
tests/
  Testes DUnitX                       ← engine + framework + 20 testes de middleware
  fpc/                                ← gates de build + serve sob Free Pascal (Win + Linux)
```

## Documentacao

- [Referência de API](docs/API-REFERENCE_pt-br.md) · [API Reference (EN)](docs/API-REFERENCE.md)
- [Guia de migração v1 → v2](docs/MIGRATION_v1_to_v2_pt-br.md) · [Migration guide (EN)](docs/MIGRATION_v1_to_v2.md)
- [Changelog](CHANGELOG.md)
- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Portugues)](docs/playbook_pt-br/README.md)
- [FuzzRunner — fuzzing contínuo dos parsers](tests/FUZZING.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## A Familia Olimpica

> *Poseidon comanda os mares — poder bruto, a engine assíncrona sob as ondas.*
> *Triton, seu filho, guarda as profundezas — retém as conexões que não podem se perder.*
> *Pégaso voa pelos céus — roteamento HTTP, middleware e providers.*
> *Hermes percorre todos os reinos — carrega mensagens, mais rápido que qualquer onda.*

| Projeto | Mito | Papel |
|---------|------|-------|
| **Poseidon** (este) | Deus dos mares | Framework HTTP assíncrono nativo + engine de I/O — IOCP/RIO, io_uring/epoll |
| [**Triton**](https://github.com/herlondf/triton) | Filho de Poseidon, guardião das profundezas | Pool de recursos genérico — conexões, clientes, SMTP |
| [**Pegasus**](https://github.com/herlondf/pegasus) | Nascido do sangue de Poseidon, cavalgado por heróis | Framework HTTP — roteamento, middleware, providers |
| **Hermes** *(Redis4D)* | Mensageiro dos deuses, guia entre os reinos | Cliente Redis — chave-valor, pub/sub, mensageria |

---

## Licenca

MIT

---

> 🇺🇸 Read this document in English: [README.md](./README.md)
