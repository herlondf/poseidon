#!/usr/bin/env bash
# diag-race.sh [porta] — deploy do ELF instrumentado, roda h2spec propenso a
# corrupcao, e reporta as linhas [RACE ...] do server.log (corrida cross-thread
# real detectada no SSL/send path).
set -u
PORT="${1:-9444}"
WORK=/opt/h2test
cp -f /mnt/d/IA/Projetos/Delphi/Poseidon/tests/h2spec/bin/poseidon-h2spec-server "$WORK/poseidon-h2spec-server"
chmod +x "$WORK/poseidon-h2spec-server"
cd "$WORK"
[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

./poseidon-h2spec-server "$PORT" > s.log 2>&1 &
SRV=$!
for j in $(seq 1 40); do grep -q READY s.log && break; sleep 0.25; done

# grupos que exercitam muitos streams (gatilho da corrupcao)
h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/5.1.2 > /dev/null 2>&1
h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/6 > o6.txt 2>&1
kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

echo "=== corrupcao no cliente? ==="
grep -ciE "bad record mac|received record with version" o6.txt | sed 's/^/sinais=/'
echo "=== linhas [RACE] no server.log ==="
grep -c "\[RACE" s.log | sed 's/^/total_race=/'
grep "\[RACE" s.log | sort | uniq -c | sort -rn | head -20
echo "=== amostra crua ==="
grep "\[RACE" s.log | head -6
