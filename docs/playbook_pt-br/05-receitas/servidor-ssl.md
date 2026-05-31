# Servidor HTTPS com SNI e mTLS

## HTTPS básico

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## SNI — múltiplos certificados em uma porta

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.ConfigureSSL('default.crt', 'default.key');
LServer.AddSSLCert('api.example.com', 'api.crt',  'api.key');
LServer.AddSSLCert('ws.example.com',  'ws.crt',   'ws.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## Impor TLS 1.2 como versão mínima

```pascal
uses Poseidon.Net.SSL;

LServer := TPoseidonNativeServer.Create;
LServer.MinTLSVersion := TLS1_2_VERSION;  // $0303 — padrão; use TLS1_3_VERSION para TLS 1.3 apenas
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## mTLS — exigir certificados de cliente

```pascal
LServer := TPoseidonNativeServer.Create;
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.ConfigureMTLS('ca-bundle.crt');  // clientes sem cert válido são rejeitados
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

Veja o projeto completo em [`samples/02-ssl-tls/`](../../../samples/02-ssl-tls/).
