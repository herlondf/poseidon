#!/bin/bash
# run-linux.sh — Execute from WSL Totvs: ~/benchmark/poseidon/
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"
mkdir -p results

echo "============================================"
echo "  Poseidon Benchmark - Linux (WSL2 Totvs)"
echo "  Connections: 100 | Requests: 20000"
echo "============================================"
echo ""

# Generate payload if needed
[ -f payload5mb.bin ] || dd if=/dev/urandom of=payload5mb.bin bs=1M count=5 2>/dev/null

get_rps() {
    python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(f\"{d['result']['rps']['mean']:.2f}\")
except:
    print('N/A')
" "$1"
}

run_server() {
    local NAME="$1" PORT="$2" BIN="$3"

    [ -f "./$BIN" ] || { echo ">>> SKIP $NAME — $BIN not found"; return; }

    echo ">>> $NAME (port $PORT)"

    ./"$BIN" &
    local PID=$!
    sleep 2

    # Check port
    if ! (echo >/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
        echo "  FAILED to start"; kill $PID 2>/dev/null; wait $PID 2>/dev/null; return
    fi

    # Warmup
    echo -n "  warmup ... "
    bombardier -c 10 -n 500 "http://127.0.0.1:$PORT/ping" -o j >/dev/null 2>&1 || true
    echo "done"

    # Ping, JSON, Delay
    for SC in ping json delay; do
        echo -n "  $SC ... "
        bombardier -c 100 -n 20000 "http://127.0.0.1:$PORT/$SC" -o j 2>/dev/null | grep '^{' > "results/${NAME}-${SC}.json"
        echo "$(get_rps "results/${NAME}-${SC}.json") RPS"
    done

    # Upload
    echo -n "  upload ... "
    bombardier -c 100 -n 200 -m POST -f payload5mb.bin "http://127.0.0.1:$PORT/upload" -o j 2>/dev/null | grep '^{' > "results/${NAME}-upload.json"
    echo "$(get_rps "results/${NAME}-upload.json") RPS"

    kill $PID 2>/dev/null
    wait $PID 2>/dev/null || true
    # Ensure port is freed
    sleep 2
    echo ""
}

run_server "Poseidon"            9801 "BenchServer.Poseidon"
run_server "Horse3.2+Poseidon"   9803 "BenchServer.HorsePoseidon320"

echo "=== SUMMARY ==="
printf "%-25s %12s %12s %12s %12s\n" "Provider" "Ping RPS" "JSON RPS" "Upload RPS" "Delay RPS"
printf "%-25s %12s %12s %12s %12s\n" "--------" "--------" "--------" "----------" "---------"

for NAME in "Poseidon" "Horse3.2+Poseidon"; do
    VALS=""
    for SC in ping json upload delay; do
        F="results/${NAME}-${SC}.json"
        [ -f "$F" ] && V=$(get_rps "$F") || V="N/A"
        VALS="$VALS $(printf '%12s' "$V")"
    done
    printf "%-25s%s\n" "$NAME" "$VALS"
done
