# Migrating to Poseidon v2

Poseidon **v2** is the native, zero-copy engine (`TPoseidonServer` +
`TNativeRequestContext`). The **v1** programming model is the Horse-compatible
API (`THorse` + `THorseRequest`/`THorseResponse`), which many existing services
run in production today.

You have **two migration paths**. Pick based on how much you want to change now.

| Path | Effort | Payoff |
|---|---|---|
| **A. Keep the compat layer** | Minimal — recompile against the Horse-compat shim | Zero handler rewrites; runs on the v2 engine as-is |
| **B. Port to the native API** | Per-handler rewrite | Best throughput (~15% faster than compat in the benchmark) and the full v2 DX (typed context, native middlewares) |

Both paths run on the same v2 engine (IOCP/RIO on Windows, epoll/io_uring on
Linux). Path A is the safe first step; Path B is where the performance and
ergonomics live.

---

## Path A — Keep the Horse-compatible layer

The compat shim (`compat/Horse.pas`) re-exports the Horse types over Poseidon,
so existing `THorse`-based code compiles and runs unchanged. This is the
recommended first move: swap the engine, keep your handlers, validate in
staging, then port hot paths later.

```pascal
uses
  Horse;  // resolves to the Poseidon compat shim on the search path

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);
  THorse.Listen(9000);
end;
```

Nothing in your controller/middleware code changes. Confirm the compat unit is
first on your unit search path.

---

## Path B — Port to the native API

The native model fuses request and response into one stack-allocated
`var Ctx: TNativeRequestContext` — no heap allocation, no reference counting per
request. This is the fastest path and unlocks the native middleware set.

### The shape of the change

**v1 (Horse):** a global singleton, two parameters, a fluent response builder.

```pascal
procedure CustomersFind(Req: THorseRequest; Res: THorseResponse);
begin
  LObj := LDAO.FindById(StrToIntDef(Req.Params['id'], 0));
  if LObj = nil then
    Res.Status(404).Send('Not found')
  else
    Res.ContentType('application/json').Send(LObj.ToJSON);
end;

// registration
THorse.Get('/customers/:id', CustomersFind);
THorse.Listen(9000);
```

**v2 (native):** an owned instance, one `var Ctx`, assigned response fields.

```pascal
procedure CustomersFind(var Ctx: TNativeRequestContext);
var
  LObj: TCustomer;
begin
  LObj := LDAO.FindById(StrToIntDef(Ctx.Param('id'), 0));
  if LObj = nil then
  begin
    Ctx.Status := 404;
    Ctx.Body := TEncoding.UTF8.GetBytes('Not found');
  end
  else
  begin
    Ctx.ContentType := TMimeType.ApplicationJSON;   // 'application/json'
    Ctx.Body := TEncoding.UTF8.GetBytes(LObj.ToJSON);
  end;
end;

// registration
var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.Get('/customers/:id', CustomersFind);
    App.Listen(9000);
  finally
    App.Free;
  end;
end;
```

### API mapping

| v1 — Horse | v2 — native | Notes |
|---|---|---|
| `THorse` (global singleton) | `TPoseidonServer` (owned instance) | `Create` it; `Free` it. Multiple instances on distinct ports are allowed. |
| `THorse.Get/Post/Put/Delete/Patch(path, cb)` | `App.Get/Post/Put/Delete/Patch(path, cb)` | Same verbs; also `Head` and `All`. Fluent — each returns `App`. |
| `THorse.Use(mw)` | `App.Use(mw)` | Middleware chain; see the middleware mapping below. |
| `THorse.Listen(9000)` | `App.Listen(9000)` | Blocks until shutdown, same as v1. |
| `procedure(Req; Res)` | `procedure(var Ctx: TNativeRequestContext)` | One fused context by `var`. |
| `procedure(Req; Res; Next)` | `procedure(var Ctx; ANext: TProc)` | Middleware signature. Call `ANext` to continue, omit to short-circuit. |
| `Req.Params['id']` | `Ctx.Param('id')` | Route params. |
| `Req.Query['q']` | `Ctx.Query('q')` | Query string (URL-decoded). |
| `Req.Headers['X']` | `Ctx.Header('X')` | Request headers (case-insensitive). |
| `Req.Body` (string) | `Ctx.RawBody` (`TBytes`) | Inbound body is bytes; decode with `TEncoding.UTF8.GetString`. |
| `Res.Status(code)` | `Ctx.Status := code` | Assign, don't chain. Use `THTTPStatus.*` constants if you like. |
| `Res.ContentType(ct)` | `Ctx.ContentType := ct` | Use `TMimeType.*` constants. |
| `Res.Send(text)` | `Ctx.Body := TEncoding.UTF8.GetBytes(text)` | Outbound body is `TBytes`. |
| `Res.Send(text)` then implicit 200 | `Ctx.Status` defaults to 200 | Set `Ctx.Status` only to override. |
| adding a response header | `Ctx.ExtraHeaders` | Append `TPair<string,string>`. |

### Common gotchas

- **Bodies are `TBytes`, not `string`.** Both `RawBody` (in) and `Body` (out) are
  byte arrays. Wrap with `TEncoding.UTF8.GetBytes` / `GetString`. This is what
  makes the path zero-copy and binary-safe.
- **No fluent `Res`.** Assign `Status`, `ContentType`, `Body` as fields — there
  is no `.Status().Send()` chain.
- **Lifetime is yours.** `TPoseidonServer` is an instance you `Create`/`Free`
  (usually in a `try/finally`), not a process-global singleton.
- **Handlers take `var Ctx`.** The `var` matters — the context is a record passed
  by reference; do not copy it.

### Middleware mapping

Horse third-party middlewares (`HorseCORS`, `Jhonson`, JWT shims, etc.) map to
first-party Poseidon middleware units under `middlewares/`. Add the unit to
`uses` and install with `App.Use(...)`:

| Concern | Poseidon middleware factory |
|---|---|
| CORS | `CORSMiddleware` |
| JWT bearer auth | `JWTMiddleware(secret, ...)` |
| Digest auth | `DigestMiddleware(realm, getHA1)` |
| Security headers (helmet) | `SecurityMiddleware` |
| Rate limiting | `RateLimitMiddleware(max, windowSec)` |
| Access logging | `LoggerMiddleware` / `LoggerMiddlewareJSON` |
| gzip compression | `CompressionMiddleware` |
| Static files | `StaticMiddleware(prefix, root)` |
| Request ID | `RequestIDMiddleware` |
| Health checks | `TPoseidonHealthCheck` builder |
| Metrics (Prometheus) | `MetricsMiddleware` |
| RFC 7807 errors | `ProblemDetailsMiddleware` |
| DTO validation → 422 | `ValidationMiddleware` (+ `Poseidon.Validation` attributes) |

See the full list and signatures in the [API Reference — Middlewares](./API-REFERENCE.md#middlewares).

---

## Suggested migration sequence

1. **Recompile on the compat layer (Path A).** Validate the whole app on the v2
   engine with zero handler changes. Run the suite; deploy to staging.
2. **Soak & benchmark.** Confirm stability and measure your baseline throughput.
3. **Port hot paths to native (Path B).** Rewrite the highest-traffic
   controllers first — that is where the ~15% engine headroom lands.
4. **Adopt native middlewares.** Replace third-party Horse middlewares with the
   first-party equivalents as you port each route group.
5. **Drop the compat shim** once no `THorse` code remains.

Breaking-change summary: the only hard breaks are **request/response fusion**
(`Req`+`Res` → `var Ctx`) and **`TBytes` bodies**. Everything else is a
mechanical rename. The compat layer lets you defer even those until you choose
to port.

---

> 🇧🇷 Leia este documento em português: [MIGRATION_v1_to_v2_pt-br.md](./MIGRATION_v1_to_v2_pt-br.md)
