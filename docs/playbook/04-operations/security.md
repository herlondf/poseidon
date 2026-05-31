# Security headers & server identity

## Secure response headers (A-1)

When `SecureHeadersEnabled` is `True`, Poseidon automatically injects three
security headers into every HTTP response:

| Header | Value |
|--------|-------|
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `DENY` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |

```pascal
LServer.SecureHeadersEnabled := True;
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

Default is `False` (opt-in). Enable for any public-facing API or web application.

## Server banner (A-2)

The `Server:` response header is set to `'Poseidon/1.0'` by default.
Change it to a custom value or suppress it entirely:

```pascal
LServer.ServerBanner := 'MyApp/2.0';  // custom banner
// LServer.ServerBanner := '';          // suppress Server: header entirely
```

Suppressing the banner reduces information disclosure to potential attackers.

## HTTP verb allowlist (S-1)

See [http1.md](../03-protocols/http1.md#http-verb-allowlist-s-1).

## mTLS and TLS configuration

See [ssl-tls.md](../03-protocols/ssl-tls.md).

## Built-in protections (always active)

These are applied automatically regardless of configuration:

| Protection | Trigger | Response |
|------------|---------|----------|
| Path traversal | `..`, `%2e%2e`, `\`, NUL in path | `400 Bad Request` |
| Request smuggling | `Content-Length` + `Transfer-Encoding: chunked` | `400 Bad Request` |
| CRLF injection | CR/LF/NUL in response header values | Stripped silently |
