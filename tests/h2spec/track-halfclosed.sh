#!/usr/bin/env bash
# track-halfclosed.sh [n] — deploy do ELF baseline async e roda h2spec COMPLETO n
# vezes, rastreando as 2 falhas half-closed (PRIORITY em half-closed-remote;
# DATA em stream nao-open) + o total. Flip entre runs = artefato da corrupcao #11.
set -u
N="${1:-3}"
PORT=9444
WORK=/opt/h2test
cp -f /mnt/d/IA/Projetos/Delphi/Poseidon/tests/h2spec/bin/poseidon-h2spec-server "$WORK/poseidon-h2spec-server"
chmod +x "$WORK/poseidon-h2spec-server"
cd "$WORK"
[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

for i in $(seq 1 "$N"); do
  ./poseidon-h2spec-server "$PORT" > s.log 2>&1 &
  SRV=$!
  for j in $(seq 1 40); do grep -q READY s.log && break; sleep 0.25; done
  h2spec -t -k -h 127.0.0.1 -p "$PORT" > full.txt 2>&1
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  SUM=$(grep -E "[0-9]+ tests, [0-9]+ passed" full.txt | tail -1)
  PRIO=$(sed -r "s/\x1b\[[0-9;]*m//g" full.txt | grep -c "PRIORITY frame on half-closed")
  DATA=$(sed -r "s/\x1b\[[0-9;]*m//g" full.txt | grep -c "DATA frame on the stream that is not in")
  # corrupcao TLS neste run?
  CORR=$(grep -ciE "bad record mac|received record with version" full.txt)
  echo "run $i: [$SUM] | PRIORITY-halfclosed_fail=$PRIO DATA-notopen_fail=$DATA | tls_corrupt_signals=$CORR"
done
