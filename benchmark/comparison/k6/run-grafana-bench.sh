#!/bin/bash
# run-grafana-bench.sh — Full benchmark suite with InfluxDB/Grafana output.
# Run from WSL Totvs: cd ~/benchmark/poseidon && bash run-grafana-bench.sh
#
# Registers results in InfluxDB → visible in Grafana at http://localhost:3001
# Dashboard: k6 Load Testing (var-test dropdown)

set -uo pipefail

K6=/home/herlon/benchmark/k6/k6-bin
JS=/home/herlon/benchmark/poseidon/bench-comparison.js
DIR=/home/herlon/benchmark/poseidon
INFLUXDB_URL="http://127.0.0.1:8086/k6"

USERS="${1:-200}"
DURATION="${2:-2m}"

echo "============================================================"
echo "  Poseidon vs Horse — k6 + Grafana Benchmark"
echo "  VUs: $USERS | Duration: $DURATION"
echo "  InfluxDB: $INFLUXDB_URL"
echo "  Grafana: http://localhost:3001"
echo "============================================================"

run_bench() {
  local LABEL="$1" BINARY="$2" PORT="$3" SCENARIO="$4"
  local BINARY_PATH="$DIR/$BINARY"
  local TAG="${LABEL}-${SCENARIO}"

  [ -f "$BINARY_PATH" ] || { echo "  SKIP: $BINARY not found"; return; }

  echo -n "  $SCENARIO ... "

  $K6 run --quiet \
    --out "influxdb=$INFLUXDB_URL" \
    --tag testid="$TAG" \
    -e BASE_URL="http://127.0.0.1:$PORT" \
    -e SCENARIO="$SCENARIO" \
    -e USERS="$USERS" \
    -e DURATION="$DURATION" \
    -e LABEL="$LABEL" \
    "$JS" 2>/dev/null

  echo "done"
}

run_server() {
  local LABEL="$1" BINARY="$2" PORT="$3"
  local BINARY_PATH="$DIR/$BINARY"

  [ -f "$BINARY_PATH" ] || { echo ">>> SKIP $LABEL — $BINARY not found"; return; }

  echo ""
  echo ">>> $LABEL"

  # Start server
  "$BINARY_PATH" &
  local PID=$!
  sleep 2

  # Verify
  if ! (echo >/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
    echo "  FAILED to start on port $PORT"
    kill $PID 2>/dev/null; wait $PID 2>/dev/null || true
    return
  fi

  # Warmup
  echo -n "  warmup ... "
  $K6 run --quiet -e BASE_URL="http://127.0.0.1:$PORT" -e SCENARIO=ping -e USERS=10 -e DURATION=10s -e LABEL=warmup "$JS" >/dev/null 2>&1 || true
  echo "done"

  # Run scenarios
  run_bench "$LABEL" "$BINARY" "$PORT" "ping"
  run_bench "$LABEL" "$BINARY" "$PORT" "json"
  run_bench "$LABEL" "$BINARY" "$PORT" "delay"

  # Stop server
  kill $PID 2>/dev/null
  wait $PID 2>/dev/null || true
  sleep 2
}

# === Run all servers ===

run_server "poseidon-framework" "BenchServer.PoseidonFramework" 9801
run_server "poseidon-native" "BenchServer.Poseidon" 9801

echo ""
echo "============================================================"
echo "  DONE — View results in Grafana:"
echo "  http://localhost:3001/d/k6/k6-load-testing"
echo "============================================================"
