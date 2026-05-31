# HTTP/2 Cleartext Upgrade (h2c)

Poseidon supports the HTTP/1.1 → HTTP/2 upgrade mechanism defined in RFC 7540 §3.2,
allowing clients to switch to HTTP/2 on a plain (non-TLS) connection.

## How it works

1. Client sends an HTTP/1.1 request with:
   ```
   Upgrade: h2c
   Connection: Upgrade, HTTP2-Settings
   HTTP2-Settings: <base64url-encoded SETTINGS payload>
   ```
2. Poseidon detects the `Upgrade: h2c` header on a plain connection.
3. Poseidon responds:
   ```
   HTTP/1.1 101 Switching Protocols
   Connection: Upgrade
   Upgrade: h2c
   ```
4. The original request is replayed as HTTP/2 stream 1.
5. All subsequent frames on the connection use the binary HTTP/2 framing.

## Enabling h2c

h2c is enabled automatically when:
- `TPoseidonNativeServer.H2Enabled` is `True` (the default); and
- The connection has no TLS (`SSLHandle = nil`).

No additional configuration is needed.

## Enabling HTTP/2 on the server

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.H2Enabled := True;   // enables both ALPN h2 (TLS) and h2c upgrade (plain)
LServer.Listen('0.0.0.0', 8080, HandleRequest);
```

## Difference from ALPN h2

| | ALPN h2 | h2c upgrade |
|-|---------|-------------|
| Transport | TLS only | Plain TCP |
| Negotiation | TLS extension | HTTP/1.1 Upgrade header |
| First request | New HTTP/2 request | Carried as stream 1 |
| Browser support | Universal | Limited (most browsers require TLS for h2) |

## Notes

- The `HTTP2-Settings` header is accepted but its value is not applied — Poseidon
  uses its own configured SETTINGS values.
- h2c upgrade is only triggered on plain connections. TLS connections always use
  ALPN negotiation.
- After the 101 response, the connection is exclusively HTTP/2; HTTP/1.1 is no
  longer valid on that socket.
