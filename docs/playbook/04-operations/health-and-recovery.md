# Health checks & crash recovery

Poseidon has an open, not-yet-root-caused issue
([#224](https://github.com/herlondf/poseidon/issues/224)): under sustained
heavy load with bursts of near-simultaneous connection closures, the
completion mechanism (io_uring or epoll — reproduced on both) can stop
delivering new-connection and connection-close events to the server. The
process stays alive but stops answering. A partial mitigation ships in the
core (`IdleSweep` force-closes a connection if the expected close completion
never arrives, avoiding an indefinite fd leak in `FIN_WAIT2`), but the
underlying "completions stop arriving" mechanism is still open. Until it's
fixed, run Poseidon behind an external health check that restarts the
process if it becomes unresponsive — a few seconds of restart downtime is a
much smaller blast radius than an indefinitely hung server.

## `/ping`-based health check

Any deployment should expose a cheap, unauthenticated liveness endpoint
(most samples already do) and have the process supervisor restart on
failure — never rely on the process's own liveness.

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
    restart: unless-stopped   # restarts the container when healthcheck fails
```

`restart: unless-stopped` alone does **not** restart on a failing
healthcheck by itself in plain `docker run` — pair it with an orchestrator
(Swarm, Kubernetes livenessProbe) or a small sidecar/watchdog script that
`docker restart`s the container when `docker inspect --format '{{.State.Health.Status}}'`
reports `unhealthy`, if not using an orchestrator that does this natively.

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
# the app must call sd_notify(WATCHDOG=1) periodically, or omit WatchdogSec
# and rely on a separate timer unit curling /ping and `systemctl restart`
# on failure instead.
```

See [#224](https://github.com/herlondf/poseidon/issues/224) for the full
investigation (reproduced on both WSL2 and a real Linux VPS, both IO
backends) and its current status before assuming this is fixed.

## Structured (JSON) logging

By default (`LogFormat := lfPlain`), the server's own log sink - the
`[startup]`/`[health]` lines and anything else logged through `_Log` when no
`OnLog` callback is assigned - writes plain text:
`[poseidon][INFO][iid=eda89e] [health] conns=13 ...`.

```pascal
LServer.LogFormat := lfJSON;
```

wraps each of those same lines as one JSON object instead:
`{"level":"INFO","iid":"eda89e","msg":"[health] conns=13 ..."}`, which a log
aggregator (CloudWatch Insights, Loki) can parse without a text-matching
regex. This only wraps the *whole* pre-formatted message as one JSON string
field - it does not break `conns=13 inflight=...` out into separate JSON
fields per metric. If you need that, parse `msg` downstream, or use the
Prometheus [`/metrics`](metrics.md) endpoint instead, which already exposes
these as individually queryable numeric values.

`LogFormat` only affects this default sink. Once `OnLog` is assigned, your
callback controls formatting entirely and `LogFormat` has no effect.
