# HTTP/1.1 — Security and Limits

Poseidon applies several HTTP/1.1 hardening measures automatically and exposes
properties to configure size limits and verb restrictions.

## HTTP verb allowlist (S-1)

By default every HTTP method is accepted. Restrict to an explicit allowlist via
`AllowedMethods`. Requests with unlisted verbs receive `405 Method Not Allowed`.

```pascal
LServer.AllowedMethods := ['GET', 'POST', 'HEAD', 'OPTIONS'];
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

Setting `AllowedMethods` to an empty array (the default) accepts all methods.

## Request and header size limits (R-4)

```pascal
LServer.MaxRequestSize := 4 * 1024 * 1024;  // 4 MB body+headers limit — returns 413
LServer.MaxHeaderSize  :=      32768;         // 32 KB header section — returns 400
```

| Property | Default | Response on exceed |
|----------|---------|-------------------|
| `MaxRequestSize` | 8 388 608 (8 MB) | `413 Request Entity Too Large` |
| `MaxHeaderSize` | 65 536 (64 KB) | `400 Bad Request` |

Both limits are checked incrementally as bytes arrive — oversized connections are
rejected before the full payload is buffered.

## Path traversal protection (S-2)

Paths are validated automatically against `IsPathSafe` from `Poseidon.Net.Security`
before the request handler is called. The following patterns are rejected with
`400 Bad Request`:

| Pattern | Example | Reason |
|---------|---------|--------|
| `..` segment | `/files/../etc/passwd` | Directory traversal |
| `%2e%2e` (URL-encoded) | `/files/%2e%2e/etc/passwd` | Encoded traversal |
| Backslash | `/files\secret` | Windows-style traversal |
| NUL byte | `/files/name%00.txt` | NUL injection |

## Request smuggling detection (S-4)

When a request contains both `Content-Length` and `Transfer-Encoding: chunked`,
Poseidon rejects it with `400 Bad Request` per RFC 7230 §3.3.3. This prevents
HTTP request smuggling attacks on reverse-proxy setups.

## CRLF stripping (S-3)

Response header values provided by the application handler are automatically
stripped of CR (`\r`), LF (`\n`) and NUL characters before being written to the
wire. This prevents header injection via user-controlled values.

The stripping is transparent — no code changes are needed in the handler.
