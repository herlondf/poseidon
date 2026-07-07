# 09 — Middlewares

O Poseidon fornece 20 middlewares integrados prontos para uso. Todos retornam
`TNativeMiddlewareFunc` e são registrados via `App.Use(...)` (global) ou
`Group.Use(...)` (escopo de grupo).

---

## 1. CORS

Adiciona headers `Access-Control-*` e trata requisições `OPTIONS` (preflight).

```pascal
uses Poseidon.Middleware.CORS;

LApp.Use(CORSMiddleware);
// ou com configuracao
LApp.Use(CORSMiddleware([
  'https://meusite.com',
  'https://admin.meusite.com'
]));
```

---

## 2. JWT

Valida o token Bearer no header `Authorization`. Interrompe a cadeia com 401
se o token for inválido ou ausente.

```pascal
uses Poseidon.Middleware.JWT;

LApp.Use(JWTMiddleware('meu-segredo-hmac-256'));
```

Claims decodificados ficam disponíveis em `ACtx.Extras['jwt_claims']`.

---

## 3. Logger

Registra método, caminho, status e tempo de resposta em stdout ou destino
configurável.

```pascal
uses Poseidon.Middleware.Logger;

LApp.Use(LoggerMiddleware);
```

---

## 4. RateLimit

Limita o número de requisições por IP dentro de uma janela deslizante.
Responde 429 quando o limite é excedido.

```pascal
uses Poseidon.Middleware.RateLimit;

// 100 requisicoes por janela de 60 segundos
LApp.Use(RateLimitMiddleware(100, 60));
```

---

## 5. Compression

Comprime a resposta com gzip ou deflate conforme o header `Accept-Encoding`
do cliente. Respostas abaixo de 1 KB não são comprimidas.

```pascal
uses Poseidon.Middleware.Compression;

LApp.Use(CompressionMiddleware);
```

---

## 6. Timeout

Cancela a requisição e responde 503 se o handler não completar dentro do
prazo configurado.

```pascal
uses Poseidon.Middleware.Timeout;

// timeout de 5000 ms
LApp.Use(TimeoutMiddleware(5000));
```

---

## 7. BodyLimit

Rejeita requisições cujo corpo exceda o tamanho máximo permitido com 413.

```pascal
uses Poseidon.Middleware.BodyLimit;

// limite de 2 MB
LApp.Use(BodyLimitMiddleware(2 * 1024 * 1024));
```

---

## 8. RequestID

Gera ou propaga um identificador único por requisição no header
`X-Request-ID`. Útil para correlação de logs distribuídos.

```pascal
uses Poseidon.Middleware.RequestID;

LApp.Use(RequestIDMiddleware);
// ACtx.Extras['request_id'] fica disponivel nos handlers seguintes
```

---

## 9. CircuitBreaker

Abre o circuito (503) após N falhas consecutivas e tenta fechar após um
período de reset, protegendo dependências downstream.

```pascal
uses Poseidon.Middleware.CircuitBreaker;

// abre apos 5 falhas, tenta resetar em 30 segundos
LApp.Use(CircuitBreakerMiddleware(5, 30));
```

---

## 10. Metrics

Expõe métricas no formato Prometheus em um endpoint dedicado.
Coleta: contagem de requisições, latência (histograma), conexões ativas.

```pascal
uses Poseidon.Middleware.Metrics;

LApp.Use(MetricsMiddleware('/metrics'));
```

---

## 11. Static

Serve arquivos estáticos de um diretório local. Suporta ETag, `Last-Modified`
e resposta 304.

```pascal
uses Poseidon.Middleware.Static;

LApp.Use(StaticMiddleware('/assets', '/var/www/meuapp/public'));
```

---

## 12. HealthCheck

Expõe um endpoint de saúde que retorna 200 com payload JSON enquanto o
servidor está saudável.

```pascal
uses Poseidon.Middleware.HealthCheck;

LApp.Use(HealthCheckMiddleware('/health'));
// GET /health -> 200 {"status":"ok","uptime":...}
```

---

## 13. Security

Adiciona headers de segurança: `X-Content-Type-Options`, `X-Frame-Options`,
`Strict-Transport-Security`, `Content-Security-Policy` e
`Referrer-Policy`.

```pascal
uses Poseidon.Middleware.Security;

LApp.Use(SecurityMiddleware);
```

---

## 14. Proxy

Encaminha requisições com determinado prefixo de path para um upstream HTTP,
atuando como reverse proxy leve.

```pascal
uses Poseidon.Middleware.Proxy;

LApp.Use(ProxyMiddleware('/api/legado', 'http://legado.interno:8080'));
```

---

## 15. Digest

Implementa autenticação HTTP Digest (RFC 7616). O callback recebe o nome de
usuário e deve retornar a senha (ou hash HA1) correspondente.

```pascal
uses Poseidon.Middleware.Digest;

LApp.Use(DigestMiddleware('area-restrita',
  function(const AUser: string): string
  begin
    if AUser = 'admin' then
      Result := 'senha-secreta'
    else
      Result := '';
  end));
```

---

## 16. Guard

Controla acesso por IP com whitelist e/ou blacklist. Responde 403 para IPs
bloqueados ou não listados (quando whitelist está ativa).

```pascal
uses Poseidon.Middleware.Guard;

var
  LGuard: TGuardOptions;
begin
  LGuard.Whitelist := ['192.168.1.0/24', '10.0.0.5'];
  LGuard.Blacklist := ['203.0.113.42'];
  LApp.Use(GuardMiddleware(LGuard));
end;
```

---

## 17. Validation

Valida o body da requisição contra um DTO anotado. Responde 422 com lista
de erros de validação quando a validação falha.

```pascal
uses Poseidon.Middleware.Validation;

LApp.Post('/usuarios',
  [ValidationMiddleware(TPedidoCriarUsuario),
   HCriarUsuario]);
```

---

## 18. ProblemDetails

Captura exceções não tratadas na cadeia e formata a resposta no padrão
RFC 7807 (`application/problem+json`).

```pascal
uses Poseidon.Middleware.ProblemDetails;

// registrar antes dos demais middlewares
LApp.Use(ProblemDetailsMiddleware);
```

Exemplo de resposta gerada:

```json
{
  "type": "https://exemplo.com/erros/nao-encontrado",
  "title": "Recurso não encontrado",
  "status": 404,
  "detail": "Usuario 42 nao existe.",
  "instance": "/api/v1/usuarios/42"
}
```

---

## 19. OpenAPI

Gera a especificação OpenAPI 3.1 a partir das rotas registradas e serve o
Swagger UI em um endpoint configurável.

```pascal
uses Poseidon.Middleware.OpenAPI;

LApp.Use(OpenAPIMiddleware('/docs', procedure(ASpec: TOpenAPISpec)
begin
  ASpec.Title   := 'Minha API';
  ASpec.Version := '1.0.0';
end));
// GET /docs      -> Swagger UI
// GET /docs/spec -> openapi.json
```

---

## 20. Cache

Cache de resposta em memória com política LRU, suporte a ETag e respostas
304. A chave de cache é `Method + Path + QueryString`.

```pascal
uses Poseidon.Middleware.Cache;

// cache de ate 500 entradas, TTL de 60 segundos
LApp.Use(CacheMiddleware(500, 60));
```

Respostas com status diferente de 200 ou header `Cache-Control: no-store`
não são armazenadas.

---

## Resumo

| # | Nome | Funcao | Factory |
|---|------|--------|---------|
| 1 | CORS | Headers de CORS e preflight | `CORSMiddleware` |
| 2 | JWT | Autenticacao Bearer JWT | `JWTMiddleware(segredo)` |
| 3 | Logger | Log de acesso | `LoggerMiddleware` |
| 4 | RateLimit | Limite de requisicoes por IP | `RateLimitMiddleware(max, segs)` |
| 5 | Compression | gzip/deflate automatico | `CompressionMiddleware` |
| 6 | Timeout | Cancelamento por tempo | `TimeoutMiddleware(ms)` |
| 7 | BodyLimit | Rejeita bodies grandes | `BodyLimitMiddleware(bytes)` |
| 8 | RequestID | ID unico por requisicao | `RequestIDMiddleware` |
| 9 | CircuitBreaker | Protecao de downstream | `CircuitBreakerMiddleware(n, segs)` |
| 10 | Metrics | Endpoint Prometheus | `MetricsMiddleware(path)` |
| 11 | Static | Arquivos estaticos | `StaticMiddleware(prefixo, dir)` |
| 12 | HealthCheck | Endpoint de saude | `HealthCheckMiddleware(path)` |
| 13 | Security | Headers de seguranca | `SecurityMiddleware` |
| 14 | Proxy | Reverse proxy leve | `ProxyMiddleware(prefixo, upstream)` |
| 15 | Digest | Autenticacao HTTP Digest | `DigestMiddleware(realm, cb)` |
| 16 | Guard | Whitelist/blacklist de IP | `GuardMiddleware(opcoes)` |
| 17 | Validation | Validacao de DTO | `ValidationMiddleware(tipo)` |
| 18 | ProblemDetails | Erros RFC 7807 | `ProblemDetailsMiddleware` |
| 19 | OpenAPI | Spec + Swagger UI | `OpenAPIMiddleware(path, cb)` |
| 20 | Cache | Cache LRU + ETag | `CacheMiddleware(max, ttl)` |

---

## Veja tambem

- [08 — API Nativa](../08-api-nativa/README.md)
- [05 — Receitas](../05-receitas/README.md)
