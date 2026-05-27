# AsyncIO

<p align="center">
  <img src="docs/logo.png" alt="AsyncIO" width="180"/>
</p>

<p align="center">
  High-performance async HTTP server for Delphi — IOCP on Windows, epoll on Linux.<br/>
  Zero external dependencies. Single WSASend per response. WebSocket, SSL/TLS and HTTP/2 built-in.
</p>

---

## Overview

AsyncIO is a standalone Delphi library that provides a native async I/O HTTP server.
It is used as the transport layer for [Pegasus](https://github.com/herlondf/pegasus) and
[Horse](https://github.com/HashLoad/horse) when the `HORSE_ASYNCIO` define is active.

| Feature | Status |
|---------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL) | ✅ |
| SNI multi-cert | ✅ |
| WebSocket | ✅ |
| HTTP/2 (h2 via ALPN) | ✅ |
| gzip compression | ✅ |
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
<path-to-asyncio>\src\
```

## Quick Start

```pascal
uses AsyncIO.Net.HttpServer;

var
  LServer: TAsyncIONativeServer;
begin
  LServer := TAsyncIONativeServer.Create;
  LServer.Listen('0.0.0.0', 9000,
    procedure(const AReq: TAsyncIONativeRequest;
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

## Documentation

- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Português)](docs/playbook_pt-br/README.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## Source layout

```
src/                                   ← AsyncIO core (zero external dependencies)
  AsyncIO.Net.HttpServer.pas           ← core server — epoll/IOCP syscalls
  AsyncIO.Net.Pool.Buffer.pas          ← lock-free buffer pool
  AsyncIO.Net.Pool.Native.pas          ← per-request context pool
  AsyncIO.Net.WebAdapters.Native.pas   ← WebBroker adapter bridge
  AsyncIO.Net.WebSocket.pas            ← WebSocket frame handling
  AsyncIO.Net.SSL.pas                  ← OpenSSL bindings + SNI
  AsyncIO.Net.HTTP2.pas                ← HTTP/2 (h2 via ALPN)

providers/                             ← framework integrations (optional)
  horse/
    Horse.Provider.AsyncIO.pas         ← Horse provider (requires Horse ≥ 3.1.9)
```

## License

MIT

---

> 🇧🇷 Leia este documento em português: [README_pt-br.md](./README_pt-br.md)
