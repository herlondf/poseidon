# SSL/TLS + SNI

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

## Notes

- PEM format only (cert + key as separate files).
- Intermediate chain: concatenate into the cert PEM file.
- Call order: `ConfigureSSL` → `AddSSLCert` → `Listen`. Any other order raises `EPoseidonSSL`.
