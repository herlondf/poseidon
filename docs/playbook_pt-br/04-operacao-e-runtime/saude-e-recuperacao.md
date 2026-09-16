# Health checks & recuperação de travamento

O Poseidon tem um issue aberto, ainda sem causa raiz fechada
([#224](https://github.com/herlondf/poseidon/issues/224)): sob carga
sustentada pesada com rajadas de fechamento de conexão quase simultâneas, o
mecanismo de completion (io_uring ou epoll — reproduzido nos dois) pode
parar de entregar eventos de nova conexão e de fechamento pro servidor. O
processo continua vivo mas para de responder. Uma mitigação parcial já está
no core (`IdleSweep` força o fechamento de uma conexão se a completion
esperada nunca chega, evitando vazamento indefinido de fd em `FIN_WAIT2`),
mas o mecanismo de fundo ("completions param de chegar") ainda está em
aberto. Até ser corrigido, rode o Poseidon atrás de um health check externo
que reinicia o processo se ele ficar sem resposta — alguns segundos de
downtime de restart é um raio de impacto muito menor que um servidor
travado indefinidamente.

## Health check baseado em `/ping`

Todo deploy deveria expor um endpoint de liveness barato e sem autenticação
(a maioria dos samples já expõe) e ter o supervisor de processo reiniciando
em caso de falha — nunca confie na própria liveness do processo.

### Docker

```yaml
services:
  app:
    image: your-poseidon-app:latest
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8080/ping"]
      interval: 5s
      timeout: 3s
      retries: 3
      start_period: 5s
    restart: unless-stopped   # reinicia o container quando o healthcheck falha
```

`restart: unless-stopped` sozinho **não** reinicia automaticamente por
healthcheck falho num `docker run` puro — combine com um orquestrador
(Swarm, `livenessProbe` do Kubernetes) ou um script sidecar/watchdog
pequeno que roda `docker restart` quando `docker inspect --format
'{{.State.Health.Status}}'` reporta `unhealthy`, caso não esteja usando um
orquestrador que já faça isso nativamente.

### Kubernetes

```yaml
livenessProbe:
  httpGet:
    path: /ping
    port: 8080
  periodSeconds: 5
  timeoutSeconds: 3
  failureThreshold: 3
```

### systemd (bare-metal / VM)

```ini
[Service]
ExecStart=/opt/yourapp/server
Restart=always
WatchdogSec=15
# o app precisa chamar sd_notify(WATCHDOG=1) periodicamente, ou omita
# WatchdogSec e use uma timer unit separada que faz curl no /ping e
# `systemctl restart` em caso de falha.
```

Veja [#224](https://github.com/herlondf/poseidon/issues/224) pra
investigação completa (reproduzido no WSL2 e numa VPS Linux real, nos dois
backends de IO) e o status atual antes de assumir que isso já foi
corrigido.

## Log estruturado (JSON)

Por padrão (`LogFormat := lfPlain`), o próprio sink de log do servidor — as
linhas `[startup]`/`[health]` e qualquer outra coisa logada via `_Log` quando
nenhum callback `OnLog` está definido — escreve texto puro:
`[poseidon][INFO][iid=eda89e] [health] conns=13 ...`.

```pascal
LServer.LogFormat := lfJSON;
```

envolve cada uma dessas mesmas linhas como um objeto JSON:
`{"level":"INFO","iid":"eda89e","msg":"[health] conns=13 ..."}`, que um
agregador de log (CloudWatch Insights, Loki) consegue parsear sem regex de
texto. Isso só envolve a mensagem *inteira* já formatada como um único campo
JSON string — não quebra `conns=13 inflight=...` em campos JSON separados por
métrica. Se precisar disso, parseie `msg` depois, ou use o endpoint Prometheus
[`/metrics`](metrics.md), que já expõe esses valores individualmente como
números consultáveis.

`LogFormat` só afeta esse sink padrão. Uma vez que `OnLog` é definido, seu
callback controla a formatação por completo e `LogFormat` não tem efeito.
