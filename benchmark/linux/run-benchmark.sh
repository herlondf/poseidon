#!/usr/bin/env bash
# benchmark/linux/run-benchmark.sh
# Script maestro para todos os cenários de benchmark Poseidon vs Horse.
#
# Pré-requisitos:
#   - Docker Compose (compose.yml na mesma pasta)
#   - bombardier instalado (ou via docker exec — ver BOMBARDIER_CMD)
#   - build-bench.sh já executado (assets/bench-*.linux64 presentes)
#   - jq instalado (para parse de JSON e geração de resultados)
#
# Uso:
#   cd benchmark/linux
#   ./run-benchmark.sh [--no-build] [--scenario alb-saturation|ping|payload]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_FILE="${RESULTS_DIR}/bench-results-${TIMESTAMP}.json"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

POSEIDON_URL="http://localhost:18080"
HORSE_URL="http://localhost:18081"
POSEIDON_HA_URL="http://localhost:18091"
HORSE_HA_URL="http://localhost:18092"
HAPROXY_STATS="http://localhost:19090/stats;csv"

WARMUP_SECS=8
RUN_SECS=60

# ALB saturation scenario (issue #22 — replicates NFCe benchmark)
ALB_FLOOD_CLIENTS=90     # concurrent slow requests (emulate 90 simultaneous NFCe emissions)
ALB_DAO_LATENCY_MS=30000 # FakeDAO sleep (emulates SEFAZ latency)
ALB_HEALTH_CLIENTS=5     # healthcheck clients (emulates ALB)
ALB_HEALTH_TIMEOUT=5000  # ALB healthcheck timeout ms

# Ping/payload scenarios
PING_CLIENTS=500
PAYLOAD_CLIENTS=100

mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date +%H:%M:%S)] $*"; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found. Install it and retry." >&2
    exit 1
  fi
}

require_cmd docker
require_cmd jq
require_cmd curl

BOMBARDIER_CMD="${BOMBARDIER_CMD:-bombardier}"
if ! command -v bombardier &>/dev/null; then
  # Try downloading bombardier binary
  BOMBARDIER_BIN="${SCRIPT_DIR}/assets/bombardier"
  if [ -f "${BOMBARDIER_BIN}" ]; then
    BOMBARDIER_CMD="${BOMBARDIER_BIN}"
  else
    echo "WARNING: bombardier not found. Download from https://github.com/codesenberg/bombardier/releases" >&2
    echo "  and place at ${BOMBARDIER_BIN}" >&2
    BOMBARDIER_CMD="false"  # will fail if any benchmark tries to run
  fi
fi

# Run bombardier and return JSON result
run_bombardier() {
  local URL="$1"
  local CLIENTS="$2"
  local DURATION="${3:-${RUN_SECS}}"
  local METHOD="${4:-GET}"
  local BODY_FILE="${5:-}"

  local ARGS=("-c" "${CLIENTS}" "-d" "${DURATION}s" "--print" "r" "--format" "json" "-l")
  if [ "${METHOD}" = "POST" ] && [ -n "${BODY_FILE}" ]; then
    ARGS+=("-m" "POST" "-f" "${BODY_FILE}" "-H" "Content-Type: application/json")
  fi
  ARGS+=("${URL}")

  "${BOMBARDIER_CMD}" "${ARGS[@]}" 2>/dev/null
}

# Collect HAProxy stats for a backend
# Returns: chkfail chkdown downtime_sec
haproxy_stats() {
  local BACKEND="$1"
  local CSV
  CSV="$(curl -sf "${HAPROXY_STATS}" 2>/dev/null || echo '')"
  if [ -z "${CSV}" ]; then
    echo "0 0 0"
    return
  fi
  # HAProxy CSV: columns 1=pxname, 2=svname, ...
  # chkfail=col19, downtime=col24 (0-indexed after header)
  local LINE
  LINE="$(echo "${CSV}" | grep "^${BACKEND}," | grep -v "FRONTEND\|BACKEND" | head -1)"
  if [ -z "${LINE}" ]; then
    echo "0 0 0"
    return
  fi
  local CHKFAIL CHKDOWN DOWNTIME
  CHKFAIL="$(echo "${LINE}" | cut -d',' -f19)"
  CHKDOWN="$(echo "${LINE}" | cut -d',' -f22)"  # chkdown
  DOWNTIME="$(echo "${LINE}" | cut -d',' -f24)" # downtime (seconds)
  echo "${CHKFAIL:-0} ${CHKDOWN:-0} ${DOWNTIME:-0}"
}

# ---------------------------------------------------------------------------
# Check services are up
# ---------------------------------------------------------------------------

log "Verificando serviços Docker..."
for SVC in poseidon horse haproxy; do
  STATUS="$(docker inspect --format='{{.State.Health.Status}}' "${SVC}" 2>/dev/null || echo 'unknown')"
  if [ "${STATUS}" != "healthy" ] && [ "${STATUS}" != "unknown" ]; then
    echo "ERROR: Serviço '${SVC}' não está healthy (status: ${STATUS})." >&2
    echo "  Execute: docker compose up -d && sleep 10" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# SCENARIO 1: Ping — latência mínima, alta concorrência
# ---------------------------------------------------------------------------

run_ping_scenario() {
  local NAME="$1"
  local BASE_URL="$2"

  log "Cenário PING — ${NAME} (${PING_CLIENTS} clientes, ${RUN_SECS}s)"
  log "  Warmup ${WARMUP_SECS}s..."
  run_bombardier "${BASE_URL}/ping" "${PING_CLIENTS}" "${WARMUP_SECS}" >/dev/null

  log "  Run..."
  local RESULT
  RESULT="$(run_bombardier "${BASE_URL}/ping" "${PING_CLIENTS}" "${RUN_SECS}")"
  echo "${RESULT}"
}

# ---------------------------------------------------------------------------
# SCENARIO 2: Payload médio (~1KB) — teste de throughput com body
# ---------------------------------------------------------------------------

run_payload_scenario() {
  local NAME="$1"
  local BASE_URL="$2"

  log "Cenário PAYLOAD (1KB) — ${NAME} (${PAYLOAD_CLIENTS} clientes, ${RUN_SECS}s)"
  log "  Warmup ${WARMUP_SECS}s..."
  run_bombardier "${BASE_URL}/medium" "${PAYLOAD_CLIENTS}" "${WARMUP_SECS}" >/dev/null

  log "  Run..."
  local RESULT
  RESULT="$(run_bombardier "${BASE_URL}/medium" "${PAYLOAD_CLIENTS}" "${RUN_SECS}")"
  echo "${RESULT}"
}

# ---------------------------------------------------------------------------
# SCENARIO 3: ALB healthcheck sob saturação (issue #22)
# Replicates NFCe benchmark: 90 concurrent slow requests (30s each) +
# 5 healthcheck clients via HAProxy.
#
# Poseidon: epoll workers are non-blocking — ping always responds in < 5 ms
# Horse/CS: all threads blocked in Sleep → healthcheck times out → HAProxy DOWN
# ---------------------------------------------------------------------------

run_alb_scenario() {
  local NAME="$1"
  local BASE_URL="$2"   # direct URL for flood
  local HA_URL="$3"     # HAProxy-fronted URL for healthcheck
  local BACKEND="$4"    # HAProxy backend name for stats

  log "Cenário ALB SATURATION — ${NAME}"
  log "  Parâmetros: flood=${ALB_FLOOD_CLIENTS} clientes x ${ALB_DAO_LATENCY_MS}ms DAO"
  log "              healthcheck=${ALB_HEALTH_CLIENTS} clientes x ${RUN_SECS}s"

  # Reset HAProxy stats by reloading (not always possible); record baseline
  local STATS_BEFORE
  read -r CHK_BEFORE CHK_DOWN_BEFORE DT_BEFORE <<< "$(haproxy_stats "${BACKEND}_backend")"

  # Start flood in background: POST /dao/slow blocks for 30s per request
  log "  Iniciando flood em background..."
  local FLOOD_PID
  ( run_bombardier "${BASE_URL}/dao/slow" "${ALB_FLOOD_CLIENTS}" "$((RUN_SECS + 5))" "POST" <<< '{}' ) &
  FLOOD_PID=$!

  # Wait for flood to saturate workers (2s should be enough)
  sleep 2

  # Run healthcheck measurement via HAProxy
  log "  Medindo /ping via HAProxy (${ALB_HEALTH_CLIENTS} clientes, ${RUN_SECS}s)..."
  local RESULT
  RESULT="$(run_bombardier "${HA_URL}/ping" "${ALB_HEALTH_CLIENTS}" "${RUN_SECS}")"

  # Collect HAProxy stats
  local CHK_AFTER CHK_DOWN_AFTER DT_AFTER
  read -r CHK_AFTER CHK_DOWN_AFTER DT_AFTER <<< "$(haproxy_stats "${BACKEND}_backend")"

  local CHKFAIL=$((CHK_AFTER - CHK_BEFORE))
  local CHKDOWN=$((CHK_DOWN_AFTER - CHK_DOWN_BEFORE))
  local DOWNTIME=$((DT_AFTER - DT_BEFORE))
  local AVAIL_PCT
  AVAIL_PCT="$(echo "scale=2; (${RUN_SECS} - ${DOWNTIME}) * 100 / ${RUN_SECS}" | bc -l 2>/dev/null || echo '100')"

  # Stop flood
  kill "${FLOOD_PID}" 2>/dev/null || true
  wait "${FLOOD_PID}" 2>/dev/null || true

  # Merge HAProxy stats into bombardier result JSON
  echo "${RESULT}" | jq --argjson chkfail "${CHKFAIL}" \
    --argjson chkdown "${CHKDOWN}" \
    --argjson downtime "${DOWNTIME}" \
    --arg avail "${AVAIL_PCT}" \
    '. + {haproxy: {chkfail: $chkfail, chkdown: $chkdown, downtime_sec: $downtime, avail_pct: $avail}}'
}

# ---------------------------------------------------------------------------
# Run all scenarios and collect results
# ---------------------------------------------------------------------------

log "=== Poseidon vs Horse Benchmark — ${TIMESTAMP} ==="

declare -A RESULTS

log ""
log "--- PING ---"
RESULTS[poseidon_ping]="$(run_ping_scenario    "Poseidon" "${POSEIDON_URL}")"
RESULTS[horse_ping]="$(run_ping_scenario       "Horse"    "${HORSE_URL}")"

log ""
log "--- PAYLOAD (1KB) ---"
RESULTS[poseidon_payload]="$(run_payload_scenario "Poseidon" "${POSEIDON_URL}")"
RESULTS[horse_payload]="$(run_payload_scenario   "Horse"    "${HORSE_URL}")"

log ""
log "--- ALB SATURATION (NFCe scenario) ---"
RESULTS[poseidon_alb]="$(run_alb_scenario "Poseidon" "${POSEIDON_URL}" "${POSEIDON_HA_URL}" "poseidon")"
RESULTS[horse_alb]="$(run_alb_scenario   "Horse"    "${HORSE_URL}"    "${HORSE_HA_URL}"    "horse")"

# ---------------------------------------------------------------------------
# Write results JSON
# ---------------------------------------------------------------------------

log ""
log "Gravando resultados: ${RESULTS_FILE}"

cat > "${RESULTS_FILE}" <<JSON
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "run_secs": ${RUN_SECS},
  "scenarios": {
    "ping": {
      "poseidon": ${RESULTS[poseidon_ping]},
      "horse":    ${RESULTS[horse_ping]}
    },
    "payload_1kb": {
      "poseidon": ${RESULTS[poseidon_payload]},
      "horse":    ${RESULTS[horse_payload]}
    },
    "alb_saturation": {
      "poseidon": ${RESULTS[poseidon_alb]},
      "horse":    ${RESULTS[horse_alb]}
    }
  }
}
JSON

# ---------------------------------------------------------------------------
# Generate HTML report
# ---------------------------------------------------------------------------

REPORT="${SCRIPT_DIR}/results/bench-report-${TIMESTAMP}.html"
log "Gerando relatório HTML: ${REPORT}"
"${SCRIPT_DIR}/generate-report.sh" "${RESULTS_FILE}" "${REPORT}"

log ""
log "=== Benchmark concluído ==="
log "Resultados JSON: ${RESULTS_FILE}"
log "Relatório HTML:  ${REPORT}"
