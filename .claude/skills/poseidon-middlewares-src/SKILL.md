---
name: poseidon-middlewares-src
description: Especialista em IMPLEMENTAR e corrigir middlewares do Poseidon (middlewares/Poseidon.Middleware.*.pas) — BodyLimit, Cache, CircuitBreaker, Compression, CORS, Digest, Guard, HealthCheck, JWT, Logger, Metrics, OpenAPI, ProblemDetails, Proxy, RateLimit, RequestID, Security, Static, Timeout, Validation. Use ao aplicar patches de achados de poseidon-middlewares-review, criar middleware novo, ou ajustar semântica de ANext/Handled e thread-safety do estado capturado. Diferente das skills *-review, aqui você EDITA .pas e prova que compila e passa nos testes. Core em src/ NÃO entra aqui: use poseidon-src.
---

# Implementação de middlewares do Poseidon

Você escreve/corrige middlewares em `middlewares/*.pas`. Fecha o que
`poseidon-middlewares-review` provou. Não audita — implementa e prova.

## Regra de ouro — patch mínimo e provado

1. Mudança fica no middleware apontado. Se precisar tocar `src/`, PARE — isso é
   trabalho de `poseidon-src`.
2. LEIA o `.pas` alvo inteiro + `Poseidon.Native.Types.pas` (o contrato
   `TNativeMiddlewareFunc`, `TNativeRequestContext`) antes de digitar.
3. "Feito" = build Win64 verde + `Poseidon.Tests.exe` sem regressão + colar a
   saída real.

## Modelo de execução (interiorize antes de editar)

Middleware é **factory** que retorna:

```pascal
TNativeMiddlewareFunc = reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

- **Factory** roda 1x (setup, captura de opções, cria containers de estado).
- **Closure** roda a cada requisição, em qualquer worker-thread.
- Estado declarado na factory e capturado pela closure é **compartilhado
  entre todas as conexões** — proteja com lock ou `TInterlocked`.

Contrato de fluxo:
- Seguir cadeia: chamar `ANext()` **exatamente uma vez**.
- Curto-circuitar: setar `ACtx.Handled := True` e retornar (não chame `ANext`).
- Nunca ambos. Nunca nenhum (engole a request).

## Regras do projeto (de CLAUDE.md — obrigatórias)

### Declarações / nomenclatura (idênticas às de src/)
- Sem `var` inline. Sem magic number. Sem alinhamento de tipos.
- Prefixos: `T`/`I`/`E`/`A`/`L`/`F`/`C` (classe/interface/exceção/param/local/campo/const).
- Interface nova → GUID único.

### `uses`
- Uma unit por linha; RTL primeiro, projeto depois. Interface vs implementation
  conforme escopo do símbolo.

### Comentários
- Default = nenhum. Só WHY não óbvio.

## Thread-safety — o risco número 1

Toda closure capturada roda em múltiplas threads sobre o **mesmo** objeto/campo:

- Container (`TDictionary`, `TList`, `TDictionary<string, TCacheEntry>`):
  proteger com `TMonitor.Enter/Exit` ou `TCriticalSection`. Ler-modificar-gravar
  atômico ou dentro do lock.
- Contador (`Integer`/`Int64`): usar `TInterlocked.Increment/Decrement/Add`.
  Nunca `Inc(FCounter)` em campo compartilhado. Lembre-se: `TInterlocked.Read`
  só existe para `Int64`.
- Timestamp/expiração: capturar `TThread.GetTickCount64` **uma vez** por
  operação; não chamar `Now` duas vezes numa mesma transição de estado.
- Eviction/purge concorrente com insert: proteger fila de vítimas e nunca
  liberar valor enquanto outra thread pode segurar referência.

## Semântica de ANext/Handled — armadilhas comuns

- `try ANext() except ... end` só faz sentido se o handler não engole a
  exceção silenciosa. Sempre relance ou converta em resposta explícita.
- `try ... finally decrementar contador end` — se o contador foi incrementado
  antes de `ANext`, o `finally` DEVE decrementar (senão vaza sob exceção).
- Timeout que dispara depois do handler completar: cuidado com escrita dupla.
  Use flag atômica de "resposta enviada".

## Segurança — checklist por middleware sensível

- **RateLimit / Logger / Proxy / RequestID**: chave/log baseado em IP DEVE vir
  de `RemoteAddr` — só use `X-Forwarded-For` atrás de proxy explicitamente
  confiável (allowlist). XFF é cliente-controlado.
- **JWT**: fixar algoritmo esperado (rejeitar `alg:none` e confusão HS/RS);
  validar `exp`/`nbf`/`iss`/`aud`; comparação de assinatura em tempo constante
  (`CompareMem` de tempo constante — nunca `=` de string). Falha → `Handled` +
  401, nunca segue a cadeia.
- **Digest**: nonce único e expirável; anti-replay; comparação constante.
- **Guard**: `IsIPInCIDR` de `Poseidon.Net.Security.pas` — herda comportamento
  dessa unit. Se ela é fail-open em octeto >255, seu Guard fica fail-open.
  Não corrija dentro do middleware; corrija na unit (via `poseidon-src`) e
  atualize o middleware para o novo contrato.
- **Static**: canonicalizar caminho ANTES de checar prefixo do root
  (`GetFullPath` + `StartsWith(root + PathSep)`). Sem canonicalização, `..`
  passa.
- **BodyLimit**: rejeitar ANTES de qualquer cópia cara. 413 + `Handled`.
- **CORS**: `AllowCredentials = true` + `AllowOrigin = "*"` é proibido pela
  spec (validar na factory, ainda no setup — não a cada request).
- **Security (headers)**: valores não podem conter CRLF (response splitting).
  Sanitizar entrada do config.

## Correção por middleware — pontos comuns

- **Cache**: chave inclui método + path + valores de `Vary`; não cacheia
  resposta com Set-Cookie ou `Cache-Control: private/no-store`; body copiado,
  não referenciado (o buffer volta ao pool).
- **CircuitBreaker**: transições closed → open → half-open com contador atômico.
  Janela de tempo com uma única leitura de `GetTickCount64` por decisão.
- **Compression**: ver `poseidon-compression-review` — não recomprimir corpo já
  comprimido, respeitar `Vary: Accept-Encoding`, pular 204/304.
- **Metrics / HealthCheck / OpenAPI**: rota reservada não deve colidir com
  rotas do app; conteúdo gerado não pode injetar do input do cliente.
- **Timeout**: cancelar o handler, não só medir. Se cancelar não for possível,
  ao menos evitar segunda escrita da resposta.

## Fluxo obrigatório ao aplicar patch/criar middleware

1. **Ler** o achado + o `.pas` alvo inteiro + `Poseidon.Native.Types.pas` +
   qualquer unit de `src/` cujo símbolo aparece na mudança.
2. **Editar** — `Edit` preferível a `Write`. Preservar indentação (2 espaços) e
   BOM UTF-8 se existir.
3. **Registrar** — se criou middleware novo, adicionar no `.dpr`/`.dproj` do
   consumidor (samples/tests) que o exercita. Sem caminho absoluto de máquina
   commitado.
4. **Verificar** (obrigatório):
   - Build do projeto que consome middlewares (samples/tests). Se seu middleware
     é standalone, ao menos `dcc64` da própria unit compilando com search path
     `..\src`.
   - Suíte DUnitX: `tests/build_tests.bat` + `Poseidon.Tests.exe`. Cole
     `Tests Found / Passed / Failed`.
   - Se o middleware tem estado compartilhado, procure/adicione teste em
     `Poseidon.Tests.Middleware.<Nome>.pas` — se ausente, delegue a
     `poseidon-tests` para escrever antes de considerar feito.
5. **Reportar** — arquivo:linha alterado, motivo em 1 frase, saída do teste.

## Mapa dos middlewares

`middlewares/Poseidon.Middleware.<Nome>.pas` — Nome ∈ { BodyLimit, Cache,
CircuitBreaker, Compression, CORS, Digest, Guard, HealthCheck, JWT, Logger,
Metrics, OpenAPI, ProblemDetails, Proxy, RateLimit, RequestID, Security,
Static, Timeout, Validation }.

## Antipadrões (rejeitar antes de commitar)
- Ler-modificar-gravar de container sem lock ("é rápido, é só um Add").
- `Inc(FCounter)` em campo compartilhado.
- Comparação de assinatura JWT/Digest com `=` de string.
- `ANext()` chamado duas vezes em caminhos diferentes de um `if`.
- Middleware que faz I/O bloqueante longo (banco, HTTP externo) sem timeout —
  segura a worker-thread.
- Copiar GUID de outra interface ao criar uma nova.

## Não faça
- Não edite `src/` aqui — use `poseidon-src`.
- Não escreva teste aqui — use `poseidon-tests`.
- Não revise aqui — use `poseidon-middlewares-review`.
- Não crie middleware "genérico configurável" quando dois casos concretos
  bastariam separados.
- Não declare verde sem colar a saída do runner.
