# Poseidon

> *God of the seas - raw power, unmatched speed.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  Zero-dependency, native async HTTP framework for Delphi and Free Pascal.<br/>
  IOCP/RIO on Windows, io_uring/epoll on Linux - HTTP/1.1, HTTP/2, WebSocket and 20 built-in middlewares out of the box.<br/>
  <strong>128k RPS, zero errors under 500 concurrent connections.</strong>
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

<p align="center">
  <img src="docs/architecture-flow.svg" alt="Poseidon's shared-nothing per-core request flow vs. Horse's single epoll loop" width="880"/>
</p>

Each core does everything: accept, recv, parse, execute handler, send response. No queues, no locks, no contention. Linear scaling with core count.

The I/O backend is selected **once** at startup, with automatic fallback: **IOCP** (Windows default) or **RIO** (opt-in, zero-syscall polling via `FORCE_RIO`); **io_uring** ≥ 5.1 (Linux default) or **epoll** (fallback / opt-in via `FORCE_EPOLL`).

---

## Performance vs. the Field

Thirteen HTTP servers, one at a time, same machine, same window - the seven already in this
comparison plus six classic representatives of other ecosystems (Node.js, Python, Ruby, PHP,
Java), to answer directly: does an Object Pascal HTTP framework compete on equal footing with the
best-known names in the industry?

**Scenario.** Mixed workload, 40% `/plaintext` (13 B), 30% `/json` (27 B), 30% `/json-large`
(63 KB), driven by `wrk -t4 -c200` for 300 s per framework after a discarded 20 s warm-up.
Every server ran in Docker under `--cpuset-cpus` pinning it to **2 dedicated physical cores**
(`--cpus=2.0`, **1 GB** memory limit); the load generator was isolated on 2 other dedicated
physical cores, on a dedicated bridge network (not `--network host`, so the same script works on
Windows+Docker Desktop too - see the full methodology and trade-offs in
[`benchmark/README.md`](benchmark/README.md)). All thirteen served byte-identical payloads and the
measured request mix came out 40.0/30.0/30.0 for each. Host: debian-bench (4 physical cores
total). Reproduce it yourself with `benchmark/scripts/run-all.sh` (or `.ps1` on Windows) - it
builds and measures all thirteen from each framework's real source, nothing vendored.

uWebSockets (uws) is not in this table. It is not a general-purpose HTTP framework: it is a raw
sockets/event-loop library with no built-in backpressure, connection timeout handling, security
headers, or protocol upgrade support - none of the features every other contender here (Poseidon
included) pays for on the hot path. Measuring throughput against it answers "how fast is a bare
event loop", not "how fast is this framework", which is not the question this table is trying to
answer.

| Rank | Framework | Technology | Req/s | p50 | p99 | Max | Errors |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | Actix | Rust | 27,249 | 4.88 ms | 17.58 ms | 71 ms | 0 |
| **2** | **Poseidon v2** | **Object Pascal** | **25,289** | **5.39 ms** | **23.37 ms** | **95 ms** | **0** |
| 3 | Go Fiber | Go | 23,792 | 7.52 ms | 28.17 ms | 106 ms | 0 |
| 4 | mORMot2 | Object Pascal | 22,634 | 5.67 ms | 30.67 ms | 405 ms | 0 |
| 5 | nginx | C | 18,241 | 9.63 ms | 29.98 ms | 199 ms | 0 |
| 6 | Kestrel | C#/.NET | 10,776 | 15.83 ms | 95.92 ms | 1,539 ms | 200 |
| 7 | Spring Boot | Java | 7,451 | 20.40 ms | 746.93 ms | 1,997 ms | 18 |
| 8 | Horse (Epoll) | Object Pascal | 4,923 | 35.96 ms | 110.29 ms | 211 ms | 0 |
| 9 | Express | Node.js | 2,594 | 74.78 ms | 110.25 ms | 1,981 ms | 56 |
| 10 | FastAPI | Python | 1,501 | 127.39 ms | 188.90 ms | 794 ms | 0 |
| 11 | Django | Python | 643 | 224.35 ms | 493.30 ms | 965 ms | 0 |
| 12 | Rails (Puma) | Ruby | 595 | 324.11 ms | 454.24 ms | 563 ms | 0 |
| 13 | Laravel | PHP | 160 | 1,142.97 ms | 1,787.06 ms | 1,999 ms | 1,414 |

### What the numbers say

Second of thirteen, within 7.2% of first - a hand-written Rust server stays ahead, but by a small
margin. What this table really shows is the distance to the names most people associate with
"production web framework":

- **2.3x Kestrel** (C#/.NET), **3.4x Spring Boot** (Java, the most-used enterprise framework in
  the Java world) and **5.1x Horse** (the other Object Pascal framework on the list).
- **9.8x Express** (the single most-used Node.js framework there is), **16.8x FastAPI** (Python),
  **39x Django** (Python) and **42x Rails on Puma** (Ruby, Rails' own default app server since
  v5).
- **158x Laravel** (PHP) - though that mostly reflects default PHP-FPM saturating under sustained
  load (1,414 errors over 300 s), not a particularly informative comparison on its own.
- Still ahead of Go Fiber, mORMot2 and nginx - the three closest contenders after Actix.

Rails and Django run without a database (none of the three endpoints needs persistence), and
Express/FastAPI/Spring Boot/Kestrel each run their own framework's default server, with no
production tuning beyond the default - see the full trade-offs and the reasoning behind each one
in [`benchmark/README.md`](benchmark/README.md#methodology-notes--honest-caveats).

Two fixes landed in Poseidon during an earlier measurement in this same comparison (on a different,
16-core host): an idle-sweep clock that wrapped in `UInt64` and closed the *busiest* connections
(6,405 spurious socket errors, now zero, and +12% throughput as a side effect), and IO-worker
sizing that ignored the container CPU budget (p99 down 31% in a paired A/B, 67% at 4 CPUs).
Further methodology detail lives in
[`docs/playbook/07-benchmarking`](docs/playbook/07-benchmarking); a standalone (no-Docker) Delphi
benchmark harness lives in [`samples/08-benchmark/`](samples/08-benchmark/) - this table's numbers
come from the reproducible Docker harness in [`benchmark/`](benchmark/).

<p align="center">
  <img src="docs/framework-features.svg" alt="Poseidon protocol/feature comparison against 6 other frameworks" width="880"/>
</p>

Every hot-path change is validated with a controlled before/after run before it merges - same binary, one change at a time. The 2026-08-07 parser/dispatcher pass (dropped a redundant allocation on the `Connection` header, skipped the upgrade-detection scan on non-upgrade GETs) measured **+1.7% throughput**, with every repetition on the "after" side beating every repetition on the "before" side.

---

## Features

**Engine** - HTTP/1.1 keep-alive · HTTP/2 (ALPN h2, h2c, server push, flow control) · WebSocket (RFC 6455, permessage-deflate) · HTTPS native OpenSSL (SNI, mTLS) · gzip + Brotli compression · Proxy Protocol v1/v2 · Graceful reload (PID file, SIGTERM, zero-downtime) · Windows 64-bit (IOCP/RIO) + Linux 64-bit (io_uring/epoll) · Delphi 11+ and Free Pascal 3.3.1

**Framework** - Hash-map router, O(1) lookup, `:param` support · Fluent route registration (Get/Post/Put/Delete/Patch/Head/All) · Zero-copy, stack-allocated request context · DTO binding with validation attributes · OpenAPI 3.x + Swagger UI · RFC 7807 Problem Details · Signed cookies (HMAC-SHA256)

**Performance engineering** - Cache-line padded atomic counters · Vectored I/O (writev/WSASend) · io_uring registered files + multishot accept · DisconnectEx socket recycling (Windows) · Thread-local header arena · 8 KB buffer pool (Acquire/Release)

**20 built-in middlewares** - CORS, JWT, Logger, RateLimit, Compression, Timeout, BodyLimit, RequestID, CircuitBreaker, Metrics, Static, HealthCheck, Security, Proxy, Digest, Guard, Validation, ProblemDetails, OpenAPI, Cache

---

## Requirements

- **Delphi 11 Alexandria or later**, or **Free Pascal 3.3.1** (trunk)
- Windows 64-bit or Linux 64-bit
- OpenSSL in PATH (only for HTTPS/HTTP2)

## Installation

Add `src/`, `src/compat/` and `middlewares/` to your project search path:

```
<poseidon>\src
<poseidon>\src\compat
<poseidon>\middlewares
```

### Free Pascal / Lazarus

Poseidon compiles and serves under FPC 3.3.1 on Win64 (IOCP) and Linux
(io_uring/epoll) in addition to Delphi. Notes:

- Requires **FPC 3.3.1** (trunk) - `reference to` / anonymous methods and
  attribute RTTI are not in the 3.2.2 release. Compile with
  `-MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes`.
- On Linux, make `cthreads` the **first** unit of your program (`{$IFDEF UNIX}`)
  so the threaded RTL is active.
- Under FPC the server defaults to **SyncDispatch** (inline dispatch); the async
  worker-pool mode is best-effort on the current FPC trunk.
- Reference build/run gates: `tests/fpc/build-server-fpc.ps1` (Windows),
  `tests/fpc/build-linux-fpc.sh` (Linux).

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

### WebSocket

```pascal
App.WebSocket('/ws',
  procedure(Conn: IPoseidonWSConn; MsgType: Byte; Data: TBytes)
  begin
    Conn.Send(Data);  // echo
  end);
```

### SSL/TLS

```pascal
App.ConfigureSSL('cert.pem', 'key.pem');
App.AddSSLCert('api.example.com', 'api-cert.pem', 'api-key.pem');  // SNI
App.EnableHTTP2;
App.Listen(443);
```

More recipes (route groups, graceful reload, security hardening, metrics) live in the [playbook](docs/playbook/README.md).

---

## Documentation

- [API Reference](docs/API-REFERENCE.md) · [Referência de API (pt-BR)](docs/API-REFERENCE_pt-br.md)
- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Portugues)](docs/playbook_pt-br/README.md)
- [FuzzRunner - continuous parser fuzzing](tests/FUZZING.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## The Olympian Family

> *Poseidon commands the seas - raw power, the async engine beneath the waves.*
> *Triton, his son, guards the depths - holds the connections that must not be lost.*
> *Hermes runs between all realms - carries messages, faster than any wave.*
> *Hefesto forges in the depths - invisible, tireless, turning raw material into finished work.*
> *Apollo is the god of light and truth - brings everything to light.*

| Project | Myth | Role |
|---------|------|------|
| **Poseidon** (this) | God of the seas | Async-native HTTP framework + I/O engine - IOCP/RIO, io_uring/epoll |
| [**Triton**](https://github.com/herlondf/triton) | Son of Poseidon, guardian of the depths | Generic resource pool - connections, clients, SMTP |
| [**Hermes**](https://github.com/herlondf/hermes) | Messenger of the gods, guide between realms | Redis client - key-value, pub/sub, messaging |
| [**Hefesto**](https://github.com/herlondf/hefesto) | Forgemaster of the gods, works unseen | Background jobs - queues, workers, retry, scheduling |
| [**Apollo**](https://github.com/herlondf/apollo) | God of light and truth, brings things to light | Structured logging - async sinks, OTLP, Seq, Loki, Datadog |

---

## License

MIT

---

> 🇧🇷 Leia este documento em portugues: [README.md](./README.md)
