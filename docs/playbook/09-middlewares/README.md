# 09 — Middlewares

Poseidon ships 20 built-in middlewares. All of them return `TNativeMiddlewareFunc`:

```pascal
TNativeMiddlewareFunc =
  reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

Register globally with `App.Use(...)` or per-route by passing the middleware
before the final handler. Middleware executes in registration order.

---

## 1. CORS

Handles `Origin`, `Access-Control-Request-Method`, and preflight `OPTIONS`
requests. Returns configured headers on every response.

```pascal
uses Poseidon.Middleware.CORS;

App.Use(CORSMiddleware);

// With options
var LOpts: TCORSOptions;
LOpts := DefaultCORSOptions;
LOpts.AllowOrigin   := 'https://example.com';
LOpts.AllowMethods  := 'GET, POST, PUT, DELETE';
LOpts.AllowHeaders  := 'Authorization, Content-Type';
LOpts.MaxAge        := 86400;
App.Use(CORSMiddleware(LOpts));
```

`TCORSOptions` is a plain record (`AllowOrigin`, `AllowMethods`, `AllowHeaders`,
`ExposeHeaders`, `AllowCredentials`, `MaxAge`). `DefaultCORSOptions` returns the
built-in defaults to start from.

---

## 2. JWT

Validates a Bearer token (HMAC-SHA256 / HS256) in the `Authorization` header.
Raises `EPoseidonException(401)` on missing, invalid, or expired tokens.

```pascal
uses Poseidon.Middleware.JWT;

App.Use(JWTMiddleware('my-secret'));

// Per-route, with issuer/audience checks and a mandatory exp claim
App.Get('/profile',
  JWTMiddleware('my-secret', 'Unauthorized', 'my-issuer', 'my-audience', True),
  HandleProfile);
```

`JWTSign(APayload, ASecret)` mints a token for testing/issuing. Only symmetric
HMAC secrets are supported — no RSA/EC public-key verification.

---

## 3. Logger

Writes one line per request to stdout (or a custom sink): method, path,
status, and elapsed time.

```pascal
uses Poseidon.Middleware.Logger;

App.Use(LoggerMiddleware);

// Custom sink (e.g. a file)
App.Use(LoggerMiddleware(LogToFile('access.log')));

// JSON lines instead of plain text
App.Use(LoggerMiddlewareJSON);
```

`TLogOutput = reference to procedure(const ALine: string)` — pass any callback
that writes the formatted line somewhere other than stdout.

---

## 4. RateLimit

In-memory, per-IP **fixed-window** rate limiter. Thread-safe. Returns
`429 Too Many Requests` with a `Retry-After` header once the window's request
count is exceeded.

```pascal
uses Poseidon.Middleware.RateLimit;

// max 100 requests per 60-second window, per IP
App.Use(RateLimitMiddleware(100, 60));
```

Additional optional parameters: a custom message, `ATrustProxy` +
`ATrustedProxies` (to key by `X-Forwarded-For` only from trusted proxy IPs),
and `AMaxTrackedKeys` (bounds memory under a high-cardinality IP attack).
The counter store is in-process only — there is no pluggable external
(e.g. Redis) backend.

---

## 5. Compression

Compresses responses with gzip or deflate based on the client's
`Accept-Encoding` header. Skips responses below a configurable minimum size
(default 860 bytes).

```pascal
uses Poseidon.Middleware.Compression;

App.Use(CompressionMiddleware);

// With minimum size threshold (bytes)
App.Use(CompressionMiddleware(1024));
```

---

## 6. Timeout

Replaces the response with `503 Service Unavailable` if the handler chain took
longer than the configured duration to complete.

```pascal
uses Poseidon.Middleware.Timeout;

// 5000 ms timeout
App.Use(TimeoutMiddleware(5000));
```

The timeout applies to the handler chain only, not to the network read phase.

> **This is a post-execution check, not a preemptive abort.** `ANext()` still
> blocks until the handler actually returns; the middleware only measures how
> long that took and swaps the response afterward. **A handler that never
> returns (a hung outbound call, an infinite loop) is not interrupted by this
> middleware** — it keeps running, holding its worker, regardless of the
> configured duration. For that case use the server-level
> [`MaxHandlerRunMs` watchdog](../04-operations/limits-and-backpressure.md#stuck-handler-watchdog-233)
> instead, which detects the stuck handler independently of any middleware and
> closes the connection (see #233).

---

## 7. BodyLimit

Returns `413 Content Too Large` before reading the body when the
`Content-Length` header exceeds the configured maximum. Also enforces the limit
during streaming reads.

```pascal
uses Poseidon.Middleware.BodyLimit;

// 2 MB maximum body
App.Use(BodyLimitMiddleware(2 * 1024 * 1024));
```

---

## 8. RequestID

Generates a unique request identifier (UUID v4) and attaches it to
`X-Request-Id` in both request and response headers. Propagates an existing
client-supplied ID when present.

```pascal
uses Poseidon.Middleware.RequestID;

App.Use(RequestIDMiddleware);
```

Retrieve in a handler: `ACtx.Header('X-Request-Id')`

---

## 9. CircuitBreaker

Sliding-window circuit breaker with three states: `Closed → Open → HalfOpen →
Closed`. Opens once the error rate over the window exceeds a percentage
threshold, returning `503` while open; probes a half-open request before
fully closing again.

```pascal
uses Poseidon.Middleware.CircuitBreaker;

App.Use(CircuitBreakerMiddleware);

// Open when >= 50% of requests error over a 60s window; stay open 30s
App.Use(CircuitBreakerMiddleware(50, 60, 30));
```

Parameters: `AErrorThresholdPct` (default 50), `AWindowSec` (default 60),
`AOpenDurationSec` (default 30).

---

## 10. Metrics

Exposes a Prometheus-compatible `/metrics` endpoint with per-path request
counts, error counts, and a request-duration histogram.

```pascal
uses Poseidon.Middleware.Metrics;

App.Use(MetricsMiddleware('/metrics'));
```

Metrics are labeled by `path` only (no `method`/`status` labels — errors are a
separate `poseidon_errors_total` counter). Histogram bucket bounds (ms):
5, 10, 25, 50, 100, 250, 500, 1000, +Inf. Path cardinality is capped
(default 10000 unique paths) to bound memory under a hostile-path attack.

The same response also carries process-level gauges with no `path` label —
`poseidon_rss_kb`, `poseidon_malloc_inuse_kb`/`_arena_kb`/`_mmap_kb`,
`poseidon_delphi_heap_kb`, `poseidon_fd_count`, `poseidon_private_dirty_kb` —
sourced from `TPoseidonDiagnostics` (see
[metrics.md](../04-operations/metrics.md#process-level-gauges) for what each
means and how to read them together).

---

## 11. Static

Serves files from a local directory tree under a URL prefix. Handles
`If-None-Match` / `ETag` (returns `304 Not Modified`), MIME detection, and
optional gzip compression.

```pascal
uses Poseidon.Middleware.Static;

App.Use(StaticMiddleware('/assets', '/var/www/assets'));

// Disable gzip
App.Use(StaticMiddleware('/assets', '/var/www/assets', False));
```

No byte-range (`Range`/`206 Partial Content`) support, and no directory
listing feature.

---

## 12. HealthCheck

Health-check endpoints (`/health`, `/health/live`, `/health/ready`) built via a
small fluent builder — not a plain middleware function. Supports custom
liveness/readiness probes registered by name.

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
        Result := THealthCheckResult.Failed('db unreachable');
    end);
App.Use(LHealth.Build);
```

`Build` consumes and frees the builder — call it once, after all checks are
registered.

---

## 13. Security

Sets common security response headers: `Strict-Transport-Security` (HSTS,
only over TLS), `Content-Security-Policy`, `X-Frame-Options`,
`X-Content-Type-Options`, `Referrer-Policy`, and `Permissions-Policy`.

```pascal
uses Poseidon.Middleware.Security;

App.Use(SecurityMiddleware);
```

Individual headers can be overridden via `TSecurityOptions`.

---

## 14. Proxy

Forwards matching requests to a single upstream HTTP server and streams the
response back to the client.

```pascal
uses Poseidon.Middleware.Proxy;

// Forward everything as-is
App.Use(ProxyMiddleware('http://backend:8080'));

// Forward and strip a path prefix before forwarding upstream
App.Use(ProxyMiddlewareWithPrefix('http://backend:8080', '/api'));
```

Single upstream only — there is no built-in multi-upstream load balancing.

---

## 15. Digest

HTTP Digest authentication (MD5, `qop=auth`). Challenges unauthenticated
requests with a `WWW-Authenticate: Digest` header and validates credentials
via a caller-supplied HA1 callback.

```pascal
uses Poseidon.Middleware.Digest;

App.Use(DigestMiddleware('Protected Area',
  function(const AUser, ARealm: string): string
  begin
    // Return HA1 = MD5(user:realm:password), or '' to reject
    Result := DigestHA1(AUser, ARealm, FUserStore.GetPassword(AUser));
  end));
```

---

## 16. Guard

Request hardening: HTTP method whitelisting, path-traversal rejection, and
request-smuggling defenses (conflicting `Content-Length`/`Transfer-Encoding`).
Not an IP allow/deny list — see [Security](../../../src/Poseidon.Net.Security.pas)
for CIDR-based checks used elsewhere (e.g. Proxy Protocol).

```pascal
uses Poseidon.Middleware.Guard;

// Smuggling/traversal checks only, any method allowed
App.Use(GuardMiddleware);

// Also restrict to an allowed method list (405 otherwise)
App.Use(GuardMiddleware(['GET', 'POST']));
```

---

## 17. Validation

Catches `EPoseidonValidation` (raised by `Poseidon.Validation`'s attribute-based
validator) and converts it into an `application/problem+json` `422` response.
Takes no parameters — validation rules themselves are declared as attributes
on a DTO class, not inline in the middleware call.

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

// in the handler, after populating LDto from the request body:
TPoseidonValidator.ValidateOrRaise(LDto); // raises EPoseidonValidation on failure
```

Other available attributes: `[MaxLength(N)]`, `[Range(AMin, AMax)]`,
`[Pattern(ARegex)]`.

---

## 18. ProblemDetails

Converts unhandled exceptions and error responses into `application/problem+json`
payloads as defined by RFC 7807. Ensures all error responses have a consistent
structure.

```pascal
uses Poseidon.Middleware.ProblemDetails;

// Register first so it wraps the entire chain
App.Use(ProblemDetailsMiddleware);
```

Example output:

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

Generates an OpenAPI 3.x specification from manually registered route metadata
and serves it alongside a Swagger UI — a fluent builder, not a plain middleware
function.

```pascal
uses Poseidon.Middleware.OpenAPI;

var LOpenAPI: TPoseidonOpenAPI;
LOpenAPI := TPoseidonOpenAPI.Create;
LOpenAPI
  .Title('My API')
  .Version('1.0.0')
  .AddRoute('GET', '/ping', 'Health check')
  .AddRoute('POST', '/users', 'Create user');
App.Use(LOpenAPI.Build);
```

Defaults: spec at `/api-docs`, Swagger UI at `/api-docs/ui` (override the spec
path with `.SpecPath(...)`). There is no attribute-based route-metadata
mechanism — each route's summary/tags are supplied via `.AddRoute(...)`.

---

## 20. Cache

HTTP response cache with LRU eviction and automatic `ETag` generation
(`If-None-Match` → `304 Not Modified`). Cached responses are served without
executing the handler.

```pascal
uses Poseidon.Middleware.Cache;

// 60s TTL, 50 MB max cache size
App.Use(CacheMiddleware(60, 1024 * 1024 * 50));

// Scope to specific routes
App.Get('/products', CacheMiddleware(300, 1024 * 1024 * 10), HandleListProducts);
```

Only `GET`/`HEAD` responses with status `200` are cached. The cache key
includes the full path and query string. Served responses carry
`Vary: Accept-Encoding`.

---

## 21. Tracing

Propagates [W3C Trace Context](https://www.w3.org/TR/trace-context/): reads
an incoming `traceparent` header if present and well-formed (reusing its
trace-id and sampled flag), or originates a new trace if absent/malformed.
Either way, mints a new span-id for this hop and writes the resulting
`traceparent` as a response header.

```pascal
uses Poseidon.Middleware.Tracing;

App.Use(TracingMiddleware);
```

Register it before `LoggerMiddlewareJSON` (see [Metrics](#10-metrics) note
below) if you want `trace_id`/`span_id` in the JSON log line -
`LoggerMiddlewareJSON` reads the `traceparent` this middleware already set,
the same `ACtx.ExtraHeaders` mechanism `RequestIDMiddleware` uses for
`X-Request-ID`.

Distinct from `RequestIDMiddleware`: `X-Request-ID` is a simple opaque
per-request correlation id a client may set; `traceparent` is the
standardized, structured (trace-id + per-hop span-id) cross-service format.
Use both if you want either separately, or just Tracing if W3C propagation
is enough on its own.

**Scope:** propagation and exposure only - this does NOT export spans to
Tempo/Grafana or any OTLP backend (a real exporter is a separate, larger
piece of work: an OTLP client, span start/end timing, batching). What this
gives you is a correctly generated and propagated trace-id/span-id, ready
for whoever wires up an actual exporter to consume from the `traceparent`
response header or the JSON log line.

---

## See also

- [08 — Native API](../08-native-api/README.md) — App.Use, route groups, middleware chain
- [05 — Recipes](../05-recipes/README.md) — Runnable patterns combining multiple middlewares
