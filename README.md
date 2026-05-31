# Poseidon

> *God of the seas — raw transport, the force of the waves.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  High-performance async HTTP server for Delphi — IOCP on Windows, epoll on Linux.<br/>
  Zero external dependencies. Single WSASend per response. WebSocket, SSL/TLS and HTTP/2 built-in.
</p>

---

## Overview

Poseidon is a standalone Delphi library that provides a native async I/O HTTP server.
It is used as the transport layer for [Pegasus](https://github.com/herlondf/pegasus) and
[Horse](https://github.com/HashLoad/horse) when the `HORSE_ASYNCIO` define is active.

| Feature | Status |
|---------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL) | ✅ |
| SNI multi-cert | ✅ |
| mTLS (client certificates) | ✅ |
| WebSocket | ✅ |
| HTTP/2 (h2 via ALPN) | ✅ |
| HTTP/2 cleartext (h2c upgrade) | ✅ |
| HTTP/2 flow control (RFC 7540 §6.9) | ✅ |
| gzip compression | ✅ |
| Rate limiting (per-IP and global) | ✅ |
| Prometheus metrics endpoint | ✅ |
| Proxy Protocol v1/v2 | ✅ |
| Security headers (opt-in) | ✅ |
| Path traversal & request smuggling protection | ✅ |
| Linux 64-bit (epoll) | ✅ |
| Windows 64-bit (IOCP) | ✅ |

## Requirements

- Delphi 11 Alexandria or later
- Linux 64-bit or Windows 64-bit target
- OpenSSL (`libssl` / `libcrypto`) in PATH — only for HTTPS/HTTP2

## Installation

Clone the repository and add the `src/` directory to your project's search path.
No package install needed.

```
{search path}
<path-to-poseidon>\src\
```

## Quick Start

```pascal
uses Poseidon.Net.HttpServer;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  LServer.Listen('0.0.0.0', 9000,
    procedure(const AReq: TPoseidonNativeRequest;
              out AStatus: Integer;
              out AContentType: string;
              out ABody: TBytes;
              out AExtraHeaders: TArray<TPair<string,string>>)
    begin
      AStatus      := 200;
      AContentType := 'text/plain';
      ABody        := TEncoding.UTF8.GetBytes('Hello, world!');
    end,
    procedure begin Writeln('Listening on :9000'); end);
end;
```

See [`samples/`](samples/) for runnable examples.

## Configuration at a Glance

### Security

| Property / Method | Default | Description |
|-------------------|---------|-------------|
| `AllowedMethods` | `[]` (all) | Allowlist of HTTP verbs — unlisted verbs return 405 |
| `MinTLSVersion` | `$0303` (TLS 1.2) | Minimum TLS version; `0` = library default |
| `ConfigureMTLS(CAFile)` | — | Require client certificates signed by the given CA bundle |
| `SecureHeadersEnabled` | `False` | Inject `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy` |
| `ServerBanner` | `'Poseidon/1.0'` | `Server:` header value; `''` suppresses the header entirely |

### Limits & Reliability

| Property | Default | Description |
|----------|---------|-------------|
| `MaxRequestSize` | 8 MB | Maximum accumulated request size — returns 413 when exceeded |
| `MaxHeaderSize` | 64 KB | Maximum header section size — returns 400 when exceeded |
| `MaxWSFrameSize` | 0 (unlimited) | Maximum WebSocket frame payload — closes with 1009 when exceeded |
| `MaxQueueDepth` | 0 (unlimited) | Max concurrent in-flight requests — returns 503 when exceeded |
| `MaxConnections` | 0 (unlimited) | Maximum total concurrent connections |
| `MaxConnectionsPerIP` | 0 (unlimited) | Maximum connections from a single IP |
| `DrainTimeoutMs` | 30 000 ms | Maximum wait for in-flight requests during `Stop()` |
| `IdleTimeoutMs` | 10 000 ms | Idle connection timeout; `0` disables |

### Performance & HTTP/2

| Property | Default | Description |
|----------|---------|-------------|
| `WorkerCount` | 200 | Worker thread count; `0` = auto (`CPU × 2`, min 4) |
| `CompressionEnabled` | `False` | Enable inline gzip for text responses > 1 KB |
| `HTTP2Enabled` | `False` | Enable HTTP/2 via ALPN (requires SSL) |
| `H2MaxConcurrentStreams` | 100 | `SETTINGS_MAX_CONCURRENT_STREAMS` sent to clients |
| `H2InitialWindowSize` | 65535 | `SETTINGS_INITIAL_WINDOW_SIZE` sent to clients |
| `TCPFastOpen` | `False` | Enable TCP Fast Open (RFC 7413); silently ignored if unsupported |

### Observability

| Property | Default | Description |
|----------|---------|-------------|
| `MetricsEnabled` | `False` | Expose Prometheus metrics at `MetricsPath` |
| `MetricsPath` | `'/metrics'` | Endpoint path for Prometheus scraping |
| `MetricsAllowedCIDR` | `''` (all) | Restrict scraping to this CIDR (e.g. `'10.0.0.0/8'`) |
| `RateLimitPerIP` | 0 (off) | Max requests/second from a single IP — returns 429 |
| `RateLimitGlobal` | 0 (off) | Max requests/second across all clients — returns 429 |
| `ProxyProtocol` | `ppDisabled` | Proxy Protocol mode: `ppDisabled`, `ppV1`, `ppV2`, `ppAuto` |
| `OnLog` | `nil` | Error log callback; `nil` writes to `ErrOutput` |
| `OnRequestLog` | `nil` | Access log callback (method, path, status, latency, bytes) |

### Dependency Injection (R-6)

The constructor accepts optional interfaces for unit-testing and customization:

```pascal
constructor Create(
  ABufferPool:  IBufferPool          = nil;   // nil → built-in multi-tier pool
  ASSLProvider: ISSLProvider         = nil;   // nil → real OpenSSL
  ACompression: ICompressionProvider = nil);  // nil → ZLib gzip
```

Pass a spy or stub in tests; pass `nil` in production for the real defaults.

## Documentation

- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Português)](docs/playbook_pt-br/README.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## Source layout

```
src/
  Poseidon.Net.HttpServer.pas        ← core server (IOCP / epoll)
  Poseidon.Net.Connection.pas        ← connection object (ref-counted)
  Poseidon.Net.Dispatcher.pas        ← protocol dispatcher (HTTP/WS/H2)
  Poseidon.Net.HTTP1.Parser.pas      ← HTTP/1.1 request parser
  Poseidon.Net.HTTP2.pas             ← HTTP/2 (HPACK + flow control)
  Poseidon.Net.WebSocket.pas         ← WebSocket frame handling (zero-copy)
  Poseidon.Net.SSL.pas               ← OpenSSL bindings + SNI + mTLS
  Poseidon.Net.Security.pas          ← pure validation (IsPathSafe, StripCRLF …)
  Poseidon.Net.Pool.Buffer.pas       ← multi-tier buffer pool (8 / 64 / 512 KB)
  Poseidon.Net.ResponseBuilder.pas   ← pooled HTTP response builder
  Poseidon.Net.Interfaces.pas        ← IBufferPool, ISSLProvider, ICompressionProvider
  Poseidon.Net.Metrics.pas           ← Prometheus exposition format
  Poseidon.Net.ProxyProtocol.pas     ← Proxy Protocol v1/v2 parser
  Poseidon.Net.IO.pas                ← IO backend interface
  Poseidon.Net.IO.IOCP.pas           ← Windows IOCP backend
  Poseidon.Net.IO.Epoll.pas          ← Linux epoll backend
```

## The Olympian Family

> *Poseidon commands the seas — raw transport, the force of the waves.*
> *Triton guards his father's waters — manages what flows, holds what must not be lost.*
> *Pegasus flies through the skies — born from Medusa's blood, by the sword Hermes gave to Perseus.*
> *Hermes runs between all realms — carries messages between gods, mortals and monsters, faster than any wave.*

| Project | Myth | Role |
|---------|------|------|
| **Poseidon** (this lib) | God of the seas | Async transport layer — IOCP/epoll, raw I/O |
| [**Triton**](https://github.com/herlondf/triton) | Son of Poseidon, guardian of the depths | Generic resource pool — connections, clients, SMTP |
| [**Pegasus**](https://github.com/herlondf/pegasus) | Born from Poseidon's blood, ridden by heroes | HTTP framework — routing, middleware, providers |
| **Hermes** *(Redis4D)* | Messenger of the gods, guide between realms | Redis client — fast key-value, pub/sub, messaging |

---

## License

MIT

---

> 🇧🇷 Leia este documento em português: [README_pt-br.md](./README_pt-br.md)
