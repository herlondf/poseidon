---
name: poseidon-security-src
description: Especialista em IMPLEMENTAR e corrigir segurança do Poseidon — Poseidon.Net.Security (IsIPInCIDR, IsPathSafe, comparações de tempo constante), Poseidon.Net.ProxyProtocol (v1/v2 parsing, allowlist), Poseidon.Net.SSL + SSL.Manager (TLS/mTLS, ALPN, handshake). Use ao aplicar patches de poseidon-security-review (CIDR fail-open em octeto >255, Proxy Protocol sem allowlist = IP spoof, TLS handshake sob DoS) ou adicionar defesa contra request smuggling/response splitting. Herda regras de poseidon-src.
---

# Implementação de segurança — invariantes e vetores

Escopo: `src/Poseidon.Net.Security.pas`, `src/Poseidon.Net.ProxyProtocol.pas`,
`src/Poseidon.Net.SSL.pas`, `src/Poseidon.Net.SSL.Manager.pas`. Regras gerais
em `poseidon-src`.

## Regra dura — falhar CLOSED, não OPEN

Toda decisão de segurança que recebe input inválido DEVE negar acesso, não
permitir. Se em dúvida sobre o input:
- Input malformado → rejeita.
- Erro de parse → rejeita.
- Estado inconsistente → rejeita.

Fail-open é bug crítico. `IsIPInCIDR` retornando `True` em octeto >255 (bug
ativo do review) = allowlist virou allowany.

## IsIPInCIDR / IsIPv4 / IsIPv6

- Parse de cada octeto: `StrToInt` sem checagem → excede 255 silenciosamente.
  Regra: se octeto > 255, RETORNAR FALSE (negar), não True.
- CIDR `/N`: 0 ≤ N ≤ 32 (v4) / 128 (v6). Fora → False.
- Máscara: aplicar como bitmask após validação, nunca antes.

## IsPathSafe (Static / path traversal)

- Canonicalizar caminho ANTES de checar prefixo (`GetFullPath` / realpath).
- Comparar com root usando separador final (`root + PathSep`) — sem, `/foo`
  matcha `/foobar`.
- Rejeitar sequências absolute (`C:\...` no Windows, `//` no Linux) mesmo
  após canonicalização se root não é absoluto.
- Rejeitar bytes null, `%00`, e caracteres de controle.

## Comparação em tempo constante

Assinaturas de JWT/Digest, tokens, hashes: NUNCA `=` de string (short-circuits
no primeiro byte diferente — timing attack).
- Use `CompareMem` de tempo constante (implementar se não existir): OR de
  todos os bytes, retorna == 0.
- Aplicar em: HMAC, HKDF, comparação de token, nonces.

## ProxyProtocol (v1/v2)

- Parser rígido: v1 texto, v2 binário. Rejeitar magic bytes errados.
- **Allowlist de origem OBRIGATÓRIA**: só aceitar Proxy Protocol de peers
  com IP em allowlist configurada. Sem allowlist, cliente qualquer manda
  header e spoof do IP real vira trivial.
- Overflow de comprimento em v2: campo `len` unsigned; validar contra
  máximo antes de alocar.
- IPv6 e Unix sockets: v2 os suporta. Cada família tem tamanho fixo — valide.

## SSL / SSL.Manager

- Handshake em thread dedicada ou não-bloqueante. Cliente lento não pode
  ocupar worker por 30 segundos.
- SNI: extrair server_name do ClientHello, escolher cert. Cert default para
  clientes sem SNI (opcional — pode recusar).
- ALPN: negociar `h2`/`http/1.1`. Retornar erro se cliente ofereceu vazio.
- mTLS: validar cert do cliente contra CA configurada. Falha = fechar
  conexão (não seguir para HTTP).
- Session resumption: seguro por padrão (não permitir renegotiation
  attacker-initiated).
- Teardown: `SSL_shutdown` bidirecional antes de `close(fd)` — evita
  truncation attack detectável.

## Response splitting (transversal — mora no ResponseBuilder)

Ver `poseidon-http1-src`. Aqui: qualquer helper de segurança que gere
header/token DEVE não permitir CR/LF no valor. Rejeitar em `SetHeader` no
context, não confiar no builder.

## Request smuggling

Prevenção mora no parser (`poseidon-http1-src`) e no HPACK/pseudo-headers
(`poseidon-http2-src`). Aqui: se você adicionar validação de header
canônico, seja rigoroso — CL+TE = 400, TE não-chunked no final = 400.

## Bugs típicos

- `StrToInt(octeto)` sem try/except → EConvertError vazando OU >255 aceito.
- CIDR `/33` (v4) aceito silenciosamente.
- `IsPathSafe` comparando com root sem separador (`/foo` matcha `/foobar/x`).
- ProxyProtocol sem allowlist = spoof aberto.
- Comparação de token via `=` de string.
- SSL handshake em worker principal → cliente lento consome slot.

## Fluxo obrigatório de teste

Além do padrão de `poseidon-src`:
- Teste unitário para toda decisão binária de segurança (IsIPInCIDR,
  IsPathSafe): incluir caso de octeto >255, CIDR inválido, path com `..`,
  path com null byte. Ver `poseidon-tests`.
- Nunca declarar seguro sem o caso adversário no teste.

## Arquivos no escopo

`src/Poseidon.Net.Security.pas`, `src/Poseidon.Net.ProxyProtocol.pas`,
`src/Poseidon.Net.SSL.pas`, `src/Poseidon.Net.SSL.Manager.pas`.

Cross-skill: Guard/Static/JWT/Digest usam estas primitivas →
`poseidon-middlewares-src`. Response splitting no builder →
`poseidon-http1-src`. Smuggling no parser → mesmo. ALPN → `poseidon-http2-src`.
