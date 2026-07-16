# Poseidon — API Reference

Complete reference for the **public** API surface exposed through `uses Poseidon`
(the facade unit) plus the middleware units under `middlewares/`. Signatures are
copied verbatim from the source `interface` sections.

> This page is the hand-maintained, navigable reference. For a browsable HTML
> reference generated directly from the source doc-comments, run
> [`docs/api/gen-api.ps1`](./api/gen-api.ps1) (PasDoc).
>
> New to Poseidon? Start with the [Native API playbook](./playbook/08-native-api/README.md).
> Upgrading from v1? See the [v1 → v2 migration guide](./MIGRATION_v1_to_v2.md).

---

## Contents

- [The facade — `uses Poseidon`](#the-facade--uses-poseidon)
- [`TPoseidonServer`](#tposeidonserver)
- [`TNativeRequestContext`](#tnativerequestcontext)
- [Handler & middleware callback types](#handler--middleware-callback-types)
- [`TNativeGroup` / route groups](#tnativegroup--route-groups)
- [WebSocket — `IPoseidonWSConn`](#websocket--iposeidonwsconn)
- [Validation (RTTI attributes)](#validation-rtti-attributes)
- [Status codes & MIME types](#status-codes--mime-types)
- [Problem Details (RFC 7807)](#problem-details-rfc-7807)
- [Exceptions](#exceptions)
- [Logging](#logging)
- [Middlewares](#middlewares)

---

## The facade — `uses Poseidon`

A single `uses Poseidon;` re-exports the entire primary API. You rarely need to
reference the underlying units directly.

| Re-exported name | Origin unit |
|---|---|
| `TPoseidonServer` | `Poseidon.Native.Server` |
| `TNativeRequestContext`, `PNativeRequestContext` | `Poseidon.Native.Types` |
| `TNativeHandler`, `TNativeHandlerFunc` | `Poseidon.Native.Types` |
| `TNativeMiddleware`, `TNativeMiddlewareFunc` | `Poseidon.Native.Types` |
| `TNativeGroup`, `TNativeGroupBlock` | `Poseidon.Native.Group` |
| `IPoseidonWSConn`, `TWSMessageCallback` | `Poseidon.Net.WebSocket` |
| `EPoseidonException`, `EPoseidonCallbackInterrupted`, `EPoseidonValidation` | `Poseidon.Exception` |
| `TProblemDetail` | `Poseidon.Problem` |
| `THTTPStatus`, `TMimeType` | `Poseidon.Status` |
| `TPoseidonValidator`, `TPoseidonValidationError`, validation attributes | `Poseidon.Validation` |
| `TLogLevel`, `TOnPoseidonLog`, `TOnPoseidonRequestLog` | `Poseidon.Net.Types` |

Middleware factories live in `middlewares/` and are **not** re-exported by the
facade — add the specific `Poseidon.Middleware.*` unit to your `uses` clause.

---

## `TPoseidonServer`

*(unit `Poseidon.Native.Server`)* — instance-based native HTTP server with a
fluent, zero-copy routing API; owns the router, route groups, and the underlying
transport. Create one instance per process (multiple instances on distinct ports
are supported).

### Construction / lifecycle

| Signature | Description |
|---|---|
| `constructor Create;` | Creates the server, router, group list, and shutdown event. |
| `destructor Destroy; override;` | Stops the server if running, then frees all owned resources. |
| `procedure Listen(APort: Integer; const AHost: string = '0.0.0.0'; AOnListen: TProc = nil);` | Starts listening, writes the PID file, invokes `AOnListen`, then blocks until shutdown. Raises if already listening. |
| `procedure Stop;` | Stops the transport, removes the PID file, signals shutdown. No-op if not running. |

### Route registration

Each verb has two overloads — a `TNativeHandler` (method pointer) and a
`TNativeHandlerFunc` (anonymous function). All return `TPoseidonServer` for
fluent chaining.

| Signature | Description |
|---|---|
| `function Get(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;` | Registers a `GET` route. |
| `function Get(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;` | `GET` route (anonymous function). |
| `function Post(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registers a `POST` route. |
| `function Put(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registers a `PUT` route. |
| `function Delete(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registers a `DELETE` route. |
| `function Patch(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registers a `PATCH` route. |
| `function Head(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registers a `HEAD` route. |
| `function All(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registers the handler for all methods (`GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS`). |

Path params use `:name` (e.g. `/users/:id`); read them with `Ctx.Param('id')`.

### Global middleware

| Signature | Description |
|---|---|
| `function Use(AMiddleware: TNativeMiddleware): TPoseidonServer; overload;` | Appends a global middleware (method pointer), run before every route. |
| `function Use(AMiddleware: TNativeMiddlewareFunc): TPoseidonServer; overload;` | Appends a global middleware (anonymous function). |

### Route groups

| Signature | Description |
|---|---|
| `function Group(const APrefix: string): TNativeGroup;` | Creates and returns a route group under `APrefix` (owned by the server). |
| `procedure GroupBlock(const APrefix: string; ABlock: TNativeGroupBlock);` | Creates a group under `APrefix` and passes it to the block callback. |

### WebSocket

| Signature | Description |
|---|---|
| `procedure WebSocket(const APath: string; AHandler: TWSMessageCallback);` | Registers a WebSocket message handler on `APath`. |

### TLS / HTTP/2 configuration

| Signature | Description |
|---|---|
| `procedure ConfigureSSL(const ACertFile, AKeyFile: string);` | Enables TLS with the given certificate and private-key files. |
| `procedure AddSSLCert(const AHostName, ACertFile, AKeyFile: string);` | Adds an SNI certificate bound to `AHostName`. |
| `procedure ConfigureMTLS(const ACAFile: string);` | Enables mutual TLS, verifying client certs against the CA file. |
| `procedure EnableHTTP2(AEnabled: Boolean = True);` | Enables (or disables) HTTP/2. |

### Properties

| Property | Description |
|---|---|
| `Server: TPoseidonNativeServer` (read-only) | Underlying native transport. |
| `Running: Boolean` (read-only) | True while listening. |
| `MaxConnections: Integer` | Max total concurrent connections. |
| `MaxConnectionsPerIP: Integer` | Max concurrent connections per client IP. |
| `WorkerCount: Integer` | Max worker-thread pool size. |
| `MinWorkerCount: Integer` | Minimum (baseline) worker-thread count. |
| `IdleTimeoutMs: Integer` | Idle connection timeout (ms). |
| `MaxRequestSize: Integer` | Max accepted request body size (bytes). |
| `MaxHeaderSize: Integer` | Max accepted header block size (bytes). |
| `DrainTimeoutMs: Integer` | Graceful-drain timeout on shutdown (ms). |
| `MaxQueueDepth: Integer` | Max depth of the worker dispatch queue. |
| `SecureHeadersEnabled: Boolean` | Toggles automatic security response headers. |
| `ServerBanner: string` | Value sent in the `Server` response header. |
| `TCPFastOpen: Boolean` | Enables TCP Fast Open on the listener. |
| `PerCoreAccept: Boolean` | Enables per-core accept sockets (SO_REUSEPORT-style scaling). |
| `SyncDispatch: Boolean` | Dispatches on the IO thread instead of the worker pool. |
| `OnH2Push: TOnH2Push` | HTTP/2 server-push hook. |
| `PIDFile: string` | Path of the PID file written on `Listen`, removed on `Stop`. |
| `OnLog: TOnPoseidonLog` | General log callback. |
| `OnRequestLog: TOnPoseidonRequestLog` | Per-request access-log callback. |

> The port is a required argument to `Listen`; there is no default-port constant.
> The default host is the `Listen` parameter default `'0.0.0.0'`.

---

## `TNativeRequestContext`

*(unit `Poseidon.Native.Types`)* — stack-allocated `record` passed by `var` to
every handler and middleware. Request-side fields reference the parsed request
without copying; response-side fields are what you write. `PNativeRequestContext`
is `^TNativeRequestContext`.

### Fields

```pascal
// --- request (read) ---
Method: string;                              // "GET", "POST", ...
Path: string;                                // request path, no query string
QueryString: string;                         // raw query (after "?"), undecoded
RemoteAddr: string;                          // client remote address
RawBody: TBytes;                             // raw inbound body bytes
KeepAlive: Boolean;                          // connection is keep-alive
Headers: TArray<TPair<string,string>>;       // request headers
Params: TArray<TPair<string,string>>;        // route params (e.g. :id)

// --- response (write) ---
Status: Integer;                             // response status code
ContentType: string;                         // response Content-Type
Body: TBytes;                                // response body bytes
ExtraHeaders: TArray<TPair<string,string>>;  // additional response headers
Handled: Boolean;                            // set True to short-circuit the pipeline
```

### Methods

| Signature | Description |
|---|---|
| `function Param(const AName: string): string;` | Route parameter by name (case-insensitive); `''` if absent. |
| `function Header(const AName: string): string;` | Request header by name (case-insensitive); `''` if absent. |
| `function Query(const AName: string): string;` | URL-decoded query-string value by name (case-insensitive); `''` if absent. |

There is no built-in JSON helper on the record — write `Body`/`ContentType`
directly (e.g. `Ctx.ContentType := TMimeType.ApplicationJSON`), or use the
`Validation` / `ProblemDetails` middlewares. `RawBody` is the inbound body;
`Body` is the outbound body.

---

## Handler & middleware callback types

*(unit `Poseidon.Native.Types`)*

```pascal
TNativeHandler       = procedure(var ACtx: TNativeRequestContext) of object;
TNativeHandlerFunc   = reference to procedure(var ACtx: TNativeRequestContext);
TNativeMiddleware    = procedure(var ACtx: TNativeRequestContext; ANext: TProc) of object;
TNativeMiddlewareFunc = reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

A middleware receives `ANext: TProc`; call it to run the rest of the chain, or
omit the call to short-circuit (e.g. an auth middleware returning 401).

---

## `TNativeGroup` / route groups

*(unit `Poseidon.Native.Group`)* — fluent route group registering routes under a
common prefix, with per-group middleware applied to every route added through it.

| Signature | Description |
|---|---|
| `constructor Create(ARouter: TNativeRouter; const APrefix: string);` | Group bound to a router; prefix normalized to a single leading slash. |
| `function Use(AMiddleware: TNativeMiddleware / TNativeMiddlewareFunc): TNativeGroup; overload;` | Adds middleware applied to routes registered afterwards on this group. |
| `function Get/Post/Put/Delete/Patch/Head(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TNativeGroup; overload;` | Registers a route under the group prefix (two overloads each). |
| `property Prefix: string` (read-only) | The group's normalized prefix. |

`TNativeGroup` has **no** `All` overload (unlike `TPoseidonServer`).

```pascal
TNativeGroupBlock = reference to procedure(G: TNativeGroup);
```

Used by `TPoseidonServer.GroupBlock` to configure a group inline.

---

## WebSocket — `IPoseidonWSConn`

*(unit `Poseidon.Net.WebSocket`)* — per-connection handle a WebSocket handler
uses to send frames and control one live client connection.
GUID `{B2C3D4E5-F607-8901-BCDE-F01234567891}`.

| Signature | Description |
|---|---|
| `procedure Send(const AText: string);` | Sends a text frame (UTF-8); permessage-deflate when negotiated. No-op if closed. |
| `procedure SendBinary(const AData: TBytes);` | Sends a binary frame; permessage-deflate when negotiated. No-op if closed. |
| `procedure Close(ACode: Word = 1000);` | Sends a close frame (default 1000) and tears down; idempotent. |
| `property RemoteAddr: string` (read-only) | Client remote address. |
| `property Closed: Boolean` (read-only) | Whether the connection has been closed. |
| `property DeflateEnabled: Boolean` (read-only) | Whether permessage-deflate was negotiated. |

```pascal
TWSMessageCallback = reference to procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame);
```

Invoked per inbound message with the connection handle and the decoded frame
(opcode, fin/RSV flags, payload).

---

## Validation (RTTI attributes)

*(unit `Poseidon.Validation`)* — decorate a DTO's **fields** (validation is
driven off `GetFields`, not properties) with attributes, then validate.

```pascal
type
  TCreateUserDTO = class
  public
    [Required][MinLength(3)][MaxLength(30)] Name: string;
    [Required][Email]                       Email: string;
    [Range(18, 120)]                        Age: Integer;
    [Pattern('^\+?\d{8,15}$', 'phone must be 8-15 digits')] Phone: string;
  end;
```

| Attribute | Constructor | Enforces |
|---|---|---|
| `Required` | *(none)* | Non-empty string / non-nil object / non-empty array (numeric 0 is valid). |
| `MinLength` | `Create(AMin: Integer)` | String length ≥ `AMin`. |
| `MaxLength` | `Create(AMax: Integer)` | String length ≤ `AMax`. |
| `Email` | *(none)* | Matches an email regex. |
| `Range` | `Create(AMin, AMax: Double)` | Numeric value in `[AMin, AMax]`; non-numeric fails cleanly. |
| `Pattern` | `Create(const APattern: string; const AMessage: string = '')` | String matches regex `APattern`; custom message optional. |

```pascal
TPoseidonValidationError = record
  Field: string;
  Message: string;
end;

TPoseidonValidator = class
  class function Validate(AObject: TObject; out AErrors: TArray<TPoseidonValidationError>): Boolean;
  class procedure ValidateOrRaise(AObject: TObject);   // raises EPoseidonValidation (422)
end;
```

`Validate` returns `True` when valid; on failure `AErrors` collects **all**
violations. `ValidateOrRaise` joins all messages with `'; '` and raises
`EPoseidonValidation` (status 422). Pair with the `Validation` middleware to turn
that into a structured 422 JSON response.

---

## Status codes & MIME types

*(unit `Poseidon.Status`)* — dependency-free records (no `Web.HTTPApp`).

```pascal
THTTPStatus = record
  constructor Create(ACode: Integer);
  function ToInteger: Integer;
  class operator Implicit(AStatus: THTTPStatus): Integer;  // usable anywhere an Integer status is expected
end;
```

Representative constants (`class var: THTTPStatus`): `Ok` (200), `Created` (201),
`NoContent` (204), `MovedPermanently` (301), `Found` (302), `NotModified` (304),
`BadRequest` (400), `Unauthorized` (401), `Forbidden` (403), `NotFound` (404),
`MethodNotAllowed` (405), `Conflict` (409), `PayloadTooLarge` (413),
`UnprocessableEntity` (422), `TooManyRequests` (429), `InternalServerError` (500),
`BadGateway` (502), `ServiceUnavailable` (503).

```pascal
TMimeType = record
  class var ApplicationJSON: string;               // 'application/json'
  class var ApplicationXWWWFormURLEncoded: string; // 'application/x-www-form-urlencoded'
  class var MultiPartFormData: string;             // 'multipart/form-data'
  class var TextPlain: string;                      // 'text/plain'
  class var TextHTML: string;                       // 'text/html'
  class var ApplicationOctetStream: string;         // 'application/octet-stream'
  class var ApplicationProblemJSON: string;         // 'application/problem+json'
end;
```

Usage: `Ctx.Status := THTTPStatus.Ok;  Ctx.ContentType := TMimeType.ApplicationJSON;`

---

## Problem Details (RFC 7807)

*(unit `Poseidon.Problem`)*

```pascal
TProblemDetail = record
  TypeURI: string;    // -> "type"     (defaults to 'about:blank')
  Title: string;      // -> "title"    (CanonicalTitle(Status))
  Status: Integer;    // -> "status"
  Detail: string;     // -> "detail"   (emitted only when non-empty)
  Instance: string;   // -> "instance" (emitted only when non-empty)
  function ToJSON: TJSONObject;                                             // application/problem+json
  class function CanonicalTitle(AStatus: Integer): string; static;         // status -> reason phrase
  class function FromException(E: EPoseidonException; const AInstance: string): TProblemDetail; static;
end;
```

`FromException` builds a problem from an `EPoseidonException`
(`Status := E.Status.ToInteger`, `Detail := E.Message`). The `ProblemDetails`
middleware wires this up automatically for unhandled errors.

---

## Exceptions

*(unit `Poseidon.Exception`)*

```pascal
EPoseidonException = class(Exception)     // carries an HTTP status
  constructor Create(const AMessage: string; const AStatus: THTTPStatus); reintroduce;
  property Status: THTTPStatus read FStatus;

EPoseidonValidation = class(EPoseidonException)   // always status 422
  constructor Create(const AMessage: string);

EPoseidonCallbackInterrupted = class(Exception)   // deliberately interrupted callback
  constructor Create;
```

- `EPoseidonException` — base app exception, pairs a message with a `THTTPStatus`.
- `EPoseidonValidation` — descends from `EPoseidonException`; fixed status 422.
- `EPoseidonCallbackInterrupted` — descends from `Exception` (not
  `EPoseidonException`); signals a deliberately interrupted callback.

Raising `EPoseidonException('not found', THTTPStatus.NotFound)` in a handler is
translated to the corresponding HTTP response (JSON problem when the
`ProblemDetails` middleware is installed).

---

## Logging

*(unit `Poseidon.Net.Types`)*

```pascal
TLogLevel = (llDebug, llInfo, llWarning, llError);

TOnPoseidonLog = reference to procedure(ALevel: TLogLevel; const AMessage: string);

TPoseidonRequestLogEvent = record
  Method: string; Path: string; Status: Integer; DurationMs: Int64;
  RemoteAddr: string; RxBytes: Int64; TxBytes: Int64;
end;

TOnPoseidonRequestLog = reference to procedure(const AEvent: TPoseidonRequestLogEvent);
```

Assign `App.OnLog` for framework diagnostics and `App.OnRequestLog` for a
structured per-request access log. For a ready-made access log, use the `Logger`
middleware instead.

---

## Middlewares

Factories live in `middlewares/Poseidon.Middleware.<Name>.pas`. Add the unit to
your `uses` clause and install with `App.Use(...)`. Most return a
`TNativeMiddlewareFunc`; `HealthCheck` and `OpenAPI` use a builder class whose
`.Build` returns the middleware.

### Security & access control

| Middleware | Factory (verbatim) | Use when |
|---|---|---|
| **CORS** | `CORSMiddleware` / `CORSMiddleware(const AOptions: TCORSOptions)`; `DefaultCORSOptions` | A browser front-end on another origin calls the API. |
| **JWT** | `JWTMiddleware(const ASecret: string; const AUnauthorizedMsg: string = 'Unauthorized'; const AIssuer: string = ''; const AAudience: string = ''; ARequireExp: Boolean = False)`; also `JWTSign(APayload: TJSONObject; const ASecret: string): string` | Stateless HS256 bearer auth; set issuer/audience/require-exp to block cross-service replay. |
| **Digest** | `DigestMiddleware(const ARealm: string; AGetHA1: TGetHA1Func)`; `DigestHA1(const AUser, ARealm, APass: string): string` | Clients require RFC 2617 digest auth. |
| **Security** | `SecurityMiddleware` / `SecurityMiddleware(const AOptions: TSecurityOptions)`; `DefaultSecurityOptions` | Any public-facing app — HSTS/CSP/X-Frame-Options/etc. |
| **Guard** | `GuardMiddleware` / `GuardMiddleware(const AAllowedMethods: TArray<string>)` | Restrict an app/group to specific verbs. |
| **RateLimit** | `RateLimitMiddleware(AMaxRequests, AWindowSeconds: Integer; const AMessage: string = 'Too Many Requests'; ATrustProxy: Boolean = False; const ATrustedProxies: TArray<string> = nil; AMaxTrackedKeys: Integer = 100000)` | Throttle abusive clients (429). Enable `ATrustProxy` only behind a trusted LB. |

**`TCORSOptions`**: `AllowOrigin, AllowMethods, AllowHeaders, ExposeHeaders: string; AllowCredentials: Boolean; MaxAge: Integer`.
**`TSecurityOptions`**: `HSTSMaxAge: Integer; HSTSIncludeSubDomains, HSTSPreload: Boolean; CSP, XFrameOptions, XContentTypeOptions, ReferrerPolicy, PermissionsPolicy: string`.

### Observability

| Middleware | Factory (verbatim) | Use when |
|---|---|---|
| **Logger** | `LoggerMiddleware` / `LoggerMiddleware(AOutput: TLogOutput)`; `LoggerMiddlewareJSON` / `LoggerMiddlewareJSON(AOutput)`; `LogToFile(const AFileName: string): TLogOutput` | Request tracing; JSON variant for structured pipelines. |
| **Metrics** | `MetricsMiddleware(const APath: string = '/metrics')` | Expose Prometheus-style metrics for scraping. |
| **RequestID** | `RequestIDMiddleware` | Correlate logs/traces across a request. |
| **HealthCheck** | builder: `TPoseidonHealthCheck.Create.BasePath(...).AddCheck(name, proc).Build` | Liveness/readiness probes (`/health`, `/health/live`, `/health/ready`). |

`THealthCheckResult`: `Healthy: Boolean; Error: string; class function OK; class function Failed(const AReason: string)`.

### Payload & content

| Middleware | Factory (verbatim) | Use when |
|---|---|---|
| **Compression** | `CompressionMiddleware(AMinSize: Integer = 860)` | Shrink text/JSON responses (gzip). |
| **BodyLimit** | `BodyLimitMiddleware(AMaxBytes: Int64)` | Defend against oversized-payload DoS. |
| **Cache** | `CacheMiddleware(ATTLSeconds: Integer = 60; AMaxBytes: Int64 = 52428800)` / `CacheMiddleware(const AOptions: TCacheOptions)` | Cache expensive idempotent GETs (ETag/304). |
| **Static** | `StaticMiddleware(const AUrlPrefix, ARootDir: string; AEnableGzip: Boolean = True)` | Serve a directory of assets under a URL prefix. |

**`TCacheOptions`**: `TTLSeconds: Integer; MaxBytes: Int64; MaxEntries: Integer; class function Default`.

### Resilience & routing

| Middleware | Factory (verbatim) | Use when |
|---|---|---|
| **Timeout** | `TimeoutMiddleware(ATimeoutMs: Integer)` | Cap slow handlers/upstreams. |
| **CircuitBreaker** | `CircuitBreakerMiddleware(AErrorThresholdPct: Integer = 50; AWindowSec: Integer = 60; AOpenDurationSec: Integer = 30)` | Fail fast (503) when downstream error rate spikes. |
| **Proxy** | `ProxyMiddleware(const AUpstream: string)`; `ProxyMiddlewareWithPrefix(const AUpstream, APrefix: string)` | Reverse-proxy to a backend (gateway). |

### API definition & errors

| Middleware | Factory (verbatim) | Use when |
|---|---|---|
| **OpenAPI** | builder: `TPoseidonOpenAPI.Create.Title(...).Version(...).AddRoute(m, p, s, tags).Build` | Publish an OpenAPI 3.x spec + Swagger UI. |
| **ProblemDetails** | `ProblemDetailsMiddleware` | Standardized RFC 7807 error responses. |
| **Validation** | `ValidationMiddleware` | Turn attribute-validation failures into 422 JSON. |

---

> 🇧🇷 Leia este documento em português: [API-REFERENCE_pt-br.md](./API-REFERENCE_pt-br.md)
