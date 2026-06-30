#!/bin/bash
# run-benchmark.sh — Runs the full benchmark suite.
# Execute from: benchmark/comparison/ directory
# Usage: bash scripts/run-benchmark.sh [--platform linux|win]
#
# Prerequisites:
#   - Server binaries in bin/win64/ or bin/linux64/
#   - bombardier in PATH or current directory
#   - payload5mb.bin generated (auto-created if missing)

set -euo pipefail

PLATFORM="${1:-linux}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
RESULTS_DIR="$BASE_DIR/results/${PLATFORM}64"

# --- Detect bombardier ---
BOMBARDIER=""
if command -v bombardier &>/dev/null; then
    BOMBARDIER="bombardier"
elif [ -f "$BASE_DIR/bombardier" ]; then
    BOMBARDIER="$BASE_DIR/bombardier"
elif [ -f "/mnt/d/IA/Projetos/WSL-Manager/benchmark/bombardier" ]; then
    BOMBARDIER="/mnt/d/IA/Projetos/WSL-Manager/benchmark/bombardier"
else
    echo "ERROR: bombardier not found. Install it or place it in $BASE_DIR/"
    echo "  Linux: go install github.com/codesenberg/bombardier@latest"
    echo "  Or copy from Windows: cp /mnt/d/IA/Projetos/WSL-Manager/benchmark/bombardier.exe ."
    exit 1
fi

# --- Detect binary dir ---
if [ "$PLATFORM" = "linux" ]; then
    BIN_DIR="$BASE_DIR/bin/linux64"
else
    BIN_DIR="$BASE_DIR/bin/win64"
fi

# --- Generate 5MB payload if missing ---
PAYLOAD="$BASE_DIR/payload5mb.bin"
if [ ! -f "$PAYLOAD" ]; then
    echo ">>> Generating 5MB payload..."
    dd if=/dev/urandom of="$PAYLOAD" bs=1M count=5 2>/dev/null
fi

# --- Server definitions: name:port:binary ---
declare -a SERVERS
if [ "$PLATFORM" = "linux" ]; then
    SERVERS=(
        "Poseidon:9801:BenchServer.Poseidon"
        "Horse+Poseidon:9803:BenchServer.HorsePoseidon"
    )
else
    SERVERS=(
        "Poseidon:9801:BenchServer.Poseidon.exe"
        "Horse+Indy:9802:BenchServer.HorseIndy.exe"
        "Horse+Poseidon:9803:BenchServer.HorsePoseidon.exe"
    )
fi

# --- Benchmark parameters (matching Horse PR #481) ---
CONNECTIONS=100
REQUESTS=20000
UPLOAD_REQUESTS=200
WARMUP_REQUESTS=500

# --- Ensure results dir ---
mkdir -p "$RESULTS_DIR"

# --- Helper: wait for server to be ready ---
wait_for_port() {
    local port=$1
    local max_wait=10
    local i=0
    while ! (echo >/dev/tcp/127.0.0.1/$port) 2>/dev/null; do
        sleep 0.5
        i=$((i + 1))
        if [ $i -ge $((max_wait * 2)) ]; then
            echo "ERROR: Server did not start on port $port within ${max_wait}s"
            return 1
        fi
    done
}

# --- Helper: run one bombardier scenario ---
run_scenario() {
    local name=$1
    local port=$2
    local scenario=$3
    local outfile="$RESULTS_DIR/${name}-${scenario}.json"

    echo -n "    $scenario ... "

    case "$scenario" in
        ping)
            $BOMBARDIER -c $CONNECTIONS -n $REQUESTS \
                "http://127.0.0.1:${port}/ping" \
                -o j > "$outfile" 2>/dev/null
            ;;
        json)
            $BOMBARDIER -c $CONNECTIONS -n $REQUESTS \
                "http://127.0.0.1:${port}/json" \
                -o j > "$outfile" 2>/dev/null
            ;;
        upload)
            $BOMBARDIER -c $CONNECTIONS -n $UPLOAD_REQUESTS \
                -m POST -f "$PAYLOAD" \
                "http://127.0.0.1:${port}/upload" \
                -o j > "$outfile" 2>/dev/null
            ;;
        delay)
            $BOMBARDIER -c $CONNECTIONS -n $REQUESTS \
                "http://127.0.0.1:${port}/delay" \
                -o j > "$outfile" 2>/dev/null
            ;;
    esac

    # Extract RPS from JSON
    local rps
    rps=$(python3 -c "import json,sys; d=json.load(open('$outfile')); print(f\"{d['result']['rps']['mean']:.2f}\")" 2>/dev/null || echo "N/A")
    echo "${rps} RPS"
}

# --- Main loop ---
echo "============================================"
echo "  Poseidon Benchmark Comparison"
echo "  Platform: ${PLATFORM}64"
echo "  Connections: $CONNECTIONS"
echo "  Requests: $REQUESTS (upload: $UPLOAD_REQUESTS)"
echo "  Tool: $BOMBARDIER"
echo "============================================"
echo ""

for entry in "${SERVERS[@]}"; do
    IFS=':' read -r NAME PORT BINARY <<< "$entry"
    BINARY_PATH="$BIN_DIR/$BINARY"

    if [ ! -f "$BINARY_PATH" ]; then
        echo ">>> SKIP $NAME — binary not found: $BINARY_PATH"
        echo ""
        continue
    fi

    echo ">>> $NAME (port $PORT)"

    # Start server
    chmod +x "$BINARY_PATH" 2>/dev/null || true
    echo "" | "$BINARY_PATH" &
    SERVER_PID=$!
    sleep 2

    # Wait for port
    if ! wait_for_port "$PORT"; then
        kill $SERVER_PID 2>/dev/null || true
        echo "    FAILED to start — skipping"
        echo ""
        continue
    fi

    # Warmup
    echo -n "    warmup ... "
    $BOMBARDIER -c 10 -n $WARMUP_REQUESTS \
        "http://127.0.0.1:${PORT}/ping" \
        -p r --print result > /dev/null 2>&1 || true
    echo "done"

    # Run scenarios
    run_scenario "$NAME" "$PORT" "ping"
    run_scenario "$NAME" "$PORT" "json"
    run_scenario "$NAME" "$PORT" "upload"
    run_scenario "$NAME" "$PORT" "delay"

    # Stop server
    kill $SERVER_PID 2>/dev/null || true
    wait $SERVER_PID 2>/dev/null || true
    sleep 1
    echo ""
done

echo "============================================"
echo "  Results saved to: $RESULTS_DIR/"
echo "============================================"

# --- Generate summary table ---
echo ""
echo "=== SUMMARY ==="
printf "%-20s %12s %12s %12s %12s\n" "Provider" "Ping RPS" "JSON RPS" "Upload RPS" "Delay RPS"
printf "%-20s %12s %12s %12s %12s\n" "--------" "--------" "--------" "----------" "---------"

for entry in "${SERVERS[@]}"; do
    IFS=':' read -r NAME PORT BINARY <<< "$entry"

    get_rps() {
        local f="$RESULTS_DIR/${NAME}-${1}.json"
        if [ -f "$f" ]; then
            python3 -c "import json; d=json.load(open('$f')); print(f\"{d['result']['rps']['mean']:.2f}\")" 2>/dev/null || echo "N/A"
        else
            echo "N/A"
        fi
    }

    printf "%-20s %12s %12s %12s %12s\n" \
        "$NAME" \
        "$(get_rps ping)" \
        "$(get_rps json)" \
        "$(get_rps upload)" \
        "$(get_rps delay)"
done

echo ""
echo "Done. Run 'scripts/generate-report.sh' to create HTML report."
