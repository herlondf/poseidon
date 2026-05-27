# SSL/TLS + SNI

O AsyncIO usa OpenSSL via bindings diretos em `AsyncIO.Net.SSL`.
`libssl` e `libcrypto` devem estar no PATH (ou na mesma pasta do binário).

## Configuração básica de HTTPS

```pascal
LServer := TAsyncIONativeServer.Create;
LServer.ConfigureSSL('cert.pem', 'key.pem');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

## SNI — múltiplos certificados

Registre certificados adicionais **após** `ConfigureSSL`, **antes** de `Listen`:

```pascal
LServer.ConfigureSSL('default.crt', 'default.key');       // cert fallback
LServer.AddSSLCert('api.example.com', 'api.crt', 'api.key');
LServer.AddSSLCert('ws.example.com',  'ws.crt',  'ws.key');
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

O handshake TLS seleciona o certificado cujo hostname corresponde à extensão SNI do cliente.
Clientes sem SNI (ou hostname não reconhecido) recebem o cert padrão.

## Observações

- Apenas formato PEM (cert + chave em arquivos separados).
- Cadeia intermediária: concatenar no arquivo PEM do certificado.
- Ordem obrigatória: `ConfigureSSL` → `AddSSLCert` → `Listen`. Outra ordem lança `EAsyncIOSSL`.
