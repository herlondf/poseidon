#!/usr/bin/env bash
set -u
PORT=9444
cd /opt/h2test
for a in $(seq 1 6); do
  ./poseidon-h2spec-server "$PORT" > s.log 2>&1 &
  SRV=$!
  for j in $(seq 1 40); do grep -q READY s.log && break; sleep 0.25; done
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/6 > o.txt 2>&1
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  grep -qiE "bad record mac|received record with version" o.txt && break
done
echo "=== corrupcao sinais ==="; grep -ciE "bad record mac|received record" o.txt
echo "=== s.log linhas ==="; wc -l s.log
echo "=== head s.log ==="; head -6 s.log
echo "=== contagem de markers ==="
echo "SEND=$(grep -c '\[SEND' s.log) EAGAIN=$(grep -c '\[EAGAIN' s.log) CLOBBER=$(grep -c '\[CLOBBER' s.log)"
echo "=== todos os prefixos [XXX no log ==="
grep -oE "\[[A-Za-z_]+" s.log | sort | uniq -c | sort -rn | head -15
echo "=== amostra de linhas com [ ==="
grep -E "\[" s.log | head -6
