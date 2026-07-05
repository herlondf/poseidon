# Poseidon

> *God of the seas — raw power, unmatched speed.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  High-performance REST framework for Delphi — IOCP on Windows, io_uring/epoll on Linux.<br/>
  128k RPS shared-nothing architecture. Zero errors under 500 concurrent connections. Drop-in Horse replacement.
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
| **Middlewares** | 15 built-in | Community |
| **Native API** | Zero-copy, instance-based | N/A |

## v2 Performance Engineering

> **⚠️ Internal documentation — remove before public release.**

### Benchmark Final (16 cores, 500 conn, wrk)

| Metric | Horse Epoll 4.0 | Poseidon v2 | Factor |
|---|---|---|---|
| **Throughput /ping** | 3.780 req/s (61% errors) | **127.532 req/s** | **33.7x** |
| **Throughput /json** | 3.675 req/s (69% errors) | **129.975 req/s** | **35.4x** |
| **Latency p50** | 103ms | **1.92ms** | **54x** |
| **Latency p99** | 287ms | **5.51ms** | **52x** |
| **Errors** | 35K+ Non-2xx | **0** | Poseidon stable |

### Optimization Timeline

| # | Strategy | What it does | Impact |
|---|---|---|---|
| 1 | **SyncDispatch** | Execute handler directly on IO thread, skip worker pool thread transition (~50-100μs/req) | 28K → 45K (+57%) |
| 2 | **Lightweight parser** | Parse only request line + 3 critical headers by byte scan. Zero string allocations for headers. | Included in baseline |
| 3 | **FORCE_EPOLL** | Skip io_uring on WSL2 where virtualization adds overhead. Use epoll directly. | Included in baseline |
| 4 | **TEncoding elimination** | Replace `TEncoding.ASCII.GetString` with direct byte→char widening via PWord. Avoids virtual dispatch + encoding table lookup. | Included in baseline |
| 5 | **GetTickCount64** | Replace `Now` (TDateTime, expensive) with `TThread.GetTickCount64` (vDSO on Linux, no syscall). | Included in baseline |
| 6 | **Pipeline Pattern (#83)** | Replace dual `_DispatchFull`/`_DispatchLightweight` with composable `TDispatchStep` array. 9 steps walked in tight loop. Zero heap allocation (procedure of object). | Refactoring, zero regression |
| 7 | **God Object decomposition (#84-#88)** | Extract 5 managers from `TPoseidonNativeServer` (1537→1176 lines): ConnectionManager, SSLManager, WebSocketManager, HTTP2Manager, IdleSweepManager. | Refactoring, zero regression |
| 8 | **Vectored I/O (#61)** | `writev()` on Linux, `WSASend` with 2 WSABUFs on Windows. Send HTTP headers + body in ONE syscall without concatenation copy. | Eliminates memcpy on send path |
| 9 | **Thread-local header arena (#72)** | `THeaderArena` — reusable TBytes per thread for response headers. Avoids TBufferPool acquire/release round-trip in SyncDispatch mode. | Reduces pool contention |
| 10 | **io_uring multishot accept (#73)** | One `IORING_OP_ACCEPT` with `IOSQE_ACCEPT_MULTISHOT` generates CQEs for all future connections. No accept resubmission. | Reduces accept overhead |
| 11 | **Shared-nothing per-core epoll (#66)** | Each worker thread owns its own `epoll fd` + `listen socket` (SO_REUSEPORT). Accept, recv, parse, handler, send — all inline on the same thread. Zero contention between cores. Kernel distributes connections via IP hash. | **28K → 128K (+358%)** |
| 12 | **Native API (#92-#95)** | `TPoseidonServer` instance-based, `TNativeRequestContext` stack-allocated record, `TNativeRouter` hash-map O(1), `TNativeHandler` procedure of object. Zero WebBroker objects, zero pool, zero per-request closures. Middleware with `Next()` via threadvar chain executor. | Zero-copy API layer |

### Architecture: Shared-Nothing Per-Core

**Before (single epoll):**
```
500 connections → [1 epoll fd] → Thread I/O (bottleneck)
                                      │
                                 dispatch to
                                      │
                              ┌───────┼───────┐
                              ▼       ▼       ▼
                          Worker 1  Worker 2  Worker N
                           (queue)  (queue)   (queue)
```
One I/O thread reads ALL 500 sockets and dispatches to workers. The I/O thread saturates at ~28K events/s regardless of core count.

**After (shared-nothing):**
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
Each core does everything: accept, recv, parse, execute handler, send response. No queues, no locks, no contention. Cores don't know each other exist.

**Why it works:**
- **Zero contention** — no mutex, no lock, no shared variable between cores
- **Cache locality** — connection data stays in L1/L2 of the core that owns it
- **Linear scaling** — 2 cores = 2x, 4 cores = 4x, 16 cores = 16x throughput
- **SO_REUSEPORT** — kernel distributes connections by source IP hash, zero userspace intervention

### Architecture: Native API vs Horse-Compat

```
Horse-compat path (per request):
  InvokeRequest → TOnNativeRequest closure
    → Pool.Acquire(TNativeWebRequest)     ← 1 object
    → Pool.Acquire(TNativeWebResponse)    ← 1 object
    → Pool.Acquire(TPoseidonRequest)      ← 1 object
    → Pool.Acquire(TPoseidonResponse)     ← 1 object
    → Router.Execute → TNextCaller chain  ← N closures (1 per middleware)
    → Res.Send(string)                    ← string→UTF-8 conversion
    → CommitResponse
    → Pool.Release × 4

Native API path (per request):
  InvokeRequest → HandleNativeRequest
    → TNativeRouter.Lookup (hash O(1))    ← zero alloc
    → for loop: middlewares               ← procedure of object, zero alloc
    → Handler(var Ctx)                    ← procedure of object, zero alloc
    → Ctx.Body := PreEncodedBytes         ← TBytes refcount share, zero copy
```

### Key Files (v2 optimizations)

| File | Role |
|---|---|
| `src/Poseidon.Net.IO.Epoll.pas` | Shared-nothing per-core epoll, writev, TCoreWorkerThread |
| `src/Poseidon.Net.Dispatcher.pas` | Pipeline pattern (9 steps), vectored send |
| `src/Poseidon.Net.ResponseBuilder.pas` | BuildHTTPResponseHeaders (headers-only, pool or arena) |
| `src/Poseidon.Native.Server.pas` | TPoseidonServer, native API, chain executor |
| `src/Poseidon.Native.Router.pas` | Hash-map router, param extraction |
| `src/Poseidon.Native.Types.pas` | TNativeRequestContext, handler types |
| `src/Poseidon.Net.Connection.Manager.pas` | Connection admission, per-IP tracking |
| `src/Poseidon.Net.IdleSweep.pas` | Idle connection timeout thread |
| `src/Poseidon.Net.SSL.Manager.pas` | SSL context, SNI, mTLS config |
| `src/Poseidon.Net.WebSocket.Manager.pas` | WS handlers, upgrade, frame dispatch |
| `src/Poseidon.Net.HTTP2.Manager.pas` | H2C upgrade, stream handling |
| `src/Poseidon.Net.Pool.Arena.pas` | Thread-local header buffer |

### Build & Benchmark

```bash
# Clean stale DCUs (CRITICAL — stale .o files cause silent regression)
find vendor/poseidon_v2/ -name "*.o" -delete -o -name "*.dcu" -delete

# Compile
dcclinux64 BenchPoseidonV2Epoll.dpr -DRELEASE -DFORCE_EPOLL \
  -U<vendor_paths> --libpath:<linux_stubs> -NSSystem

# Run (all cores, 500 connections, 15 seconds)
./BenchPoseidonV2Epoll &
sleep 3
wrk -t4 -c500 -d15s http://localhost:9000/ping
wrk -t4 -c500 -d15s http://localhost:9000/json
```

---

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
  Poseidon.pas                        ← entry point (TPoseidon = TPoseidonProviderNative)
  Poseidon.Core.pas                   ← radix router + middleware pipeline
  Poseidon.Request.pas                ← TPoseidonRequest (Horse-compat)
  Poseidon.Response.pas               ← TPoseidonResponse (Horse-compat)
  Poseidon.Native.Server.pas          ← TPoseidonServer (native API, instance-based)
  Poseidon.Native.Router.pas          ← hash-map router O(1) for native API
  Poseidon.Native.Types.pas           ← TNativeRequestContext, handler types
  Poseidon.Net.HttpServer.pas         ← async HTTP server orchestrator
  Poseidon.Net.IO.Epoll.pas           ← shared-nothing per-core epoll
  Poseidon.Net.IO.IOCP.pas            ← Windows IOCP backend
  Poseidon.Net.IO.IOUring.pas         ← Linux io_uring backend
  Poseidon.Net.Dispatcher.pas         ← pipeline pattern (9 steps)
  Poseidon.Net.Connection.Manager.pas ← connection admission, per-IP tracking
  Poseidon.Net.SSL.Manager.pas        ← SSL context, SNI, mTLS
  Poseidon.Net.WebSocket.Manager.pas  ← WS handlers, upgrade, frames
  Poseidon.Net.HTTP2.Manager.pas      ← H2C upgrade, streams, push
  Poseidon.Net.IdleSweep.pas          ← idle connection timeout
  Poseidon.Net.ResponseBuilder.pas    ← pre-encoded response fragments + vectored headers
  Poseidon.Net.Pool.Buffer.pas        ← thread-local buffer pool
  Poseidon.Net.Pool.Arena.pas         ← thread-local header arena
  providers/
    Poseidon.Provider.Native.pas      ← default (IOCP/epoll)
middlewares/
  Poseidon.Middleware.*.pas           ← 15 production-ready middlewares
tests/
  DUnitX tests                        ← engine + framework + dispatcher
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
