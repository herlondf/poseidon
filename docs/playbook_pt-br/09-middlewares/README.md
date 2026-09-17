# 09 — Middlewares

O Poseidon fornece 20 middlewares integrados. Todos retornam
`TNativeMiddlewareFunc`:

```pascal
TNativeMiddlewareFunc =
  reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

Registre globalmente com `App.Use(...)` ou por rota, passando o middleware
antes do handler final. Middlewares executam na ordem de registro.

---

## 1. CORS

Trata `Origin`, `Access-Control-Request-Method` e preflight `OPTIONS`.
Retorna os headers configurados em toda resposta.

```pascal
uses Poseidon.Middleware.CORS;

App.Use(CORSMiddleware);

// Com opcoes
var LOpts: TCORSOptions;
LOpts := DefaultCORSOptions;
LOpts.AllowOrigin   := 'https://example.com';
LOpts.AllowMethods  := 'GET, POST, PUT, DELETE';
LOpts.AllowHeaders  := 'Authorization, Content-Type';
LOpts.MaxAge        := 86400;
App.Use(CORSMiddleware(LOpts));
```

`TCORSOptions` é um record simples (`AllowOrigin`, `AllowMethods`,
`AllowHeaders`, `ExposeHeaders`, `AllowCredentials`, `MaxAge`).
`DefaultCORSOptions` retorna os valores padrão para partir deles.

---

## 2. JWT

Valida um token Bearer (HMAC-SHA256 / HS256) no header `Authorization`.
Lança `EPoseidonException(401)` se o token estiver ausente, inválido ou
expirado.

```pascal
uses Poseidon.Middleware.JWT;

App.Use(JWTMiddleware('meu-segredo'));

// Por rota, com checagem de issuer/audience e exp obrigatorio
App.Get('/profile',
  JWTMiddleware('meu-segredo', 'Unauthorized', 'meu-issuer', 'minha-audience', True),
  HandleProfile);
```

`JWTSign(APayload, ASegredo)` emite um token (util para testes). Suporta
apenas segredos HMAC simétricos — sem verificação por chave pública RSA/EC.

---

## 3. Logger

Escreve uma linha por requisição em stdout (ou destino customizado): método,
caminho, status e tempo decorrido.

```pascal
uses Poseidon.Middleware.Logger;

App.Use(LoggerMiddleware);

// Destino customizado (ex: arquivo)
App.Use(LoggerMiddleware(LogToFile('access.log')));

// Linhas em JSON em vez de texto plano
App.Use(LoggerMiddlewareJSON);
```

`TLogOutput = reference to procedure(const ALine: string)` — passe qualquer
callback que escreva a linha formatada em outro destino além do stdout.

---

## 4. RateLimit

Rate limiter em memória, por IP, de **janela fixa** (fixed window). Thread-safe.
Retorna `429 Too Many Requests` com header `Retry-After` quando o limite da
janela é excedido.

```pascal
uses Poseidon.Middleware.RateLimit;

// max 100 requisicoes por janela de 60 segundos, por IP
App.Use(RateLimitMiddleware(100, 60));
```

Parâmetros opcionais adicionais: mensagem customizada, `ATrustProxy` +
`ATrustedProxies` (para usar `X-Forwarded-For` apenas quando vindo de proxies
confiáveis), e `AMaxTrackedKeys` (limita memória sob ataque de IPs com alta
cardinalidade). O contador é somente in-process — não há backend externo
plugável (ex: Redis).

---

## 5. Compression

Comprime respostas com gzip ou deflate conforme o header `Accept-Encoding`
do cliente. Pula respostas abaixo de um tamanho mínimo configurável
(padrão 860 bytes).

```pascal
uses Poseidon.Middleware.Compression;

App.Use(CompressionMiddleware);

// Com limite mínimo de tamanho (bytes)
App.Use(CompressionMiddleware(1024));
```

---

## 6. Timeout

Troca a resposta por `503 Service Unavailable` se a cadeia de handlers demorou
mais que o prazo configurado para completar.

```pascal
uses Poseidon.Middleware.Timeout;

// timeout de 5000 ms
App.Use(TimeoutMiddleware(5000));
```

O timeout se aplica somente à cadeia de handlers, não à fase de leitura de
rede.

> **Isso é uma checagem pós-execução, não um abort preemptivo.** O `ANext()`
> continua bloqueando até o handler realmente retornar; o middleware só mede
> quanto tempo isso levou e troca a resposta depois. **Um handler que nunca
> retorna (uma chamada de saída travada, um loop infinito) não é interrompido
> por este middleware** — ele continua rodando, segurando seu worker,
> independente do prazo configurado. Para esse caso use o
> [watchdog `MaxHandlerRunMs` no nível do servidor](../04-operacao-e-runtime/limits-and-backpressure.md#watchdog-de-handler-travado-233)
> em vez disso, que detecta o handler travado independente de qualquer
> middleware e fecha a conexão (veja #233).

---

## 7. BodyLimit

Retorna `413 Content Too Large` antes de ler o corpo quando o header
`Content-Length` excede o máximo configurado. Também aplica o limite durante
leituras em streaming.

```pascal
uses Poseidon.Middleware.BodyLimit;

// maximo de 2 MB
App.Use(BodyLimitMiddleware(2 * 1024 * 1024));
```

---

## 8. RequestID

Gera um identificador único por requisição (UUID v4) e anexa em
`X-Request-Id` tanto no request quanto na resposta. Propaga um ID já enviado
pelo cliente, quando presente.

```pascal
uses Poseidon.Middleware.RequestID;

App.Use(RequestIDMiddleware);
```

Recuperar num handler: `ACtx.Header('X-Request-Id')`

---

## 9. CircuitBreaker

Circuit breaker de janela deslizante com três estados: `Closed → Open →
HalfOpen → Closed`. Abre quando a taxa de erro na janela ultrapassa um
percentual configurado, retornando `503` enquanto aberto; testa uma
requisição em half-open antes de fechar de novo.

```pascal
uses Poseidon.Middleware.CircuitBreaker;

App.Use(CircuitBreakerMiddleware);

// Abre quando >= 50% das requisicoes falham numa janela de 60s; fica aberto 30s
App.Use(CircuitBreakerMiddleware(50, 60, 30));
```

Parâmetros: `AErrorThresholdPct` (padrão 50), `AWindowSec` (padrão 60),
`AOpenDurationSec` (padrão 30).

---

## 10. Metrics

Expõe um endpoint `/metrics` compatível com Prometheus, com contagem de
requisições por caminho, contagem de erros e histograma de latência.

```pascal
uses Poseidon.Middleware.Metrics;

App.Use(MetricsMiddleware('/metrics'));
```

Métricas são rotuladas apenas por `path` (sem labels `method`/`status` — erros
são um contador separado, `poseidon_errors_total`). Limites do histograma
(ms): 5, 10, 25, 50, 100, 250, 500, 1000, +Inf. A cardinalidade de caminhos é
limitada (padrão 10000 caminhos únicos) para não estourar memória sob ataque
de caminhos hostis.

A mesma resposta também traz gauges no nível do processo, sem label `path` —
`poseidon_rss_kb`, `poseidon_malloc_inuse_kb`/`_arena_kb`/`_mmap_kb`,
`poseidon_delphi_heap_kb`, `poseidon_fd_count`, `poseidon_private_dirty_kb` —
vindos de `TPoseidonDiagnostics` (veja
[metrics.md](../04-operacao-e-runtime/metrics.md#gauges-no-nivel-do-processo)
pro significado de cada um e como lê-los em conjunto).

---

## 11. Static

Serve arquivos de uma árvore de diretório local sob um prefixo de URL. Trata
`If-None-Match` / `ETag` (retorna `304 Not Modified`), detecção de MIME e
compressão gzip opcional.

```pascal
uses Poseidon.Middleware.Static;

App.Use(StaticMiddleware('/assets', '/var/www/assets'));

// Desabilitar gzip
App.Use(StaticMiddleware('/assets', '/var/www/assets', False));
```

Sem suporte a byte-range (`Range`/`206 Partial Content`) e sem listagem de
diretório.

---

## 12. HealthCheck

Endpoints de saúde (`/health`, `/health/live`, `/health/ready`) construídos
por um pequeno builder fluente — não é uma função de middleware simples.
Suporta probes de liveness/readiness customizados, registrados por nome.

```pascal
uses Poseidon.Middleware.HealthCheck;

var LHealth: TPoseidonHealthCheck;
LHealth := TPoseidonHealthCheck.Create;
LHealth
  .BasePath('/health')
  .AddCheck('postgres', function: THealthCheckResult
    begin
      if FDBConnection.Ping then
        Result := THealthCheckResult.OK
      else
        Result := THealthCheckResult.Failed('db inacessivel');
    end);
App.Use(LHealth.Build);
```

`Build` consome e libera o builder — chame uma única vez, depois de
registrar todos os checks.

---

## 13. Security

Define headers de segurança comuns: `Strict-Transport-Security` (HSTS,
somente sobre TLS), `Content-Security-Policy`, `X-Frame-Options`,
`X-Content-Type-Options`, `Referrer-Policy` e `Permissions-Policy`.

```pascal
uses Poseidon.Middleware.Security;

App.Use(SecurityMiddleware);
```

Headers individuais podem ser sobrescritos via `TSecurityOptions`.

---

## 14. Proxy

Encaminha requisições para um único servidor upstream e faz streaming da
resposta de volta ao cliente.

```pascal
uses Poseidon.Middleware.Proxy;

// Encaminha tudo como está
App.Use(ProxyMiddleware('http://backend:8080'));

// Encaminha removendo um prefixo de path antes de repassar ao upstream
App.Use(ProxyMiddlewareWithPrefix('http://backend:8080', '/api'));
```

Apenas um upstream por vez — não há balanceamento de carga multi-upstream
embutido.

---

## 15. Digest

Autenticação HTTP Digest (MD5, `qop=auth`). Desafia requisições não
autenticadas com header `WWW-Authenticate: Digest` e valida credenciais via
um callback de HA1 fornecido pelo chamador.

```pascal
uses Poseidon.Middleware.Digest;

App.Use(DigestMiddleware('Area Protegida',
  function(const AUser, ARealm: string): string
  begin
    // Retorna HA1 = MD5(usuario:realm:senha), ou '' para rejeitar
    Result := DigestHA1(AUser, ARealm, FUserStore.GetPassword(AUser));
  end));
```

---

## 16. Guard

Hardening de requisição: whitelist de métodos HTTP, rejeição de path
traversal e defesas contra request smuggling (`Content-Length`/
`Transfer-Encoding` conflitantes). Não é uma lista de allow/deny de IP — veja
`Poseidon.Net.Security` para checagens baseadas em CIDR usadas em outros
pontos (ex: Proxy Protocol).

```pascal
uses Poseidon.Middleware.Guard;

// Apenas checagens de smuggling/traversal, qualquer metodo permitido
App.Use(GuardMiddleware);

// Tambem restringe a uma lista de metodos permitidos (405 caso contrario)
App.Use(GuardMiddleware(['GET', 'POST']));
```

---

## 17. Validation

Captura `EPoseidonValidation` (lançada pelo validador baseado em atributos de
`Poseidon.Validation`) e converte numa resposta `application/problem+json`
`422`. Não recebe parâmetros — as regras de validação em si são declaradas
como atributos numa classe DTO, não passadas inline na chamada do middleware.

```pascal
uses Poseidon.Middleware.Validation, Poseidon.Validation;

App.Use(ValidationMiddleware);

type
  TCreateUserDTO = class
  public
    [Required]
    Name: string;
    [Email]
    Email: string;
    [MinLength(8)]
    Password: string;
  end;

// no handler, apos popular LDto a partir do corpo da requisicao:
TPoseidonValidator.ValidateOrRaise(LDto); // lanca EPoseidonValidation se invalido
```

Outros atributos disponíveis: `[MaxLength(N)]`, `[Range(AMin, AMax)]`,
`[Pattern(ARegex)]`.

---

## 18. ProblemDetails

Converte exceções não tratadas e respostas de erro em payloads
`application/problem+json` conforme RFC 7807. Garante que todas as respostas
de erro tenham uma estrutura consistente.

```pascal
uses Poseidon.Middleware.ProblemDetails;

// registrar primeiro para envolver toda a cadeia
App.Use(ProblemDetailsMiddleware);
```

Exemplo de saída:

```json
{
  "type": "https://tools.ietf.org/html/rfc7231#section-6.5.4",
  "title": "Not Found",
  "status": 404,
  "detail": "Route /users/99 not found",
  "instance": "/users/99"
}
```

---

## 19. OpenAPI

Gera uma especificação OpenAPI 3.x a partir de metadados de rota registrados
manualmente e serve junto com um Swagger UI — um builder fluente, não uma
função de middleware simples.

```pascal
uses Poseidon.Middleware.OpenAPI;

var LOpenAPI: TPoseidonOpenAPI;
LOpenAPI := TPoseidonOpenAPI.Create;
LOpenAPI
  .Title('Minha API')
  .Version('1.0.0')
  .AddRoute('GET', '/ping', 'Health check')
  .AddRoute('POST', '/users', 'Criar usuario');
App.Use(LOpenAPI.Build);
```

Padrões: spec em `/api-docs`, Swagger UI em `/api-docs/ui` (sobrescreva o
caminho da spec com `.SpecPath(...)`). Não há mecanismo de metadados de rota
via atributos — o resumo/tags de cada rota são fornecidos via
`.AddRoute(...)`.

---

## 20. Cache

Cache de resposta HTTP com eviction LRU e geração automática de `ETag`
(`If-None-Match` → `304 Not Modified`). Respostas em cache são servidas sem
executar o handler.

```pascal
uses Poseidon.Middleware.Cache;

// TTL de 60s, 50 MB de tamanho maximo
App.Use(CacheMiddleware(60, 1024 * 1024 * 50));

// Restrito a rotas especificas
App.Get('/products', CacheMiddleware(300, 1024 * 1024 * 10), HandleListProducts);
```

Somente respostas `GET`/`HEAD` com status `200` são cacheadas. A chave de
cache inclui o caminho completo e a query string. Respostas servidas do
cache carregam `Vary: Accept-Encoding`.

---

## 21. Tracing

Propaga [W3C Trace Context](https://www.w3.org/TR/trace-context/): lê um
header `traceparent` de entrada se presente e bem formado (reaproveitando
seu trace-id e a flag de sampled), ou origina um trace novo se ausente/mal
formado. De qualquer jeito, gera um novo span-id pra este hop e escreve o
`traceparent` resultante como header de resposta.

```pascal
uses Poseidon.Middleware.Tracing;

App.Use(TracingMiddleware);
```

Registre antes do `LoggerMiddlewareJSON` (veja a nota em [Metrics](#10-metrics)
acima) se quiser `trace_id`/`span_id` na linha de log JSON — o
`LoggerMiddlewareJSON` lê o `traceparent` que este middleware já setou, o
mesmo mecanismo `ACtx.ExtraHeaders` que o `RequestIDMiddleware` usa pro
`X-Request-ID`.

Diferente do `RequestIDMiddleware`: `X-Request-ID` é um id de correlação
opaco simples que um cliente pode setar; `traceparent` é o formato
padronizado e estruturado (trace-id + span-id por hop) pra propagação
entre serviços. Use os dois se quiser cada um separadamente, ou só o
Tracing se a propagação W3C já basta sozinha.

**Escopo:** só propagação e exposição — isso NÃO exporta spans pro
Tempo/Grafana nem pra nenhum backend OTLP (um exportador de verdade é um
trabalho maior e separado: um client OTLP, timing de início/fim de span,
batching). O que isso entrega é um trace-id/span-id corretamente gerado e
propagado, pronto pra quem conectar um exportador de verdade consumir a
partir do header de resposta `traceparent` ou da linha de log JSON.

---

## Veja também

- [08 — API Nativa](../08-api-nativa/README.md) — App.Use, grupos de rotas, cadeia de middleware
- [05 — Receitas](../05-receitas/README.md) — Padrões executáveis combinando múltiplos middlewares
