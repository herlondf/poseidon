#!/usr/bin/env bash
# diag-clobber.sh [iters] [porta] — roda N vezes o gatilho pesado (5.1.2 + http2/6)
# e AGREGA: sinais de corrupcao, CLOBBER (Causa #1), EAGAIN (socket cheio), RACE.
# Objetivo: ver se CLOBBER/EAGAIN correlacionam com a corrupcao (send path) ou nao.
set -u
ITERS="${1:-20}"
PORT="${2:-9444}"
WORK=/opt/h2test
cp -f /mnt/d/IA/Projetos/Delphi/Poseidon/tests/h2spec/bin/poseidon-h2spec-server "$WORK/poseidon-h2spec-server"
chmod +x "$WORK/poseidon-h2spec-server"
cd "$WORK"
[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

TS=0; TC=0; TE=0; TR=0; RUNS_CORRUPT=0; RUNS_CLOBBER=0
for i in $(seq 1 "$ITERS"); do
  ./poseidon-h2spec-server "$PORT" > s.log 2>&1 &
  SRV=$!
  for j in $(seq 1 40); do grep -q READY s.log && break; sleep 0.25; done
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/5.1.2 > o.txt 2>&1
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/6 >> o.txt 2>&1
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

  s=$(grep -ciE "bad record mac|received record with version" o.txt)
  c=$(grep -c "\[CLOBBER" s.log)
  e=$(grep -c "\[EAGAIN" s.log)
  r=$(grep -c "\[RACE" s.log)
  TS=$((TS+s)); TC=$((TC+c)); TE=$((TE+e)); TR=$((TR+r))
  [ "$s" -gt 0 ] && RUNS_CORRUPT=$((RUNS_CORRUPT+1))
  [ "$c" -gt 0 ] && RUNS_CLOBBER=$((RUNS_CLOBBER+1))
  # se este run corrompeu E teve clobber, mostrar contexto
  if [ "$s" -gt 0 ] && [ "$c" -gt 0 ]; then
    echo "iter $i: CORRUPCAO+CLOBBER juntos:"; grep "\[CLOBBER" s.log | head -3
  fi
done
echo "=================================="
echo "runs=$ITERS | corrompeu=$RUNS_CORRUPT run(s) | com_clobber=$RUNS_CLOBBER run(s)"
echo "totais: sinais_corrupcao=$TS  CLOBBER=$TC  EAGAIN=$TE  RACE=$TR"
