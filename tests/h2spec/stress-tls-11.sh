#!/usr/bin/env bash
# stress-tls-11.sh — validacao do fix #11 (corrupcao de record TLS sob carga).
# Roda repetidamente os grupos h2spec propensos a corrupcao sob muitos streams
# concorrentes (5.1.2 concurrent-stream-limit, 6.x flow/data) sobre TLS, e conta
# assinaturas de corrupcao no lado cliente (h2spec = cliente TLS Go real):
#   "bad record MAC" / "received record with version" / "unexpected EOF" / "decryption failed"
# Uso: stress-tls-11.sh <iteracoes> [porta]
set -u
ITERS="${1:-15}"
PORT="${2:-9444}"
WORK=/opt/h2test
cd "$WORK" || { echo "no $WORK"; exit 1; }

[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt \
  -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

corrupt=0
fail_csl=0
runs=0
for i in $(seq 1 "$ITERS"); do
  ./poseidon-h2spec-server "$PORT" > server.log 2>&1 &
  SRV=$!
  ready=0
  for j in $(seq 1 40); do grep -q READY server.log && { ready=1; break; }; sleep 0.25; done
  if [ "$ready" != 1 ]; then echo "iter $i: SERVER_NOT_READY"; cat server.log; kill "$SRV" 2>/dev/null; continue; fi

  # 5.1.2 = concurrent-stream-limit (abre MAX+1 streams rapido = gatilho da corrupcao)
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/5.1.2 > o_csl.txt 2>&1
  # 6 = DATA/flow (varios streams com corpo)
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/6 > o_data.txt 2>&1
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  runs=$((runs+1))

  if grep -qiE "bad record mac|received record with version|decryption failed|unexpected EOF|corrupt" o_csl.txt o_data.txt server.log; then
    corrupt=$((corrupt+1))
    echo "iter $i: CORRUPCAO DETECTADA:"
    grep -iE "bad record mac|received record with version|decryption failed|unexpected EOF|corrupt" o_csl.txt o_data.txt server.log | head -4
  fi
  # concurrent-stream-limit deve PASSAR (nao e teste half-closed)
  if ! grep -qE "1 passed|All tests passed|tests, 1 passed" o_csl.txt; then
    fail_csl=$((fail_csl+1))
    echo "iter $i: 5.1.2 nao passou:"
    sed -r 's/\x1b\[[0-9;]*m//g' o_csl.txt | grep -E "passed|✕|×" | head -3
  fi
  # WORKER_EX no server = crash/corrida
  if grep -qE "WORKER_EX|CORE.*_EX|EAccessViolation|_EX \[" server.log; then
    echo "iter $i: SERVER EXCEPTION:"; grep -E "WORKER_EX|_EX \[|EAccess" server.log | head -3
  fi
done

echo "=========================================="
echo "STRESS #11: runs=$runs  corrupcao=$corrupt  csl_falhou=$fail_csl"
if [ "$corrupt" = 0 ] && [ "$fail_csl" = 0 ]; then
  echo "RESULTADO: LIMPO (sem corrupcao de record TLS em $runs runs)"
else
  echo "RESULTADO: AINDA HA PROBLEMA"
fi
