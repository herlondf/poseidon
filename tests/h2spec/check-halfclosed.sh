#!/usr/bin/env bash
# check-halfclosed.sh [porta] — roda os grupos h2spec dos 2 testes half-closed
# (5.1 e 6.1) contra o binario ja em /opt/h2test, N vezes, e conta pass/fail.
# Serve p/ distinguir bug de lifecycle REAL de artefato da corrupcao TLS (#11).
set -u
PORT="${1:-9444}"
ITERS="${2:-5}"
cd /opt/h2test || exit 1
[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

f51=0; f61=0
for i in $(seq 1 "$ITERS"); do
  ./poseidon-h2spec-server "$PORT" > s.log 2>&1 &
  SRV=$!
  for j in $(seq 1 40); do grep -q READY s.log && break; sleep 0.25; done
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/5.1 > r51.txt 2>&1
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/6.1 > r61.txt 2>&1
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  grep -qE ", 0 failed|All tests passed" r51.txt || { f51=$((f51+1)); }
  grep -qE ", 0 failed|All tests passed" r61.txt || { f61=$((f61+1)); }
  s51=$(grep -oE "[0-9]+ passed, [0-9]+ (skipped, )?[0-9]+ failed" r51.txt | tail -1)
  s61=$(grep -oE "[0-9]+ passed, [0-9]+ (skipped, )?[0-9]+ failed" r61.txt | tail -1)
  echo "iter $i: 5.1[$s51]  6.1[$s61]"
done
echo "=================================="
echo "5.1 falhou em $f51/$ITERS iteracoes; 6.1 falhou em $f61/$ITERS"
