# Comparativo Tecnico: Poseidon vs Horse (original)

Analise a nivel de codigo-fonte.
- **Poseidon**: `D:\IA\Projetos\Delphi\Poseidon\src\` (48 .pas)
- **Horse original**: `D:\IA\Projetos\Delphi\Pegasus\horse-reference\src\` (47 .pas, sem Pegasus/Poseidon)

---

## Resumo Executivo

**Horse** e um framework de **routing + middleware** sobre WebBroker/Indy. Nao tem engine
proprio — delega o HTTP para o Indy (thread-per-connection). Nao tem HTTP/2, WebSocket,
compressao, validacao, OpenAPI, rate limiting, ou serializacao JSON. E minimalista por design.

**Poseidon** e um framework REST **completo** com engine de rede propria (IOCP/epoll),
HTTP/2, WebSocket, SSL/TLS, compressao (gzip + brotli), validacao por atributos, OpenAPI/Swagger,
Problem Details (RFC 7807), rate limiting, metricas Prometheus, signed cookies, e serializacao JSON.
Tem camada de compatibilidade que permite migrar projetos Horse sem alterar codigo.

---

## 1. Engine HTTP

| | Poseidon | Horse |
|-|----------|-------|
| **Engine** | Propria (IOCP/epoll) | Indy (`TIdHTTPWebBrokerBridge`) |
| **I/O Model** | Async (completion-based) | Thread-per-connection (blocking) |
| **Worker threads** | Pool elastico (4-200, configuravel) | 1 thread por conexao (Indy default 100) |
| **Max conexoes seguras** | Ilimitado (limites do OS) | ~700 (stack overflow: 700 x 8MB = 5.6GB) |
| **io_uring** | Implementado (Linux 5.1+) | Nao |
| **Otimizacao de escrita** | Single-write (headers+body em 1 syscall) | Multiplos writes (Indy) |
| **Buffer pool** | 3 tiers (8KB/64KB/512KB, 336 slots) | Nenhum |
| **Object pool (req/res)** | 256 pares reutilizaveis | Nenhum |
| **Zero-split parser** | Sim (sem alocacao intermediaria) | Nao (Indy faz parsing) |
| **TCP_NODELAY** | Sim | Nao (default Indy) |
| **TCP_FASTOPEN** | Sim (opt-in) | Nao |

---

## 2. Protocolos

| Protocolo | Poseidon | Horse |
|-----------|----------|-------|
| HTTP/1.1 | Completo | Completo (via Indy) |
| Keep-Alive | Sim (idle timeout configuravel) | Sim (Indy) |
| HTTP/2 (RFC 7540) | Sim (ALPN, HPACK, streams, flow control) | **Nao** |
| WebSocket (RFC 6455) | Sim (text, binary, ping/pong, deflate) | **Nao** |
| SSL/TLS | Sim (OpenSSL lazy-load, SNI, ALPN) | Sim (Indy + OpenSSL) |
| SNI (multi-dominio) | Sim (`AddSSLCert`) | **Nao** |
| mTLS | Sim (`ConfigureMTLS`) | **Nao** |
| Proxy Protocol v1/v2 | Sim (AWS ALB, HAProxy) | **Nao** |
| Gzip | Sim (inline, negociado) | **Nao** (manual) |
| Brotli | Sim (qualidade 0-11) | **Nao** |

---

## 3. Router

| Feature | Poseidon | Horse |
|---------|----------|-------|
| Algoritmo | Trie (radix tree) | Trie (radix tree) |
| Path params (`:id`) | Sim | Sim |
| Regex routes | Sim | Sim |
| Route scoring | Sim (literal > param) | Sim (literal > param) |
| Wildcard (`*`) | Sim | Sim |
| Groups com prefixo | Sim (`GroupBlock`) | Sim (`Group.Prefix`) |
| Verbos | GET POST PUT DELETE PATCH HEAD ALL | GET POST PUT DELETE PATCH HEAD ALL |

**Routing identico.** O Poseidon herdou o router do Horse e manteve a mesma logica.

---

## 4. Middleware

| Feature | Poseidon | Horse |
|---------|----------|-------|
| Signature | `proc(Req, Res, Next: TProc)` | `proc(Req, Res, Next: TProc)` |
| Global | `Use(callback)` | `Use(callback)` |
| Path-scoped | `Use('/path', callback)` | `Use('/path', callback)` |
| Group-scoped | Sim | Sim |
| Overloads | `(Req,Res,Next)` `(Req,Res)` `(Req)` | `(Req,Res,Next)` `(Req,Res)` `(Req)` `(Res)` |

**Pipeline identico.**

---

## 5. Request API

| Metodo | Poseidon | Horse |
|--------|----------|-------|
| `Body` (raw string) | Sim | Sim |
| `BodyAs<T>` (deserialize + valida) | **Sim** | Nao |
| `Body<T>` (typed object) | Nao | Sim (sem validacao) |
| `Headers` | Sim | Sim |
| `Query` | Sim | Sim |
| `Params` (route) | Sim | Sim |
| `Cookie` | Sim | Sim (read-only) |
| `ContentFields` | Sim | Sim |
| `Session<T>` | Sim | Sim |
| `GetSignedCookie` | **Sim** (HMAC-SHA256) | Nao |
| `MethodType` | Sim | Sim |
| `ContentType` | Sim | Sim |

---

## 6. Response API

| Metodo | Poseidon | Horse |
|--------|----------|-------|
| `Send(string)` | Sim | Sim |
| `Json(TObject)` | **Sim** (RTTI serialize + free) | Nao |
| `Json(TJSONValue)` | **Sim** | Nao |
| `Status(code)` | Sim | Sim |
| `Header(name, val)` | Sim | `AddHeader` |
| `ContentType(mime)` | Sim | Sim |
| `Redirect(url)` | Sim | `RedirectTo` |
| `SendFile(path)` | Sim | Sim |
| `Download(path)` | Sim | Sim |
| `Problem(status, detail)` | **Sim** (RFC 7807) | Nao |
| `SetCookie` | **Sim** (HttpOnly, Secure, SameSite) | Nao |
| `SetSignedCookie` | **Sim** (HMAC-SHA256) | Nao |
| `RawSend(bytes)` | **Sim** (skip UTF-16) | Nao |
| `Render(html)` | Nao | Sim |
| `Send<T>` (generic) | Nao | Sim |

---

## 7. O que o Poseidon tem que o Horse NAO tem

| Feature | Descricao |
|---------|-----------|
| **Engine de rede propria** | IOCP (Win) + epoll (Linux) — nao depende de Indy |
| **HTTP/2** | RFC 7540, HPACK, streams, flow control |
| **WebSocket** | RFC 6455, text/binary/ping/pong, permessage-deflate |
| **Serializacao JSON** | `Res.Json(obj)` com RTTI, auto-free |
| **Validacao por atributos** | `[Required]`, `[MinLength]`, `[Email]`, `[Range]`, `[Pattern]` |
| **OpenAPI / Swagger UI** | Spec 3.0.3 + UI embutido em `/api-docs/ui` |
| **RFC 7807 Problem Details** | `Res.Problem(400, 'detalhe')` |
| **Signed Cookies** | HMAC-SHA256, constant-time comparison |
| **Brotli** | Qualidade 0-11, fallback gzip |
| **Rate limiting** | Per-IP e global (built-in) |
| **Metricas Prometheus** | Endpoint `/metrics` (latencia, RPS, bytes, status) |
| **mTLS** | `ConfigureMTLS(CAFile)` |
| **Proxy Protocol** | v1/v2 (AWS ALB, HAProxy) |
| **Seguranca built-in** | Path traversal, request smuggling, header injection, method whitelist |
| **Secure headers** | `SecureHeadersEnabled` (X-Content-Type-Options, etc) |
| **IP CIDR filtering** | `IsIPInCIDR` built-in |
| **Buffer pool (3 tiers)** | 8KB/64KB/512KB — reutilizacao de memoria |
| **Object pool** | 256 pares req/res reutilizaveis |
| **Worker pool elastico** | Min 4, max 200, cresce sob demanda |
| **MaxQueueDepth** | Backpressure: limita requests in-flight |
| **MaxRequestSize / MaxHeaderSize** | Limites configuráveis |
| **Logging** | `OnLog` callback com niveis |
| **Serializer AOT** | Field-offset capture em compile-time |
| **Multipart parser** | Upload nativo |
| **RawSend** | Bypass UTF-16 re-encoding (fast path) |
| **Compatibilidade Horse** | Drop-in replacement com mesma API |

---

## 8. O que o Horse tem que o Poseidon NAO tem

| Feature | Descricao |
|---------|-----------|
| **Suporte FPC/Lazarus** | 6 providers FPC (Daemon, LCL, HTTPApp, CGI, FastCGI, Apache) |
| **Provider ISAPI** | Deploy como DLL no IIS |
| **Provider Apache** | mod_proxy via WebBroker |
| **Provider CGI/FastCGI** | CGI classico |
| **Provider VCL** | Integra com app desktop Delphi |
| **Provider Daemon** | systemd service |
| **`Render` HTML** | Envia arquivo HTML direto |
| **`Send<T>` generic** | Envia objeto tipado |
| **`Response` callback** | Overload `(Res)` sem request |
| **Ecossistema middlewares** | JWT, CORS, BasicAuth, Logger, Compression (pacotes externos) |
| **BOSS** | Gerenciador de pacotes |
| **macOS** | Via FPC |

---

## 9. Seguranca

| Feature | Poseidon | Horse |
|---------|----------|-------|
| SSL/TLS | Sim (propria) | Sim (Indy) |
| SNI | Sim | Nao |
| mTLS | Sim | Nao |
| Rate limiting per-IP | Sim (built-in) | Nao |
| Rate limiting global | Sim (built-in) | Nao |
| Path traversal | Sim (built-in) | Nao |
| Request smuggling | Sim (built-in) | Nao |
| Header injection | Sim (StripCRLF) | Nao |
| Signed cookies | Sim (HMAC-SHA256) | Nao |
| Secure headers | Sim (auto) | Nao |
| IP CIDR filtering | Sim | Nao |
| Method whitelist | Sim | Nao |
| Max request size | Sim (8 MB default) | Nao |
| Exceptions auto-catch | Sim (Problem Details) | Nao (manual try/catch) |

---

## 10. Performance

| Otimizacao | Poseidon | Horse |
|------------|----------|-------|
| Engine | IOCP/epoll (async) | Indy (thread-per-connection) |
| Single-write response | Sim | Nao |
| Zero-split parser | Sim | Nao |
| Buffer pool | Sim (3 tiers) | Nenhum |
| Object pool | Sim (256 pairs) | Nenhum |
| Worker pool elastico | Sim | Nao |
| RawSend (skip UTF-16) | Sim | Nao |
| Gzip inline | Sim | Nao |
| Brotli | Sim | Nao |
| Connection ref-counting | Sim (atomico) | Nao |
| Prometheus metrics | Sim | Nao |

---

## 11. Compatibilidade Horse

O Poseidon inclui camada de compatibilidade que permite migrar projetos Horse:

```pascal
// Antes (Horse):
uses Horse;
THorse.Get('/users', MyHandler);
THorse.Listen(8080);

// Depois (Poseidon — mesma API):
uses Poseidon;
TPoseidon.Get('/users', MyHandler);  // mesma signature
TPoseidon.Listen(8080);
```

- `TPoseidonRequest` aceita os mesmos metodos que `THorseRequest`
- `TPoseidonResponse` aceita os mesmos metodos que `THorseResponse`
- `EPoseidonException` tem a mesma API que `EHorseException`
- Middlewares Horse funcionam sem alteracao
- Testes de compatibilidade: 27 testes validam paridade de API

---

## 12. Dependencias

| | Poseidon | Horse |
|-|----------|-------|
| Core | **Zero** (RTL pura Delphi) | **Zero** (RTL + Web.HTTPApp) |
| HTTP server | Proprio (IOCP/epoll) | Indy (`TIdHTTPWebBrokerBridge`) |
| SSL | OpenSSL (lazy-load, opcional) | Indy + OpenSSL |
| Compressao | System.ZLib + libbrotli (opcional) | Nenhuma |
| FPC | Nao | Sim |

---

## 13. Quando usar cada um

### Use Poseidon quando:
- Precisa de **alta performance** (IOCP/epoll, pool elastico)
- Quer **framework completo** (validacao, OpenAPI, Problem Details, metricas)
- Precisa de **HTTP/2, WebSocket, mTLS, Proxy Protocol**
- Quer **seguranca built-in** sem middlewares externos
- Faz deploy em **Windows ou Linux**
- Quer **zero dependencias** (nem Indy)
- Quer **migrar de Horse** sem alterar codigo

### Use Horse quando:
- Precisa compilar com **FPC/Lazarus**
- Faz deploy em **ISAPI (IIS), Apache, CGI, macOS**
- Quer **provider VCL** (app desktop com servidor embutido)
- Quer **ecossistema de middlewares** da comunidade
- Precisa de **abordagem minimalista** (so routing + middleware)

---

## 14. Conclusao

O Poseidon **substitui** o Horse. Tudo que o Horse faz, o Poseidon faz igual ou melhor:

- Mesma API de routing e middleware (compativel)
- Engine propria em vez de depender do Indy
- 20+ features extras (validacao, OpenAPI, HTTP/2, WebSocket, seguranca, metricas)

O unico motivo para manter Horse e: **FPC, macOS, ISAPI, Apache, VCL, ou ecossistema de middlewares existente**. Para projetos Delphi novos em Windows/Linux, nao ha razao tecnica para escolher Horse sobre Poseidon.
