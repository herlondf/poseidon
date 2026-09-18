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

Seven HTTP servers, one at a time, same machine, same window.

**Scenario.** Mixed workload, 40% `/plaintext` (13 B), 30% `/json` (27 B), 30% `/json-large`
(63 KB), driven by `wrk -t8 -c200` for 300 s per framework after a discarded 15 s warm-up.
Every server ran in Docker under `--cpuset-cpus` pinning it to **2 dedicated physical cores**
plus `--cpus=2.0` and a **1 GB** memory limit; the load generator was isolated on 4 other
physical cores, so it never competed with the server and never saturated (peak 442% of 800%
available). All seven served byte-identical payloads and the measured request mix came out
40.0/30.0/30.0 for each. Host: Ryzen 7 5800H, WSL2, Linux 6.6.

uWebSockets (uws) is not in this table. It is not a general-purpose HTTP framework: it is a raw
sockets/event-loop library with no built-in backpressure, connection timeout handling, security
headers, or protocol upgrade support - none of the features every other contender here (Poseidon
included) pays for on the hot path. Measuring throughput against it answers "how fast is a bare
event loop", not "how fast is this framework", which is not the question this table is trying to
answer.

| Rank | Framework | Technology | Req/s | p50 | p99 | Max | Errors |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | Actix | Rust | 37,146 | 5.12 ms | 15.21 ms | 143 ms | 0 |
| **2** | **Poseidon v2** | **Object Pascal** | **35,941** | **5.30 ms** | **10.19 ms** | **64 ms** | **0** |
| 3 | Go Fiber | Go | 30,641 | 6.39 ms | 18.60 ms | 52 ms | 0 |
| 4 | mORMot2 | Object Pascal | 28,077 | 6.88 ms | 44.80 ms | 1,810 ms | 1 |
| 5 | nginx | C | 20,281 | 9.29 ms | 20.08 ms | 307 ms | 0 |
| 6 | Kestrel | C# / .NET | 17,599 | 10.31 ms | 29.94 ms | 101 ms | 0 |
| 7 | Horse (Epoll) | Object Pascal | 2,554 | 79.63 ms | 799.25 ms | 1,990 ms | 64 |

### Resource usage

Same run, sampled every 5 s from the server container. Every framework saturated both CPUs, so
CPU does not separate them; memory does.

| Rank | Framework | Technology | Mem peak | Mem avg | CPU avg | Requests served |
|---:|---|---|---:|---:|---:|---:|
| **1** | **Poseidon v2** | **Object Pascal** | **5.2 MB** | **4.3 MB** | **199%** | **10,785,241** |
| 2 | Go Fiber | Go | 7.2 MB | 6.7 MB | 197% | 9,195,118 |
| 3 | Actix | Rust | 19.2 MB | 17.1 MB | 202% | 11,145,622 |
| 4 | nginx | C | 21.8 MB | 20.8 MB | 198% | 6,086,278 |
| 5 | mORMot2 | Object Pascal | 33.8 MB | 31.3 MB | 202% | 8,425,615 |
| 6 | Kestrel | C# / .NET | 81.4 MB | 74.6 MB | 196% | 5,281,181 |
| 7 | Horse (Epoll) | Object Pascal | 116.5 MB | 99.1 MB | 196% | 766,574 |

### What the numbers say

Second of seven on raw throughput, within 3.2% of first - inside the run-to-run variance of this
machine. A hand-written Rust server and a Delphi framework are, on this workload, the same speed.
But raw throughput is the least interesting line in the table. Read the other columns:

- **Best p99 and best maximum of the entire field.** 10.19 ms and 64 ms, against 15.21 ms / 143 ms
  for Actix and 18.60 ms / 52 ms for Go Fiber. Under a container limit, tail latency is what your
  users actually feel, and Poseidon holds the flattest tail of any server here.
- **Smallest memory footprint of the entire field.** 5.2 MB peak, against 19.2 MB for Actix,
  81 MB for Kestrel and 116 MB for Horse. That is 15x less RAM than Kestrel for twice its
  throughput, which is the difference between one container and four.
- **Zero errors in 10.8 million requests.** No timeouts, no resets, no non-2xx. Only three of the
  seven managed that.
- **14x Horse**, on the same compiler and the same runtime, with 22x less memory.

Two fixes landed in Poseidon while this was measured. An idle-sweep clock that wrapped in `UInt64`
and closed the *busiest* connections (6,405 spurious socket errors, now zero, and +12% throughput
as a side effect), and IO-worker sizing that ignored the container CPU budget (p99 down 31% in a
paired A/B, 67% at 4 CPUs). Full methodology lives in the separate `Benchmark` harness (pointers in
[`docs/playbook/07-benchmarking`](docs/playbook/07-benchmarking)); this repo's own reproducible
numbers are in [`samples/08-benchmark/`](samples/08-benchmark/).

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
