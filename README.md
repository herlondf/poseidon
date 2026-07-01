# Poseidon

> *God of the seas — raw power, unmatched speed.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  High-performance REST framework for Delphi — IOCP on Windows, io_uring/epoll on Linux.<br/>
  29k RPS with router &amp; middleware. Zero erros under 200 concurrent users. Drop-in Horse replacement.
</p>

---

## Quick Start

```pascal
uses Poseidon;

begin
  TPoseidon.Get('/ping',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send('pong');
    end);

  TPoseidon.Get('/users/:id',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Json(TJSONObject.Create.AddPair('id', Req.Params.Get('id')));
    end);

  TPoseidon.Listen(9000);
end.
```

## Why Poseidon

| | Poseidon | Horse + Indy |
|---|---|---|
| **Throughput** (200 VUs, 2min) | 28,885 RPS | 2,091 RPS |
| **Latency p95** | 22ms | 156ms |
| **Errors** | 0% | 5-80% |
| **HTTP/2** | Built-in | No |
| **WebSocket** | Built-in | No |
| **SSL/TLS** | Native OpenSSL (SNI, mTLS, ALPN) | Via Indy |
| **Middlewares** | 15 built-in | Community |
| **Validation** | `[Required]`, `[Email]`, `[Range]` | Manual |
| **OpenAPI** | Built-in Swagger UI | Community |

## Features

### Framework
| Feature | Status |
|---------|--------|
| Radix-tree router with `:param` support | ✅ |
| Middleware pipeline (Use, Group, GroupBlock) | ✅ |
| Request: Body, Query, Params, Headers, Cookie, Session | ✅ |
| Response: Send, Json, Status, Header, Redirect, SendFile | ✅ |
| DTO binding with validation attributes | ✅ |
| OpenAPI 3.x + Swagger UI | ✅ |
| RFC 7807 Problem Details | ✅ |
| Signed cookies (HMAC-SHA256) | ✅ |
| Horse API compatibility (opt-in shim) | ✅ |

### Engine
| Feature | Status |
|---------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL), SNI, mTLS | ✅ |
| HTTP/2 (ALPN h2, h2c, server push, flow control) | ✅ |
| WebSocket (RFC 6455, permessage-deflate) | ✅ |
| gzip + Brotli compression | ✅ |
| Rate limiting (per-IP, global) | ✅ |
| Prometheus metrics | ✅ |
| Proxy Protocol v1/v2 | ✅ |
| Security headers, path traversal & smuggling protection | ✅ |
| Windows 64-bit (IOCP) | ✅ |
| Linux 64-bit (io_uring ≥ 5.6, epoll fallback) | ✅ |

### Built-in Middlewares

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
| `Poseidon.Middleware.Security` | Security headers |
| `Poseidon.Middleware.Proxy` | HTTP proxy |
| `Poseidon.Middleware.Digest` | Digest authentication |

## Requirements

- Delphi 11 Alexandria or later
- Windows 64-bit or Linux 64-bit
- OpenSSL in PATH (only for HTTPS/HTTP2)

## Installation

Add `src/`, `src/providers/` and `middlewares/` to your project search path:

```
<poseidon>\src
<poseidon>\src\providers
<poseidon>\middlewares
```

## Usage Examples

### Middleware

```pascal
uses Poseidon, Poseidon.Middleware.CORS, Poseidon.Middleware.JWT;

TPoseidon.Use(TPoseidonMiddlewareCORS.New);
TPoseidon.Use('/api', TPoseidonMiddlewareJWT.New('my-secret'));

TPoseidon.Get('/api/data',
  procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
  begin
    Res.Json(TJSONObject.Create.AddPair('user', Req.Session<TMySession>.Name));
  end);

TPoseidon.Listen(9000);
```

### DTO Validation

```pascal
type
  [Required]
  TCreateUserDTO = class
    [Required] [MinLength(3)]
    Name: string;
    [Required] [Email]
    Email: string;
    [Range(1, 150)]
    Age: Integer;
  end;

TPoseidon.Post('/users',
  procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
  var DTO: TCreateUserDTO;
  begin
    DTO := Req.BodyAs<TCreateUserDTO>;  // validates automatically, 422 on failure
    try
      Res.Status(201).Json(DTO, False);
    finally
      DTO.Free;
    end;
  end);
```

### Horse Migration

For gradual migration from Horse, create a `Horse.pas` shim in your project:

```pascal
unit Horse;
interface
uses Poseidon;
type
  THorse = TPoseidon;
  THorseRequest = TPoseidonRequest;
  THorseResponse = TPoseidonResponse;
  THorseCallback = TPoseidonCallback;
  EHorseException = EPoseidonException;
  EHorseCallbackInterrupted = EPoseidonCallbackInterrupted;
implementation
end.
```

Existing Horse code compiles without changes. Remove the shim once migration is complete.

## Source Layout

```
src/
  Poseidon.pas                     ← entry point (TPoseidon = TPoseidonProviderNative)
  Poseidon.Core.pas                ← radix router + middleware pipeline
  Poseidon.Request.pas             ← TPoseidonRequest
  Poseidon.Response.pas            ← TPoseidonResponse
  Poseidon.Validation.pas          ← [Required], [Email], [Range], [Pattern]
  Poseidon.OpenAPI.pas             ← Swagger UI
  Poseidon.Net.HttpServer.pas      ← async HTTP server (IOCP / io_uring / epoll)
  Poseidon.Net.HTTP2.pas           ← HTTP/2 + HPACK
  Poseidon.Net.WebSocket.pas       ← WebSocket + permessage-deflate
  Poseidon.Net.SSL.pas             ← OpenSSL (SNI, ALPN, mTLS)
  providers/
    Poseidon.Provider.Native.pas   ← default (IOCP/epoll)
    Poseidon.Provider.Indy.pas     ← fallback (WebBroker)
middlewares/
  Poseidon.Middleware.*.pas        ← 15 production-ready middlewares
tests/
  515 DUnitX tests                 ← engine + framework + middleware integration
```

## Documentation

- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Português)](docs/playbook_pt-br/README.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## The Olympian Family

| Project | Role |
|---------|------|
| **Poseidon** (this) | REST framework + async HTTP engine |
| [**Triton**](https://github.com/herlondf/triton) | Generic resource pool (connections, clients) |
| **Hermes** *(Redis4D)* | Redis client (key-value, pub/sub) |

---

## License

MIT

---

> 🇧🇷 Leia este documento em português: [README_pt-br.md](./README_pt-br.md)
