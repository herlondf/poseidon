---
name: poseidon-security-review
description: Revisão de segurança do Poseidon — request smuggling, response splitting, path traversal, spoofing via Proxy Protocol, allowlist de IP/CIDR, TLS/mTLS e defesas contra DoS. Use ao auditar qualquer superfície exposta a entrada não confiável (parser, headers de resposta, roteamento para arquivos, Proxy Protocol, TLS) ou limites de recurso. Segue a Regra de Ouro de poseidon-review (só reporte o que provar — e, para segurança, descreva o vetor de ataque concreto).
---

# Revisão de segurança do Poseidon

Escopo: `Poseidon.Net.Security.pas`, `Poseidon.Net.HTTP1.Parser.pas`,
`Poseidon.Net.ResponseBuilder.pas`, `Poseidon.Net.ProxyProtocol.pas`,
`Poseidon.Net.SSL*.pas`, `Poseidon.Net.HttpServer.pas` (backpressure/limites),
`middlewares/*` que tocam auth/CORS/static. Aplique a Regra de Ouro de
`poseidon-review`: para cada achado, descreva o VETOR DE ATAQUE concreto.

## O que caçar

### Request smuggling (RFC 7230 §3.3.3)
- CL.TE / TE.CL / CL.CL (Content-Length duplicado divergente) / TE.TE
  (Transfer-Encoding obscurecido: `chunked` com casing/espaço/valor extra).
- Espaço antes do `:` no nome do header; obs-fold; TE cujo coding final ≠
  `chunked`. O parser deve REJEITAR (400), não normalizar silenciosamente.
- Desync via chunked mal-terminado (trailer/terminador) que deixa bytes
  residuais para a próxima requisição pipelined.

### Response splitting / injeção de header
- Valor E NOME de headers de resposta controlados pela app sanitizados
  (CR/LF/NUL). Um nome não sanitizado permite injetar `Set-Cookie` etc.

### Path traversal
- `IsPathSafe` cobre `..`, `%2e%2e`, `%2e.`, `.%2e`, `\`, `%5c`, `%00`, NUL.
  Onde há acesso a arquivo (middleware Static), a validação é aplicada ANTES de
  montar o caminho, e há defesa em profundidade (canonical `StartsWith(root)`).

### Proxy Protocol / spoofing de IP
- PP só deve ser aceito de fontes confiáveis; aceitar PP de fonte não confiável
  permite spoof de `RemoteAddr`. v1/v2 parse: limites de tamanho, incompleto vs
  inválido, consumo correto do header.

### Allowlist de IP / CIDR
- `IsIPInCIDR`: fail-open vs fail-closed. Entrada não-IPv4/ IPv6 deve fail-CLOSE
  contra CIDR IPv4 (senão um peer IPv6 burla uma allowlist IPv4). Máscara/prefix
  corretos; octetos > 255; strip de porta.

### TLS / mTLS
- Verificação de cadeia/CA ligada quando mTLS exigido; versão mínima aplicada;
  SNI; sem bypass silencioso em erro de handshake; liberação de handle/BIO na
  ordem certa (sem uso após free).

### DoS / limites
- Tamanho máx de request/header/body aplicado (413); contagem de headers;
  backpressure (503 + fechar) quando `InFlightCount ≥ MaxQueueDepth`; slowloris
  (idle timeout); OOM ao alocar corpo/frame antes de validar o tamanho;
  HPACK/CONTINUATION/RST flood (ver poseidon-http2-review).

## Não reporte sem provar
Um achado de segurança sem vetor de ataque concreto e reproduzível não é um
achado — é uma suspeita. Se um limite JÁ é aplicado em outro ponto do fluxo,
não é bug. Confirme lendo o fonte do caminho inteiro, não uma função isolada.
