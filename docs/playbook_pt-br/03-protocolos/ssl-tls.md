# SSL/TLS + SNI + mTLS

O Poseidon usa OpenSSL via bindings diretos em `Poseidon.Net.SSL`.
`libssl` e `libcrypto` devem estar no PATH (ou na mesma pasta do binário).

## Configuração básica de HTTPS

```pascal
LServer := TPoseidonNativeServer.Create;
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

## Versão mínima de TLS (S-6)

Defina `MinTLSVersion` antes de `ConfigureSSL` para impor um piso na versão TLS.
Use as constantes de `Poseidon.Net.SSL`:

```pascal
uses Poseidon.Net.SSL;

LServer.MinTLSVersion := TLS1_2_VERSION;  // $0303 — padrão, TLS 1.2
// LServer.MinTLSVersion := TLS1_3_VERSION;  // $0304 — apenas TLS 1.3
// LServer.MinTLSVersion := 0;               // padrão da lib (OpenSSL 3.x: TLS 1.2)
LServer.ConfigureSSL('cert.pem', 'key.pem');
```

Clientes que tentarem conectar com versão inferior são rejeitados no handshake TLS.

## mTLS — TLS mútuo / certificados de cliente (S-5)

Chame `ConfigureMTLS` após `ConfigureSSL` e antes de `Listen`.
O servidor exigirá um certificado de cliente assinado pelo CA bundle informado.

```pascal
LServer.ConfigureSSL('server.crt', 'server.key');
LServer.ConfigureMTLS('ca-bundle.crt');   // arquivo PEM com um ou mais certs CA
LServer.Listen('0.0.0.0', 443, @HandleRequest, nil);
```

Clientes sem certificado válido são rejeitados na camada TLS (antes de qualquer
processamento HTTP). O certificado do cliente não é encaminhado ao handler de
requisição — use mTLS apenas para autenticação em nível de transporte.

## Cache de sessão TLS (A-4)

O cache de sessão é habilitado automaticamente em `ConfigureSSL` (até 1024 sessões).
Clientes que reconectam reutilizam a sessão TLS, pulando o handshake completo e
economizando ~1 RTT. Nenhum código de aplicação é necessário para ativar isso.

## Observações

- Apenas formato PEM (cert + chave em arquivos separados).
- Cadeia intermediária: concatenar no arquivo PEM do certificado.
- Ordem obrigatória: `ConfigureSSL` → `AddSSLCert` → `ConfigureMTLS` → `Listen`. Outra ordem lança `EPoseidonSSL`.
- `MinTLSVersion` deve ser definido antes de `ConfigureSSL` (é aplicado durante a criação do contexto).
