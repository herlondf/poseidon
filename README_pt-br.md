# Poseidon

> *Deus dos mares — poder bruto, velocidade incomparável.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  Framework REST de alta performance para Delphi — IOCP no Windows, io_uring/epoll no Linux.<br/>
  29k RPS com router e middleware. Zero erros com 200 usuários simultâneos. Substituto drop-in do Horse.
</p>

---

## Início Rápido

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

## Por que Poseidon

| | Poseidon | Horse + Indy |
|---|---|---|
| **Throughput** (200 VUs, 2min) | 28.885 RPS | 2.091 RPS |
| **Latência p95** | 22ms | 156ms |
| **Erros** | 0% | 5-80% |
| **HTTP/2** | Integrado | Não |
| **WebSocket** | Integrado | Não |
| **SSL/TLS** | OpenSSL nativo (SNI, mTLS, ALPN) | Via Indy |
| **Middlewares** | 15 integrados | Comunidade |
| **Validação** | `[Required]`, `[Email]`, `[Range]` | Manual |
| **OpenAPI** | Swagger UI integrado | Comunidade |

## Funcionalidades

### Framework
| Funcionalidade | Status |
|----------------|--------|
| Router radix-tree com suporte a `:param` | ✅ |
| Pipeline de middleware (Use, Group, GroupBlock) | ✅ |
| Request: Body, Query, Params, Headers, Cookie, Session | ✅ |
| Response: Send, Json, Status, Header, Redirect, SendFile | ✅ |
| Binding de DTO com atributos de validação | ✅ |
| OpenAPI 3.x + Swagger UI | ✅ |
| RFC 7807 Problem Details | ✅ |
| Cookies assinados (HMAC-SHA256) | ✅ |
| Compatibilidade com API Horse (shim opt-in) | ✅ |

### Engine
| Funcionalidade | Status |
|----------------|--------|
| HTTP/1.1 keep-alive | ✅ |
| HTTPS (OpenSSL), SNI, mTLS | ✅ |
| HTTP/2 (ALPN h2, h2c, server push, flow control) | ✅ |
| WebSocket (RFC 6455, permessage-deflate) | ✅ |
| Compressão gzip + Brotli | ✅ |
| Rate limiting (por IP e global) | ✅ |
| Métricas Prometheus | ✅ |
| Proxy Protocol v1/v2 | ✅ |
| Headers de segurança, proteção path traversal e smuggling | ✅ |
| Windows 64-bit (IOCP) | ✅ |
| Linux 64-bit (io_uring ≥ 5.6, fallback epoll) | ✅ |

### 15 Middlewares Integrados

CORS, JWT, Logger, RateLimit, Compression, Timeout, BodyLimit, RequestID, CircuitBreaker, Metrics, Static, HealthCheck, Security, Proxy, Digest

## Requisitos

- Delphi 11 Alexandria ou superior
- Windows 64-bit ou Linux 64-bit
- OpenSSL no PATH (apenas para HTTPS/HTTP2)

## Instalação

Adicione `src/`, `src/providers/` e `middlewares/` ao search path do projeto:

```
<poseidon>\src
<poseidon>\src\providers
<poseidon>\middlewares
```

## Exemplos

### Middleware

```pascal
uses Poseidon, Poseidon.Middleware.CORS, Poseidon.Middleware.JWT;

TPoseidon.Use(TPoseidonMiddlewareCORS.New);
TPoseidon.Use('/api', TPoseidonMiddlewareJWT.New('meu-secret'));

TPoseidon.Get('/api/data',
  procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
  begin
    Res.Json(TJSONObject.Create.AddPair('user', Req.Session<TMinhaSessao>.Nome));
  end);

TPoseidon.Listen(9000);
```

### Validação de DTO

```pascal
type
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
    DTO := Req.BodyAs<TCreateUserDTO>;  // valida automaticamente, 422 se falhar
    try
      Res.Status(201).Json(DTO, False);
    finally
      DTO.Free;
    end;
  end);
```

### Migração do Horse

Para migração gradual, crie um shim `Horse.pas` no seu projeto:

```pascal
unit Horse;
interface
uses Poseidon;
type
  THorse = TPoseidon;
  THorseRequest = TPoseidonRequest;
  THorseResponse = TPoseidonResponse;
  // ... demais aliases
implementation
end.
```

Código Horse existente compila sem alterações. Remova o shim após a migração.

## Documentação

- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Português)](docs/playbook_pt-br/README.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## A Família Olímpica

| Projeto | Função |
|---------|--------|
| **Poseidon** (este) | Framework REST + engine HTTP assíncrono |
| [**Triton**](https://github.com/herlondf/triton) | Pool genérico de recursos (conexões, clientes) |
| **Hermes** *(Redis4D)* | Cliente Redis (key-value, pub/sub) |

---

## Licença

MIT

---

> 🇺🇸 Read this document in English: [README.md](./README.md)
