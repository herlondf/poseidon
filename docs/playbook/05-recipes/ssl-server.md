# HTTPS server with SNI and mTLS

## Basic HTTPS

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## SNI — multiple certificates on one port

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.ConfigureSSL('default.crt', 'default.key');
LServer.AddSSLCert('api.example.com', 'api.crt',  'api.key');
LServer.AddSSLCert('ws.example.com',  'ws.crt',   'ws.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## Enforce TLS 1.2 minimum

```pascal
uses Poseidon.Net.SSL;

LServer := TPoseidonNativeServer.Create;
LServer.MinTLSVersion := TLS1_2_VERSION;  // $0303 — default; change to TLS1_3_VERSION for TLS 1.3 only
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## mTLS — require client certificates

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.ConfigureMTLS('ca-bundle.crt');  // clients without a valid cert are rejected
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

See full project at [`samples/02-ssl-tls/`](../../../samples/02-ssl-tls/).
