# Security headers e identidade do servidor

## Headers de segurança nas respostas (A-1)

Quando `SecureHeadersEnabled` é `True`, o Poseidon injeta automaticamente três
headers de segurança em toda resposta HTTP:

| Header | Valor |
|--------|-------|
| `X-Content-Type-Options` | `nosniff` |
| `X-Frame-Options` | `DENY` |
| `Referrer-Policy` | `strict-origin-when-cross-origin` |

```pascal
LServer.SecureHeadersEnabled := True;
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

O padrão é `False` (opt-in). Habilite para qualquer API pública ou aplicação web.

## Banner do servidor (A-2)

O header `Server:` da resposta é `'Poseidon/1.0'` por padrão.
Altere para um valor personalizado ou suprima completamente:

```pascal
LServer.ServerBanner := 'MinhaApp/2.0';  // banner personalizado
// LServer.ServerBanner := '';             // suprime o header Server: inteiramente
```

Suprimir o banner reduz a divulgação de informações a atacantes em potencial.

## Allowlist de verbos HTTP (S-1)

Veja [http1.md](../03-protocolos/http1.md#allowlist-de-verbos-http-s-1).

## mTLS e configuração TLS

Veja [ssl-tls.md](../03-protocolos/ssl-tls.md).

## Proteções embutidas (sempre ativas)

Aplicadas automaticamente independentemente de configuração:

| Proteção | Gatilho | Resposta |
|----------|---------|----------|
| Path traversal | `..`, `%2e%2e`, `\`, NUL no path | `400 Bad Request` |
| Request smuggling | `Content-Length` + `Transfer-Encoding: chunked` | `400 Bad Request` |
| Injeção CRLF | CR/LF/NUL em valores de header de resposta | Removidos silenciosamente |
