# SSL/TLS + SNI + mTLS

Poseidon uses OpenSSL via direct bindings in `Poseidon.Net.SSL`.
`libssl` and `libcrypto` must be in PATH (or the same directory as the binary).

## Basic HTTPS setup

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.ConfigureSSL('cert.pem', 'key.pem');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## SNI — multiple certificates

Register additional certs **after** `ConfigureSSL`, **before** `Listen`:

```pascal
LServer.ConfigureSSL('default.crt', 'default.key');       // fallback cert
LServer.AddSSLCert('api.example.com', 'api.crt', 'api.key');
LServer.AddSSLCert('ws.example.com',  'ws.crt',  'ws.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

The TLS handshake selects the certificate whose hostname matches the client SNI extension.
Clients with no SNI (or an unrecognised hostname) receive the default cert.

## Minimum TLS version (S-6)

Set `MinTLSVersion` before `ConfigureSSL` to enforce a floor on the TLS version.
Use the constants from `Poseidon.Net.SSL`:

```pascal
uses Poseidon.Net.SSL;

LServer.MinTLSVersion := TLS1_2_VERSION;  // $0303 — default, TLS 1.2
// LServer.MinTLSVersion := TLS1_3_VERSION;  // $0304 — TLS 1.3 only
// LServer.MinTLSVersion := 0;               // library default (OpenSSL 3.x: TLS 1.2)
LServer.ConfigureSSL('cert.pem', 'key.pem');
```

Clients attempting to connect with a lower version are rejected by the TLS handshake.

## mTLS — mutual TLS / client certificates (S-5)

Call `ConfigureMTLS` after `ConfigureSSL` and before `Listen`.
The server will require a client certificate signed by the given CA bundle.

```pascal
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.ConfigureMTLS('ca-bundle.crt');   // PEM file with one or more CA certs
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

Clients that do not present a valid certificate are rejected at the TLS layer (before any
HTTP request is processed). The client certificate is not currently forwarded to the request
handler — use mTLS for transport-level authentication only.

## TLS session cache (A-4)

Session resumption is enabled automatically on `ConfigureSSL` (up to 1024 cached sessions).
Reconnecting clients reuse the TLS session, skipping the full handshake and saving ~1 RTT.
No application code is needed to activate this.

## Notes

- PEM format only (cert + key as separate files).
- Intermediate chain: concatenate into the cert PEM file.
- Call order: `ConfigureSSL` → `AddSSLCert` → `ConfigureMTLS` → `Listen`. Any other order raises `EPoseidonSSL`.
- `MinTLSVersion` must be set before `ConfigureSSL` (it is applied during context creation).
