# Poseidon

> *God of the seas — raw power, unmatched speed.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  High-performance HTTP framework for Delphi — RIO/IOCP on Windows, io_uring/epoll on Linux.<br/>
  128k RPS shared-nothing architecture. Zero errors under 500 concurrent connections.
</p>

---

## Quick Start

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
        Writeln('Server ready on http://localhost:9000');
        Readln;
        App.Stop;
      end);
  finally
    App.Free;
  end;
end.
```

## Why Poseidon

| | Poseidon v2 | Horse Epoll 4.0 |
|---|---|---|
| **Throughput** (500 conn, 16 cores) | **127,532 RPS** | 3,780 RPS (61% errors) |
| **Latency p50** | **1.92ms** | 103ms |
| **Latency p99** | **5.51ms** | 287ms |
| **Errors** | **0** | 35K+ Non-2xx |
| **Architecture** | Shared-nothing per-core | Single epoll |
| **HTTP/2** | Built-in | No |
| **WebSocket** | Built-in | No |
| **SSL/TLS** | Native OpenSSL (SNI, mTLS, ALPN) | Via Indy |
| **Middlewares** | 20 built-in | Community |
| **Native API** | Zero-copy, instance-based | N/A |

## Architecture: Shared-Nothing Per-Core

```
Kernel distributes via SO_REUSEPORT (IP hash)
              │
    ┌─────────┼─────────┐
    ▼         ▼         ▼
┌────────┐ ┌────────┐ ┌────────┐
│ Core 0 │ │ Core 1 │ │ Core N │
│ listen │ │ listen │ │ listen │  ← own socket
│ epoll  │ │ epoll  │ │ epoll  │  ← own epoll fd
│ accept │ │ accept │ │ accept │
│ recv   │ │ recv   │ │ recv   │  ← all inline
│ parse  │ │ parse  │ │ parse  │
│ handle │ │ handle │ │ handle │
│ send   │ │ send   │ │ send   │
└────────┘ └────────┘ └────────┘
  ~170 conn  ~170 conn  ~170 conn
```

Each core does everything: accept, recv, parse, execute handler, send response. No queues, no locks, no contention. Linear scaling with core count.

### I/O Backend Selection

Backend is selected **once** at server startup, with automatic fallback:

| Platform | Primary | Fallback | Force Fallback |
|----------|---------|----------|----------------|
| **Windows** | RIO (Registered I/O) | IOCP | `{$DEFINE FORCE_IOCP}` |
| **Linux** | io_uring (≥ 5.6) | epoll | `{$DEFINE FORCE_EPOLL}` |

- **RIO**: Shared-memory completion queues, zero-syscall polling, pre-registered buffers
- **IOCP**: Standard Windows async I/O with completion ports
- **io_uring**: Linux async I/O with registered files (`IORING_REGISTER_FILES`)
- **epoll**: Shared-nothing per-core with `SO_REUSEPORT`

---

## Features

### Framework
| Feature | Status |
|---------|--------|
| Hash-map router with `:param` support (O(1) lookup) | ✅ |
| Middleware pipeline (Use, Group, GroupBlock) | ✅ |
| Fluent route registration (Get, Post, Put, Delete, Patch, Head, All) | ✅ |
| Stack-allocated request context (zero-copy) | ✅ |
| DTO binding with validation attributes | ✅ |
| OpenAPI 3.x + Swagger UI | ✅ |
| RFC 7807 Problem Details | ✅ |
| Signed cookies (HMAC-SHA256) | ✅ |

### Engine
| Feature | Status |
|---------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL), SNI, mTLS | ✅ |
| HTTP/2 (ALPN h2, h2c, server push, flow control) | ✅ |
| WebSocket (RFC 6455, permessage-deflate) | ✅ |
| gzip + Brotli compression | ✅ |
| Proxy Protocol v1/v2 | ✅ |
| Graceful reload (PID file, SIGTERM, zero-downtime) | ✅ |
| Windows 64-bit (RIO / IOCP) | ✅ |
| Linux 64-bit (io_uring / epoll) | ✅ |

### Performance Engineering
| Feature | Status |
|---------|--------|
| Cache-line padding on atomic counters | ✅ |
| DisconnectEx socket recycling pool (Windows) | ✅ |
| io_uring registered files (Linux) | ✅ |
| Vectored I/O (writev / WSASend) | ✅ |
| Thread-local header arena | ✅ |
| io_uring multishot accept | ✅ |
| Buffer pool (Acquire/Release, 8 KB) | ✅ |

### 20 Built-in Middlewares

| Middleware | Description |
|-----------|-------------|
| `Poseidon.Middleware.CORS` | CORS headers |
| `Poseidon.Middleware.JWT` | HMAC-SHA256 Bearer token validation |
| `Poseidon.Middleware.Logger` | Request logging |
| `Poseidon.Middleware.RateLimit` | Fixed-window IP rate limiter |
| `Poseidon.Middleware.Compression` | gzip/deflate response compression |
| `Poseidon.Middleware.Timeout` | Per-request timeout → 503 |
| `Poseidon.Middleware.BodyLimit` | Content-Length guard → 413 |
| `Poseidon.Middleware.RequestID` | X-Request-ID echo/generate |
| `Poseidon.Middleware.CircuitBreaker` | Sliding-window circuit breaker → 503 |
| `Poseidon.Middleware.Metrics` | Prometheus /metrics endpoint |
| `Poseidon.Middleware.Static` | Static file server (ETag, gzip, 304) |
| `Poseidon.Middleware.HealthCheck` | /health endpoint |
| `Poseidon.Middleware.Security` | Security headers (HSTS, CSP, X-Frame) |
| `Poseidon.Middleware.Proxy` | HTTP reverse proxy |
| `Poseidon.Middleware.Digest` | Digest authentication (RFC 7616) |
| `Poseidon.Middleware.Guard` | IP whitelist/blacklist guard |
| `Poseidon.Middleware.Validation` | DTO validation with attributes |
| `Poseidon.Middleware.ProblemDetails` | RFC 7807 error formatting |
| `Poseidon.Middleware.OpenAPI` | OpenAPI 3.x spec + Swagger UI |
| `Poseidon.Middleware.Cache` | In-memory response cache (LRU, ETag, 304) |

---

## Requirements

- Delphi 11 Alexandria or later
- Windows 64-bit or Linux 64-bit
- OpenSSL in PATH (only for HTTPS/HTTP2)

## Installation

Add `src/` and `middlewares/` to your project search path:

```
<poseidon>\src
<poseidon>\middlewares
```

## Usage Examples

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
  App.Use(JWTMiddleware('my-secret'));

  App.Get('/api/data',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Status := 200;
      Ctx.ContentType := 'application/json';
      Ctx.Body := TEncoding.UTF8.GetBytes('{"data":"protected"}');
    end);

  App.Listen(9000);
end.
```

### Route Groups

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

  App.Get('/ping', MyHandler);

  InstallSignalHandler(procedure begin App.Stop; end);

  App.Listen(8080);
end.
```

Deploy script:

```bash
OLD_PID=$(cat /run/poseidon.pid)
./poseidon-new &
sleep 2
kill -TERM $OLD_PID
```

### SSL/TLS

```pascal
App.ConfigureSSL('cert.pem', 'key.pem');
App.AddSSLCert('api.example.com', 'api-cert.pem', 'api-key.pem');  // SNI
App.EnableHTTP2;
App.Listen(443);
```

## Source Layout

```
src/
  Poseidon.Native.Server.pas          ← TPoseidonServer (native API, instance-based)
  Poseidon.Native.Router.pas          ← hash-map router O(1) for native API
  Poseidon.Native.Types.pas           ← TNativeRequestContext, handler types
  Poseidon.Native.Group.pas           ← route groups
  Poseidon.GracefulReload.pas         ← PID file + SIGTERM handler
  Poseidon.Net.HttpServer.pas         ← async HTTP server orchestrator
  Poseidon.Net.IO.Epoll.pas           ← shared-nothing per-core epoll
  Poseidon.Net.IO.IOCP.pas            ← Windows IOCP backend + DisconnectEx recycling
  Poseidon.Net.IO.IOUring.pas         ← Linux io_uring backend + registered files
  Poseidon.Net.IO.RIO.pas             ← Windows RIO backend (zero-syscall polling)
  Poseidon.Net.Dispatcher.pas         ← pipeline pattern (9 steps)
  Poseidon.Net.Connection.pas         ← per-connection state (cache-line padded)
  Poseidon.Net.Connection.Manager.pas ← connection admission, per-IP tracking
  Poseidon.Net.SSL.Manager.pas        ← SSL context, SNI, mTLS
  Poseidon.Net.WebSocket.Manager.pas  ← WS handlers, upgrade, frames
  Poseidon.Net.HTTP2.Manager.pas      ← H2C upgrade, streams, push
  Poseidon.Net.IdleSweep.pas          ← idle connection timeout
  Poseidon.Net.ResponseBuilder.pas    ← pre-encoded response fragments + vectored headers
  Poseidon.Net.Pool.Buffer.pas        ← buffer pool (8 KB, Acquire/Release)
  Poseidon.Net.Pool.Arena.pas         ← thread-local header arena
  Poseidon.Net.Pool.Socket.pas        ← DisconnectEx socket recycling (Windows)
  Poseidon.Net.Pool.Workers.pas       ← adaptive worker thread pool
middlewares/
  Poseidon.Middleware.*.pas           ← 20 production-ready middlewares
samples/
  01-basic-http-server/               ← minimal TPoseidonServer setup
  02-ssl-tls/                         ← HTTPS + SNI
  03-websocket/                       ← WebSocket echo
  04-http2/                           ← HTTP/2 with ALPN
  06-security/                        ← security hardening
  07-http2-server-push/               ← HTTP/2 server push
  08-benchmark/                       ← benchmark setup
  09-graceful-reload/                 ← zero-downtime restart
tests/
  DUnitX tests                        ← engine + framework + 20 middleware tests
```

## Documentation

- [API Reference](docs/API-REFERENCE.md) · [Referência de API (pt-BR)](docs/API-REFERENCE_pt-br.md)
- [Migration guide v1 → v2](docs/MIGRATION_v1_to_v2.md) · [Guia de migração (pt-BR)](docs/MIGRATION_v1_to_v2_pt-br.md)
- [Changelog](CHANGELOG.md)
- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Portugues)](docs/playbook_pt-br/README.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## The Olympian Family

| Project | Role |
|---------|------|
| **Poseidon** (this) | HTTP framework + async engine |
| [**Triton**](https://github.com/herlondf/triton) | Generic resource pool (connections, clients) |
| **Hermes** *(Redis4D)* | Redis client (key-value, pub/sub) |

---

## License

MIT

---

> 🇧🇷 Leia este documento em portugues: [README_pt-br.md](./README_pt-br.md)
