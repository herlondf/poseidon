# HTTP/1.1 — Segurança e Limites

O Poseidon aplica automaticamente diversas medidas de proteção HTTP/1.1 e expõe
propriedades para configurar limites de tamanho e restrições de verbos.

## Allowlist de verbos HTTP (S-1)

Por padrão todos os métodos HTTP são aceitos. Restrinja a uma allowlist explícita
via `AllowedMethods`. Requisições com verbos não listados recebem `405 Method Not Allowed`.

```pascal
LServer.AllowedMethods := ['GET', 'POST', 'HEAD', 'OPTIONS'];
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

Definir `AllowedMethods` como array vazio (padrão) aceita todos os métodos.

## Limites de tamanho de requisição e headers (R-4)

```pascal
LServer.MaxRequestSize := 4 * 1024 * 1024;  // 4 MB — retorna 413 se excedido
LServer.MaxHeaderSize  :=      32768;         // 32 KB — retorna 400 se excedido
```

| Propriedade | Padrão | Resposta ao exceder |
|-------------|--------|---------------------|
| `MaxRequestSize` | 8 388 608 (8 MB) | `413 Request Entity Too Large` |
| `MaxHeaderSize` | 65 536 (64 KB) | `400 Bad Request` |

Ambos os limites são verificados incrementalmente à medida que os bytes chegam —
conexões com excesso de tamanho são rejeitadas antes de bufferizar o payload completo.

## Proteção contra path traversal (S-2)

Os paths são validados automaticamente por `IsPathSafe` de `Poseidon.Net.Security`
antes de chamar o handler da requisição. Os seguintes padrões são rejeitados com
`400 Bad Request`:

| Padrão | Exemplo | Motivo |
|--------|---------|--------|
| Segmento `..` | `/files/../etc/passwd` | Traversal de diretório |
| `%2e%2e` (URL-encoded) | `/files/%2e%2e/etc/passwd` | Traversal encodado |
| Barra invertida | `/files\secret` | Traversal estilo Windows |
| Byte NUL | `/files/nome%00.txt` | Injeção NUL |

## Detecção de request smuggling (S-4)

Quando uma requisição contém `Content-Length` e `Transfer-Encoding: chunked` ao mesmo tempo,
o Poseidon a rejeita com `400 Bad Request` conforme RFC 7230 §3.3.3. Isso previne
ataques de HTTP request smuggling em ambientes com reverse-proxy.

## Remoção de CRLF (S-3)

Valores de header de resposta fornecidos pelo handler da aplicação são automaticamente
despidos de CR (`\r`), LF (`\n`) e caracteres NUL antes de serem escritos na rede.
Isso previne injeção de headers via valores controlados pelo usuário.

A remoção é transparente — nenhuma mudança de código no handler é necessária.
