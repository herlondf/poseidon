#!/bin/bash
# run-k6-win.sh — Run k6 load tests against servers running on WINDOWS.
# Execute FROM WSL Totvs. Servers must already be running on Windows.
#
# Usage: bash run-k6-win.sh [USERS] [DURATION]
# Default: 200 VUs, 2m

set -uo pipefail

USERS="${1:-200}"
DURATION="${2:-2m}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
K6="$HOME/benchmark/k6/k6-bin"
JS="$SCRIPT_DIR/bench-comparison.js"
RESULTS_DIR="$SCRIPT_DIR/../results/k6-win64"
WIN_HOST="$(ip route show default | awk '{print $3}')"

# Check k6
if [ ! -f "$K6" ]; then
  K6=$(which k6 2>/dev/null || echo "")
  [ -z "$K6" ] && { echo "ERROR: k6 not found"; exit 1; }
fi

mkdir -p "$RESULTS_DIR"

# Servers: label:port
SERVERS=(
  "Poseidon:9801"
  "Horse3.2+Indy:9802"
  "Horse3.2+Poseidon:9803"
)

SCENARIOS="ping json delay"

echo "============================================================"
echo "  k6 Benchmark — Windows Servers"
echo "  VUs: $USERS | Duration: $DURATION"
echo "  Host: $WIN_HOST"
echo "============================================================"
echo ""

for entry in "${SERVERS[@]}"; do
  IFS=':' read -r LABEL PORT <<< "$entry"
  BASE_URL="http://${WIN_HOST}:${PORT}"

  # Check if server is reachable
  if ! curl -s --max-time 2 "$BASE_URL/ping" >/dev/null 2>&1; then
    echo ">>> SKIP $LABEL — not reachable at $BASE_URL"
    echo ""
    continue
  fi

  echo ">>> $LABEL ($BASE_URL)"

  for SC in $SCENARIOS; do
    echo -n "  $SC ... "
    $K6 run --quiet \
      -e BASE_URL="$BASE_URL" \
      -e SCENARIO="$SC" \
      -e USERS="$USERS" \
      -e DURATION="$DURATION" \
      -e LABEL="$LABEL" \
      "$JS" 2>/dev/null

    # Copy result from /tmp
    SRC="/tmp/k6-${LABEL}-${SC}.json"
    if [ -f "$SRC" ]; then
      cp "$SRC" "$RESULTS_DIR/${LABEL}-${SC}.json"
      RPS=$(python3 -c "import json; d=json.load(open('$SRC')); print(d['rps'])" 2>/dev/null || echo "?")
      P95=$(python3 -c "import json; d=json.load(open('$SRC')); print(f\"{d['latency']['p95']:.1f}ms\")" 2>/dev/null || echo "?")
      echo "done — $RPS RPS, p95=$P95"
    else
      echo "done (no result file)"
    fi
  done
  echo ""
done

# Summary table
echo "============================================================"
echo "  SUMMARY — $USERS VUs, $DURATION"
echo "============================================================"
printf "%-25s %10s %10s %10s %10s %10s %10s\n" \
  "Provider" "Ping RPS" "Ping p95" "JSON RPS" "JSON p95" "Delay RPS" "Delay p95"
printf "%-25s %10s %10s %10s %10s %10s %10s\n" \
  "--------" "--------" "--------" "--------" "--------" "---------" "---------"

for entry in "${SERVERS[@]}"; do
  IFS=':' read -r LABEL PORT <<< "$entry"
  VALS=""
  for SC in ping json delay; do
    F="$RESULTS_DIR/${LABEL}-${SC}.json"
    if [ -f "$F" ]; then
      RPS=$(python3 -c "import json; d=json.load(open('$F')); print(f\"{d['rps']:.0f}\")" 2>/dev/null || echo "N/A")
      P95=$(python3 -c "import json; d=json.load(open('$F')); print(f\"{d['latency']['p95']:.1f}\")" 2>/dev/null || echo "N/A")
      VALS="$VALS $(printf '%10s %10s' "$RPS" "${P95}ms")"
    else
      VALS="$VALS $(printf '%10s %10s' 'N/A' 'N/A')"
    fi
  done
  printf "%-25s%s\n" "$LABEL" "$VALS"
done

echo ""
echo "Results: $RESULTS_DIR/"
