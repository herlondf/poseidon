#!/usr/bin/env bash
# run-autobahn.sh — roda o Autobahn|Testsuite (fuzzingclient) contra o echo server
# do Poseidon. Executa DENTRO da distro WSL Benchmark (que tem Docker). O echo
# server roda como processo nativo; o testsuite roda no container crossbario com
# --network host. Uso: bash run-autobahn.sh [porta]
set -u
PORT="${1:-9011}"
SPEC="${2:-fuzzingclient.json}"
DIR="/mnt/d/IA/Projetos/Delphi/Poseidon/tests/autobahn"
WORK=/opt/autobahn
mkdir -p "$WORK/reports"
cp -f "$DIR/bin/poseidon-autobahn-server" "$WORK/server"
chmod +x "$WORK/server"
cp -f "$DIR/$SPEC" "$WORK/fuzzingclient.json"

# libs runtime OK?
if ldd "$WORK/server" 2>&1 | grep -qi "not found"; then
  echo "RUNTIME_LIB_MISSING"; ldd "$WORK/server" 2>&1 | grep -i "not found"; exit 2
fi

"$WORK/server" "$PORT" > "$WORK/server.log" 2>&1 &
SRV=$!
ready=0
for i in $(seq 1 40); do grep -q READY "$WORK/server.log" && { ready=1; break; }; sleep 0.25; done
if [ "$ready" != 1 ]; then echo "SERVER_NOT_READY"; cat "$WORK/server.log"; kill "$SRV" 2>/dev/null; exit 3; fi
echo "echo server up (pid $SRV) porta $PORT"

docker run --rm --network host \
  -v "$WORK/fuzzingclient.json:/spec.json:ro" \
  -v "$WORK/reports:/reports" \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /spec.json 2>&1 | tail -5

kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
echo "=== relatorio em $WORK/reports/clients/index.json ==="
ls -la "$WORK/reports/clients/" 2>/dev/null | head
