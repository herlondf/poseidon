# Limites e backpressure

O Poseidon oferece limites configuráveis que protegem contra esgotamento de recursos
e permitem degradação controlada sob carga.

## Limites de tamanho de requisição (R-4)

```pascal
LServer.MaxRequestSize := 4 * 1024 * 1024;  // 4 MB — 413 se excedido
LServer.MaxHeaderSize  := 32768;             // 32 KB — 400 se excedido
```

Veja [http1.md](../03-protocolos/http1.md#limites-de-tamanho-de-requisição-e-headers-r-4) para detalhes.

## Limites de conexão

```pascal
LServer.MaxConnections      := 10000;  // limite global — socket descartado se excedido
LServer.MaxConnectionsPerIP := 100;    // limite por IP — socket descartado se excedido
```

O padrão é `0` (ilimitado) para ambos. Quando o limite é atingido, o socket entrante
é fechado imediatamente sem resposta HTTP.

## Profundidade de fila / backpressure (R-5)

`MaxQueueDepth` limita o número de requisições sendo processadas simultaneamente.
Quando o limite é atingido, o servidor retorna `503 Service Unavailable` em vez de
enfileirar mais trabalho.

```pascal
LServer.MaxQueueDepth := 500;  // 0 = ilimitado (padrão)
```

Use em conjunto com `WorkerCount`: `MaxQueueDepth` é o portão de aceitação
(caminho rápido), `WorkerCount` é a capacidade de processamento (caminho lento).

## Load shedding por crescimento de in-flight (#237)

`MaxQueueDepth` só reage quando a fila já está completamente cheia — um
teto rígido. Num pico de sobrecarga agudo, esse teto pode ser atingido e
ultrapassado dentro do próprio tempo de processamento de uma requisição,
bem depois da sobrecarga já estar em andamento. `MaxInFlightGrowthPerWindow`
reage mais cedo, ao quão RÁPIDO as requisições em andamento estão se
acumulando, não só a quantas existem agora:

```pascal
LServer.MaxInFlightGrowthPerWindow := 50;  // 0 = desabilitado (padrão)
LServer.LoadSheddingWindowMs       := 1000; // janela de 1s (padrão)
LServer.RetryAfterSeconds          := 1;    // enviado em todo 503 de load shedding (padrão)
```

Se as requisições em andamento crescem mais que `MaxInFlightGrowthPerWindow`
dentro de `LoadSheddingWindowMs`, novas requisições são descartadas com
`503` + `Retry-After: <RetryAfterSeconds>` — a mesma resposta que o teto
rígido do `MaxQueueDepth` já produz (que também ganhou um header
`Retry-After` junto com esta feature; não tinha nenhum antes). As duas
checagens rodam em toda requisição; qualquer uma pode disparar o descarte
sozinha — elas se complementam, não se substituem.

`LoadSheddingWindowMs` é seu próprio timer, deliberadamente não atrelado ao
`HeartbeatMs`/linha de log `[health]`: desabilitar o log de heartbeat não
pode silenciosamente desabilitar o load shedding também.

Isso é uma amostragem best-effort, com corrida por design (a janela
deslizante é lida/resetada via `TInterlocked`, não um lock) — a troca certa
pra uma heurística de load shedding no caminho quente da requisição, onde
precisão perfeita não compra nada que um lock não custasse de volta em
latência. Escolha `MaxInFlightGrowthPerWindow` acima da rajada natural do
seu tráfego normal (observe `poseidon_requests_total` ou suas próprias
métricas pra ter uma base primeiro) — baixo demais, e picos de tráfego
legítimo são descartados; alto demais, e nunca dispara antes do próprio
teto do `MaxQueueDepth` já ter disparado de qualquer jeito.

Isso é opt-in (padrão `0`, desabilitado), mesmo raciocínio do
`MaxHandlerRunMs` e `HeaderTimeoutMs` no resto desta página: deploys
existentes mantêm o comportamento de hoje a menos que seja configurado
explicitamente.

## Rate limiting

Contadores de janela fixa que reiniciam a cada segundo.

```pascal
LServer.RateLimitPerIP    := 100;  // máx 100 req/s por IP cliente — 429 se excedido
LServer.RateLimitGlobal   := 5000; // máx 5000 req/s global — 429 se excedido
LServer.RateLimitResponse := 429;  // padrão; altere para 503 se preferir
```

O padrão é `0` (ilimitado) para ambos os contadores. Os limites por IP e global são
independentes — uma requisição é rejeitada se **qualquer** limite for excedido.

## Tamanho de frame WebSocket (R-3)

```pascal
LServer.MaxWSFrameSize := 1 * 1024 * 1024;  // 1 MB — código WS 1009 se excedido
```

Veja [websocket.md](../03-protocolos/websocket.md#limite-de-tamanho-de-frame-r-3) para detalhes.

## Timeout de conexão ociosa

```pascal
LServer.IdleTimeoutMs := 30000;  // 30 s — padrão 10 000 ms; 0 = desabilitado
```

Conexões sem bytes recebidos por `IdleTimeoutMs` são fechadas.
O timer é reiniciado a cada byte recebido, portanto conexões keep-alive ativas não são afetadas.

## Deadline de conclusão de headers / guarda anti-Slowloris (#254)

`IdleTimeoutMs` reinicia a **cada** byte recebido, incluindo um único byte de
uma requisição ainda incompleta. É exatamente o ataque Slowloris clássico
(2009, contra o Apache): abrir várias conexões e vazar um byte a cada poucos
segundos — nenhuma delas fica ociosa tempo suficiente pra bater o
`IdleTimeoutMs`, então nenhuma é fechada, ao custo de banda quase zero por
conexão.

```pascal
LServer.HeaderTimeoutMs := 10000;  // 0 = desabilitado (padrão)
```

Este é um deadline separado e **absoluto**, medido a partir da abertura da
conexão, não reiniciado por atividade parcial — espelhando o
`client_header_timeout` do nginx. Só se aplica até a primeira requisição da
conexão ter uma linha de requisição + headers completos; a partir daí a
conexão volta a ser governada pelo `IdleTimeoutMs` normalmente pro resto da
sua vida keep-alive. Combine com `MaxConnectionsPerIP` (também `0`/ilimitado
por padrão) pra resistência real a Slowloris — um deadline de header sozinho
ainda deixa um IP segurar várias conexões lentas simultaneamente, só não pra
sempre.

Isso é opt-in (padrão `0`, desabilitado) pelo mesmo motivo do
`MaxHandlerRunMs` abaixo: deploys existentes mantêm o comportamento de hoje a
menos que seja configurado explicitamente.

## Watchdog de handler travado (#233)

Nenhum dos limites acima protege contra um handler genuinamente travado —
bloqueado para sempre numa dependência de saída lenta/sem resposta (um
webservice, um banco), não apenas lento. O `Poseidon.Middleware.Timeout`
também não ajuda aqui: é uma checagem pós-execução (veja
[middlewares](../09-middlewares/README.md#6-timeout)) que só mede o handler
DEPOIS que ele retorna.

```pascal
LServer.MaxHandlerRunMs := 60000;  // 0 = desabilitado (padrão)
```

Quando o handler em andamento de uma conexão está rodando há mais tempo que
`MaxHandlerRunMs`, o idle-sweep loga um aviso e fecha a conexão — o mesmo
padrão de "vazar o recurso em vez de liberar" usado no shutdown (nunca mata a
thread do worker, já que o Delphi não tem forma segura de abortar uma thread
no meio de uma chamada nativa). O worker travado eventualmente termina
sozinho (possivelmente bem depois) e seu `finally` roda normalmente,
liberando sua referência; o cliente só não espera por isso — vê a conexão
cair na hora e pode tentar de novo contra uma conexão/instância nova.

Isso é opt-in (padrão `0`, desabilitado) para que deploys existentes
mantenham o comportamento de hoje a menos que seja configurado
explicitamente. Escolha um valor acima do p99 do seu handler mais lento
legítimo, não da mediana — isso é uma proteção contra ficar travado para
sempre, não um timeout geral de requisição (use `Poseidon.Middleware.Timeout`
ou um timeout explícito no client de saída para isso).

## Tabela resumo

| Propriedade | Padrão | Ação ao exceder |
|-------------|--------|-----------------|
| `MaxRequestSize` | 8 MB | `413` |
| `MaxHeaderSize` | 64 KB | `400` |
| `MaxConnections` | 0 (∞) | socket descartado |
| `MaxConnectionsPerIP` | 0 (∞) | socket descartado |
| `MaxQueueDepth` | 0 (∞) | `503` + `Retry-After` |
| `MaxInFlightGrowthPerWindow` | 0 (desabilitado) | `503` + `Retry-After` |
| `RateLimitPerIP` | 0 (∞) | `429` (ou `RateLimitResponse`) |
| `RateLimitGlobal` | 0 (∞) | `429` (ou `RateLimitResponse`) |
| `MaxWSFrameSize` | 0 (∞) | WS close `1009` |
| `IdleTimeoutMs` | 10 000 ms | conexão fechada |
| `HeaderTimeoutMs` | 0 (desabilitado) | conexão fechada (guarda anti-Slowloris) |
| `MaxHandlerRunMs` | 0 (desabilitado) | conexão fechada (handler vazado, não morto) |
