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
App.Use(CORSMiddleware([
  CORSAllowOrigin('https://example.com'),
  CORSAllowMethods('GET,POST,PUT,DELETE'),
  CORSAllowHeaders('Authorization,Content-Type'),
  CORSMaxAge(86400)
]));
```

---

## 2. JWT

Validates a Bearer token in the `Authorization` header. Injects claims into
`ACtx` on success; returns `401` on missing or invalid token.

```pascal
uses Poseidon.Middleware.JWT;

App.Use(JWTMiddleware('my-secret'));

// Per-route
App.Get('/profile', JWTMiddleware('my-secret'), HandleProfile);
```

The secret may be a symmetric HMAC key or a PEM-encoded RSA/EC public key.

---

## 3. Logger

Writes one line per request to stdout (or a custom writer): method, path,
status, duration, and bytes sent.

```pascal
uses Poseidon.Middleware.Logger;

App.Use(LoggerMiddleware);

// Custom format
App.Use(LoggerMiddleware(LLoggerOptions));
```

Output format: `[ISO8601] METHOD /path STATUS DURATIONms BYTESb`

---

## 4. RateLimit

Token-bucket rate limiter keyed by client IP. Returns `429 Too Many Requests`
with a `Retry-After` header when the bucket is empty.

```pascal
uses Poseidon.Middleware.RateLimit;

// 100 requests per 60-second window
App.Use(RateLimitMiddleware(100, 60));
```

The counter store is in-process. For multi-process deployments, wire in a Redis
backend via the `IRateLimitStore` interface.

---

## 5. Compression

Compresses responses with gzip or deflate based on the client's
`Accept-Encoding` header. Skips responses below a configurable minimum size.

```pascal
uses Poseidon.Middleware.Compression;

App.Use(CompressionMiddleware);

// With minimum size threshold (bytes)
App.Use(CompressionMiddleware(1024));
```

---

## 6. Timeout

Aborts request processing and returns `503 Service Unavailable` if the handler
does not complete within the configured duration.

```pascal
uses Poseidon.Middleware.Timeout;

// 5000 ms timeout
App.Use(TimeoutMiddleware(5000));
```

The timeout applies to the handler chain only, not to the network read phase.

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

Retrieve in a handler: `ACtx.Headers.Values['X-Request-Id']`

---

## 9. CircuitBreaker

Tracks handler failures and opens the circuit after `AThreshold` consecutive
errors, returning `503` until `AResetSecs` have elapsed. Closes automatically
on the first successful probe request.

```pascal
uses Poseidon.Middleware.CircuitBreaker;

// Open after 5 failures; retry after 30 seconds
App.Use(CircuitBreakerMiddleware(5, 30));
```

---

## 10. Metrics

Exposes a Prometheus-compatible `/metrics` endpoint with counters and histograms
for request count, error rate, and response-time distribution.

```pascal
uses Poseidon.Middleware.Metrics;

App.Use(MetricsMiddleware('/metrics'));
```

Collected labels: `method`, `path`, `status`. The histogram has pre-configured
buckets at 5 ms, 10 ms, 25 ms, 50 ms, 100 ms, 250 ms, 500 ms, 1 s, 2.5 s.

---

## 11. Static

Serves files from a local directory tree under a URL prefix. Handles
`If-Modified-Since`, `ETag`, and byte-range requests automatically.

```pascal
uses Poseidon.Middleware.Static;

App.Use(StaticMiddleware('/assets', '/var/www/assets'));
```

Directory listings are disabled by default. Pass `StaticEnableDirList` in
options to enable them.

---

## 12. HealthCheck

Returns `200 OK` with a JSON body on the configured path. Supports custom
liveness and readiness probes via callbacks.

```pascal
uses Poseidon.Middleware.HealthCheck;

App.Use(HealthCheckMiddleware('/health'));

// With custom check
App.Use(HealthCheckMiddleware('/health', procedure(var AOk: Boolean)
begin
  AOk := FDBConnection.Ping;
end));
```

Response body: `{"status":"ok","uptime":12345}`

---

## 13. Security

Sets common security response headers: `X-Frame-Options`, `X-Content-Type-Options`,
`X-XSS-Protection`, `Referrer-Policy`, `Permissions-Policy`, and a configurable
`Content-Security-Policy`.

```pascal
uses Poseidon.Middleware.Security;

App.Use(SecurityMiddleware);
```

Individual headers can be overridden via `TSecurityOptions`.

---

## 14. Proxy

Forwards matching requests to an upstream HTTP server and streams the response
back to the client. Rewrites the request path by stripping the configured prefix.

```pascal
uses Poseidon.Middleware.Proxy;

App.Use(ProxyMiddleware('/api', 'http://backend:8080'));
```

Supports upstream load balancing when multiple URLs are supplied as a
comma-separated list. Uses a round-robin strategy by default.

---

## 15. Digest

HTTP Digest authentication (`RFC 7616`). Challenges unauthenticated requests
with a `WWW-Authenticate: Digest` header and validates credentials via a
caller-supplied callback.

```pascal
uses Poseidon.Middleware.Digest;

App.Use(DigestMiddleware('Protected Area',
  function(AUser: string): string
  begin
    // Return the stored HA1 hash for AUser, or '' to reject
    Result := FUserStore.GetHA1(AUser);
  end));
```

---

## 16. Guard

IP-based access control. Requests are checked against a whitelist and a
blacklist. A non-empty whitelist means all other IPs are denied.

```pascal
uses Poseidon.Middleware.Guard;

var LGuard: TGuardOptions;
LGuard.Whitelist := ['10.0.0.0/8', '192.168.1.0/24'];
LGuard.Blacklist := ['10.0.0.99'];
App.Use(GuardMiddleware(LGuard));
```

CIDR notation is supported for both lists.

---

## 17. Validation

Validates request fields (body JSON properties, query params, headers) against
a declarative rule set. Returns `422 Unprocessable Entity` with a structured
error body on failure.

```pascal
uses Poseidon.Middleware.Validation;

App.Post('/users',
  ValidationMiddleware([
    VRequired('body.name'),
    VEmail('body.email'),
    VMinLength('body.password', 8)
  ]),
  HandleCreateUser);
```

Rules are composable. Custom rule functions are supported.

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

Generates an OpenAPI 3.1 specification from registered routes and serves it as
JSON. Also mounts Swagger UI at a configurable path.

```pascal
uses Poseidon.Middleware.OpenAPI;

App.Use(OpenAPIMiddleware('/openapi.json', '/docs'));
```

Route metadata (summary, tags, request/response schemas) is supplied via
`[OpenAPIRoute]` attributes on handler procedures, or via a fluent builder
attached to the route registration.

---

## 20. Cache

HTTP response cache with LRU eviction, `ETag` generation, and `304 Not Modified`
support. Cached responses are served without executing the handler.

```pascal
uses Poseidon.Middleware.Cache;

// 512 entries, 60-second TTL
App.Use(CacheMiddleware(512, 60));

// Scope to specific routes
App.Get('/products', CacheMiddleware(256, 300), HandleListProducts);
```

Only `GET` and `HEAD` responses with status `200` are cached. The cache key
includes the full URL path and query string. `Vary` headers are respected.

---

## See also

- [08 — Native API](../08-native-api/README.md) — App.Use, route groups, middleware chain
- [05 — Recipes](../05-recipes/README.md) — Runnable patterns combining multiple middlewares
