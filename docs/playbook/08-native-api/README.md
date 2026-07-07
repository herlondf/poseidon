# 08 — Native API

Reference for `TPoseidonServer` and its associated types. This is the primary
interface for building HTTP services directly on Poseidon without a higher-level
framework provider.

---

## TPoseidonServer

`TPoseidonServer` is the central object of every Poseidon application. It owns
the listener socket, worker pool, buffer pool, and route table. Create one
instance per process (multiple instances on distinct ports are supported).

```pascal
var
  LApp: TPoseidonServer;
begin
  LApp := TPoseidonServer.Create;
  try
    LApp.WorkerCount := 8;
    LApp.MaxConnections := 10000;
    LApp.Get('/ping', procedure(var ACtx: TNativeRequestContext)
    begin
      ACtx.Body := 'pong';
    end);
    LApp.Listen(9000);
  finally
    LApp.Free;
  end;
end;
```

---

## TNativeRequestContext

`TNativeRequestContext` is a stack-allocated record that represents a single
HTTP request/response pair. It is passed by `var` reference to every route
handler and middleware — no heap allocation, no reference counting.

Key fields:

| Field | Type | Description |
|-------|------|-------------|
| `Method` | `string` | HTTP verb (GET, POST, …) |
| `Path` | `string` | URL path, without query string |
| `QueryString` | `string` | Raw query string (after `?`) |
| `Headers` | `TStringList` | Request headers (`Name: Value`) |
| `Body` | `string` | Request or response body |
| `Status` | `Integer` | HTTP response status code (default 200) |
| `ContentType` | `string` | Response `Content-Type` header |
| `ExtraHeaders` | `TStringList` | Additional response headers |

### Accessing parameters

```pascal
// Route parameter defined as /users/:id
var LId: string;
LId := ACtx.Param('id');

// Query string parameter (?page=2)
var LPage: string;
LPage := ACtx.QueryParam('page');

// Request header
var LAuth: string;
LAuth := ACtx.Headers.Values['Authorization'];
```

### Setting the response

```pascal
ACtx.Status      := 201;
ACtx.ContentType := 'application/json';
ACtx.Body        := '{"id":42}';
ACtx.ExtraHeaders.Values['X-Request-Id'] := '...';
```

---

## Route registration

All registration methods return `Self`, enabling a fluent call chain.

```pascal
App
  .Get('/users',         HandleListUsers)
  .Post('/users',        HandleCreateUser)
  .Put('/users/:id',     HandleReplaceUser)
  .Patch('/users/:id',   HandleUpdateUser)
  .Delete('/users/:id',  HandleDeleteUser)
  .Head('/users',        HandleHead)
  .All('/probe',         HandleAny);
```

Signatures accepted by every verb method:

```pascal
// Simple handler
procedure(var ACtx: TNativeRequestContext)

// Handler with next (same as middleware)
procedure(var ACtx: TNativeRequestContext; ANext: TProc)
```

Route parameters use `:name` syntax. Wildcard segments use `*`.

---

## Middleware

### Type definition

```pascal
TNativeMiddlewareFunc =
  reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

Calling `ANext` passes control to the next middleware or to the route handler.
Not calling `ANext` short-circuits the chain (useful for auth, rate limiting).

### Global middleware

```pascal
App.Use(LoggerMiddleware);
App.Use(CORSMiddleware);
App.Use(RequestIDMiddleware);
```

Middleware is executed in registration order before every matched route.

### Per-route middleware

```pascal
App.Get('/admin', JWTMiddleware('secret'), HandleAdmin);
```

Multiple middleware arguments are accepted before the final handler.

---

## Route groups

Groups apply a common prefix (and optionally shared middleware) to a set of routes.

### Inline group

```pascal
var LApi: TPoseidonRouteGroup;
LApi := App.Group('/api/v1');
LApi.Get('/users', HandleListUsers);
LApi.Post('/users', HandleCreateUser);
```

### Block group

```pascal
App.GroupBlock('/api/v1', procedure
begin
  App.Get('/users',  HandleListUsers);
  App.Post('/users', HandleCreateUser);
end);
```

Groups can be nested. Middleware passed to `Group` or `GroupBlock` applies only
to routes registered within that group.

---

## WebSocket

```pascal
App.WebSocket('/ws/chat', procedure(AConn: TPoseidonWSConnection; AMsg: string)
begin
  AConn.Send('echo: ' + AMsg);
end);
```

The WebSocket upgrade is handled automatically when the client sends a valid
`Upgrade: websocket` request to the registered path.

---

## Lifecycle

```pascal
// Start listening (blocks until Stop is called from another thread or signal)
App.Listen(9000);

// Stop accepting new connections and drain existing ones
App.Stop;
```

`Listen` returns only after `Stop` completes the drain phase. `DrainTimeoutMs`
controls how long Poseidon waits for in-flight requests before forcibly closing
connections.

---

## Graceful reload

```pascal
App.PIDFile := '/var/run/poseidon.pid';
App.DrainTimeoutMs := 5000;
InstallSignalHandler(App); // Linux only
App.Listen(9000);
```

On Linux, `InstallSignalHandler` maps `SIGUSR2` to a zero-downtime restart:
the new process binds the same port (via `SO_REUSEPORT`) while the old process
drains and exits. On Windows, the PID file is written but signal handling is
not available — use a service manager restart instead.

---

## Configuration properties

| Property | Type | Default | Description |
|----------|------|---------|-------------|
| `MaxConnections` | `Integer` | 10000 | Maximum concurrent open connections |
| `WorkerCount` | `Integer` | CPU count | I/O worker threads |
| `IdleTimeoutMs` | `Integer` | 30000 | Close idle keep-alive connections after this many ms |
| `DrainTimeoutMs` | `Integer` | 5000 | Max ms to wait for in-flight requests on `Stop` |
| `PerCoreAccept` | `Boolean` | False | Enable `SO_REUSEPORT` per-core accept (Linux) |
| `PIDFile` | `string` | `''` | Path to write the process PID file |
| `ReadBufferSize` | `Integer` | 32768 | Per-connection receive buffer size (bytes) |
| `WriteBufferSize` | `Integer` | 65536 | Per-connection send buffer size (bytes) |
| `MaxHeaderSize` | `Integer` | 8192 | Maximum total request header block size (bytes) |
| `MaxBodySize` | `Int64` | 1 MB | Maximum request body size before 413 is returned |
| `TCPNoDelay` | `Boolean` | True | Disable Nagle algorithm on accepted sockets |
| `ReuseAddr` | `Boolean` | True | `SO_REUSEADDR` on the listener socket |

---

## SSL / TLS

```pascal
// Single certificate
App.ConfigureSSL('cert.pem', 'key.pem');

// Multiple SNI certificates
App.AddSSLCert('example.com',  'example.pem',  'example.key');
App.AddSSLCert('api.example.com', 'api.pem', 'api.key');

// Mutual TLS (client certificate required)
App.ConfigureMTLS('ca.pem');

// HTTP/2 (requires SSL)
App.EnableHTTP2;

App.Listen(443);
```

SSL is handled by the built-in OpenSSL wrapper. The certificate files are read
once at `Listen` time and reloaded on graceful restart without dropping connections.

---

## See also

- [02 — Core Concepts](../02-core-concepts/README.md)
- [09 — Middlewares](../09-middlewares/README.md)
- [05 — Recipes](../05-recipes/README.md)
