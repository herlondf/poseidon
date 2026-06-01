#!/usr/bin/env bash
# benchmark/linux/run-benchmark.sh
# Executa os cenários de benchmark do Poseidon (Linux/Docker).
#
# Pré-requisitos:
#   - Docker Compose (compose.yml na mesma pasta)
#   - bombardier instalado no PATH ou em assets/bombardier
#   - bench-poseidon.linux64 presente em assets/ (gerado por run-bench.ps1)
#   - jq instalado
#
# Uso:
#   cd benchmark/linux
#   ./run-benchmark.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RESULTS_FILE="${RESULTS_DIR}/bench-results-${TIMESTAMP}.json"

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

POSEIDON_URL="http://localhost:18080"

WARMUP_SECS=8
RUN_SECS=60

PING_CLIENTS=500
PAYLOAD_CLIENTS=100

mkdir -p "${RESULTS_DIR}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date +%H:%M:%S)] $*" >&2; }

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found. Install it and retry." >&2
    exit 1
  fi
}

require_cmd docker
require_cmd jq

BOMBARDIER_CMD="${BOMBARDIER_CMD:-bombardier}"
if ! command -v bombardier &>/dev/null; then
  BOMBARDIER_BIN="${SCRIPT_DIR}/assets/bombardier"
  if [ -f "${BOMBARDIER_BIN}" ]; then
    BOMBARDIER_CMD="${BOMBARDIER_BIN}"
  else
    echo "ERROR: bombardier not found. Download from https://github.com/codesenberg/bombardier/releases" >&2
    echo "  and place at ${BOMBARDIER_BIN}" >&2
    exit 1
  fi
fi

# Run bombardier and return JSON result on stdout
run_bombardier() {
  local URL="$1"
  local CLIENTS="$2"
  local DURATION="${3:-${RUN_SECS}}"

  "${BOMBARDIER_CMD}" -c "${CLIENTS}" -d "${DURATION}s" --print r --format json -l \
    "${URL}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Check services are up
# ---------------------------------------------------------------------------

log "Verificando serviços Docker..."
for SVC in poseidon; do
  RAW_STATUS="$(docker inspect --format='{{.State.Health.Status}}' "${SVC}" 2>/dev/null || true)"
  STATUS="$(printf '%s' "${RAW_STATUS}" | tr -d '\r\n' | xargs || true)"
  if [ -z "${STATUS}" ]; then STATUS="unknown"; fi
  log "  ${SVC}: status='${STATUS}'"
  if [ "${STATUS}" != "healthy" ] && [ "${STATUS}" != "unknown" ]; then
    echo "ERROR: Serviço '${SVC}' não está healthy (status: ${STATUS})." >&2
    echo "  Execute: docker compose up -d poseidon && sleep 10" >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# SCENARIO 1: Ping — latência mínima, alta concorrência
# ---------------------------------------------------------------------------

run_ping_scenario() {
  log "Cenário PING (${PING_CLIENTS} clientes, ${RUN_SECS}s)"
  log "  Warmup ${WARMUP_SECS}s..."
  run_bombardier "${POSEIDON_URL}/ping" "${PING_CLIENTS}" "${WARMUP_SECS}" >/dev/null

  log "  Run..."
  run_bombardier "${POSEIDON_URL}/ping" "${PING_CLIENTS}" "${RUN_SECS}"
}

# ---------------------------------------------------------------------------
# SCENARIO 2: Payload médio (~1KB) — throughput com body
# ---------------------------------------------------------------------------

run_payload_scenario() {
  log "Cenário PAYLOAD 1KB (${PAYLOAD_CLIENTS} clientes, ${RUN_SECS}s)"
  log "  Warmup ${WARMUP_SECS}s..."
  run_bombardier "${POSEIDON_URL}/medium" "${PAYLOAD_CLIENTS}" "${WARMUP_SECS}" >/dev/null

  log "  Run..."
  run_bombardier "${POSEIDON_URL}/medium" "${PAYLOAD_CLIENTS}" "${RUN_SECS}"
}

# ---------------------------------------------------------------------------
# Run scenarios
# ---------------------------------------------------------------------------

log "=== Poseidon Benchmark — ${TIMESTAMP} ==="

log ""
log "--- PING ---"
RESULT_PING="$(run_ping_scenario)"

log ""
log "--- PAYLOAD (1KB) ---"
RESULT_PAYLOAD="$(run_payload_scenario)"

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
    "ping":        ${RESULT_PING},
    "payload_1kb": ${RESULT_PAYLOAD}
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
