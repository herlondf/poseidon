---
name: poseidon-middlewares-review
description: Revisão focada dos middlewares do Poseidon (middlewares/Poseidon.Middleware.*) — o especialista da cadeia de middleware. Cobre BodyLimit, CORS, Cache, CircuitBreaker, Compression, Digest, Guard, HealthCheck, JWT, Logger, Metrics, OpenAPI, ProblemDetails, Proxy, RateLimit, RequestID, Security, Static, Timeout e Validation. Use ao auditar a semântica de ANext()/Handled, thread-safety de estado compartilhado entre requisições (tabelas de rate-limit/cache/circuit-breaker), decisões de segurança (JWT, Guard, Static/path traversal, RateLimit via XFF) e composição/ordem da cadeia. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão dos middlewares do Poseidon

Escopo: `middlewares/Poseidon.Middleware.*.pas` (20 middlewares). Aplique a Regra
de Ouro de `poseidon-review`: só reporte o que puder PROVAR (cenário + linha).

## Modelo de execução (leia antes de opinar)

Um middleware é uma **factory** que retorna
`TNativeMiddlewareFunc = reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc)`.
A factory roda UMA vez (setup, captura de opções); a closure roda a CADA
requisição. Estado declarado na factory e capturado pela closure é
**compartilhado por todas as conexões/threads** — tabelas de rate-limit, cache,
circuit-breaker, contadores de métricas vivem aí.

Contrato: o middleware chama `ANext()` para seguir a cadeia, ou seta
`ACtx.Handled := True` e retorna para curto-circuitar (ex.: CORS preflight →
204). `ACtx` é passado por `var` e mutado no lugar.

## O que caçar (transversal a todos)

### Thread-safety do estado compartilhado (o maior risco)
As closures rodam concorrentemente em várias worker-threads sobre o MESMO objeto
capturado. Para CADA middleware com estado (RateLimit `LTable`, Cache, Metrics,
CircuitBreaker, Digest nonce store):
- O container (`TDictionary`/`TList`) é acessado sem `TMonitor`/`TCriticalSection`?
  → corrida de dados: corrupção de bucket/hash, `EListError`, leitura suja.
  PROVE apontando o campo e duas requisições concorrentes que o tocam.
- Read-modify-write de contador sem `TInterlocked` → contagem perdida (rate limit
  frouxo, métrica errada).
- Eviction/expiração concorrente com inserção → use-after-free do valor.

### Semântica de ANext/Handled
- Todo caminho ou chama `ANext()` uma vez OU seta `Handled` e sai. Chamar
  `ANext()` DUAS vezes re-executa o resto da cadeia. Não chamar nem marcar
  `Handled` "engole" a requisição (pendura/404 espúrio).
- Middleware que envolve `ANext()` em `try/except` (Timeout, CircuitBreaker,
  ProblemDetails): exceção do handler tratada, mas o estado (semáforo, contador
  de concorrência) é revertido no `finally`? Timeout que não cancela o handler
  de fato só mede, não protege.

### Segurança (cruze com poseidon-security-review)
- **RateLimit / RequestID / Logger / Proxy**: confiam em `X-Forwarded-For` sem
  gate de proxy confiável? XFF é controlado pelo cliente → bypass de rate limit e
  spoof de IP em log. Chave do bucket deve ser `RemoteAddr` salvo atrás de proxy
  confiável.
- **JWT**: verificação de assinatura (algоритмo fixado — rejeitar `alg:none` e
  confusão HS/RS), validação de `exp`/`nbf`/`iss`/`aud`, e comparação de assinatura
  em tempo constante. `Handled:=True` + 401 no fail, nunca segue a cadeia.
- **Digest**: nonce único, expiração, replay; comparação constante.
- **Guard**: usa `IsIPInCIDR`/allowlist — herda o fail-open de octeto inválido
  (ver Security.pas). Confirme fail-close.
- **Static**: `IsPathSafe` ANTES de montar o path + canonicalização
  (`GetFullPath` + `StartsWith(root)` com separador final). Já auditado como
  correto — confirme que continua.
- **BodyLimit**: aplica o limite antes de qualquer cópia cara; 413 + `Handled`.
- **Security (headers)**: seta headers sem CRLF; não sobrescreve indevidamente.
- **CORS**: reflexão de `Origin` com credenciais (`AllowCredentials=true` +
  `AllowOrigin:*` é combinação proibida pela spec do navegador — verifique).
- **Proxy** (reverse proxy): repasse de headers hop-by-hop, `Host`, e SSRF se o
  upstream deriva de input.

### Correção / DX por middleware
- **Cache**: chave inclui método+path+Vary; não cacheia resposta de erro/privada;
  não serve corpo obsoleto após expiração. Cópia vs referência do `Body`.
- **CircuitBreaker**: transições closed→open→half-open corretas; contadores
  atômicos; janela de tempo (sem `Now` chamado de forma inconsistente).
- **Metrics/HealthCheck/OpenAPI**: rota reservada não colide com rotas do app;
  não vaza infos sensíveis; geração de doc não injeta a partir de input.
- **Compression**: ver `poseidon-compression-review` (Content-Length, 204/304,
  Vary, não recomprimir).
- **Timeout**: o que acontece com o handler que continua após o timeout — a
  resposta é escrita duas vezes? Race entre timeout e conclusão.

## Não reporte sem provar
Uma "corrida na tabela" só é bug se você nomear o container, mostrar que não há
lock, e descrever duas requisições concorrentes que o corrompem. Um "bypass de
JWT" exige o token/alg concreto que passa. Prefira descartar a inflar.
