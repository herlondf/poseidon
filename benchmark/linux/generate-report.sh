#!/usr/bin/env bash
# benchmark/linux/generate-report.sh
# Lê um arquivo JSON de resultados e gera um relatório HTML com Plotly.js.
#
# Uso:
#   ./generate-report.sh bench-results-20260531-120000.json report.html

set -euo pipefail

INPUT="${1:?usage: generate-report.sh <results.json> <output.html>}"
OUTPUT="${2:?usage: generate-report.sh <results.json> <output.html>}"
TEMPLATE="$(dirname "${BASH_SOURCE[0]}")/report-template.html"

if [ ! -f "${INPUT}" ]; then
  echo "ERROR: ${INPUT} not found" >&2
  exit 1
fi

if [ ! -f "${TEMPLATE}" ]; then
  echo "ERROR: ${TEMPLATE} not found" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" &>/dev/null; then
    echo "ERROR: '$1' not found" >&2
    exit 1
  fi
}
require_cmd jq

# ---------------------------------------------------------------------------
# Extract metrics from JSON
# ---------------------------------------------------------------------------

extract() {
  local PATH_="$1"
  jq -r "${PATH_} // \"N/A\"" "${INPUT}"
}

extract_num() {
  local PATH_="$1"
  jq -r "${PATH_} // 0" "${INPUT}"
}

TIMESTAMP="$(extract '.timestamp')"

# Ping scenario
P_PING_RPS="$(extract_num '.scenarios.ping.poseidon.result.rps.mean')"
H_PING_RPS="$(extract_num '.scenarios.ping.horse.result.rps.mean')"
P_PING_P50="$(extract_num '.scenarios.ping.poseidon.result.latencies.mean / 1000000')"
H_PING_P50="$(extract_num '.scenarios.ping.horse.result.latencies.mean / 1000000')"
P_PING_P95="$(extract_num '.scenarios.ping.poseidon.result.latencies.percentile95 / 1000000')"
H_PING_P95="$(extract_num '.scenarios.ping.horse.result.latencies.percentile95 / 1000000')"
P_PING_P99="$(extract_num '.scenarios.ping.poseidon.result.latencies.percentile99 / 1000000')"
H_PING_P99="$(extract_num '.scenarios.ping.horse.result.latencies.percentile99 / 1000000')"

# Payload scenario
P_PL_RPS="$(extract_num '.scenarios.payload_1kb.poseidon.result.rps.mean')"
H_PL_RPS="$(extract_num '.scenarios.payload_1kb.horse.result.rps.mean')"
P_PL_P95="$(extract_num '.scenarios.payload_1kb.poseidon.result.latencies.percentile95 / 1000000')"
H_PL_P95="$(extract_num '.scenarios.payload_1kb.horse.result.latencies.percentile95 / 1000000')"

# ALB saturation
P_ALB_RPS="$(extract_num '.scenarios.alb_saturation.poseidon.result.rps.mean')"
H_ALB_RPS="$(extract_num '.scenarios.alb_saturation.horse.result.rps.mean')"
P_ALB_AVAIL="$(extract '.scenarios.alb_saturation.poseidon.haproxy.avail_pct')"
H_ALB_AVAIL="$(extract '.scenarios.alb_saturation.horse.haproxy.avail_pct')"
P_ALB_DT="$(extract_num '.scenarios.alb_saturation.poseidon.haproxy.downtime_sec')"
H_ALB_DT="$(extract_num '.scenarios.alb_saturation.horse.haproxy.downtime_sec')"

# ---------------------------------------------------------------------------
# Substitute placeholders in template
# ---------------------------------------------------------------------------

sed \
  -e "s|{{TIMESTAMP}}|${TIMESTAMP}|g" \
  -e "s|{{P_PING_RPS}}|${P_PING_RPS}|g" \
  -e "s|{{H_PING_RPS}}|${H_PING_RPS}|g" \
  -e "s|{{P_PING_P50}}|${P_PING_P50}|g" \
  -e "s|{{H_PING_P50}}|${H_PING_P50}|g" \
  -e "s|{{P_PING_P95}}|${P_PING_P95}|g" \
  -e "s|{{H_PING_P95}}|${H_PING_P95}|g" \
  -e "s|{{P_PING_P99}}|${P_PING_P99}|g" \
  -e "s|{{H_PING_P99}}|${H_PING_P99}|g" \
  -e "s|{{P_PL_RPS}}|${P_PL_RPS}|g" \
  -e "s|{{H_PL_RPS}}|${H_PL_RPS}|g" \
  -e "s|{{P_PL_P95}}|${P_PL_P95}|g" \
  -e "s|{{H_PL_P95}}|${H_PL_P95}|g" \
  -e "s|{{P_ALB_RPS}}|${P_ALB_RPS}|g" \
  -e "s|{{H_ALB_RPS}}|${H_ALB_RPS}|g" \
  -e "s|{{P_ALB_AVAIL}}|${P_ALB_AVAIL}|g" \
  -e "s|{{H_ALB_AVAIL}}|${H_ALB_AVAIL}|g" \
  -e "s|{{P_ALB_DT}}|${P_ALB_DT}|g" \
  -e "s|{{H_ALB_DT}}|${H_ALB_DT}|g" \
  "${TEMPLATE}" > "${OUTPUT}"

echo "Relatório gerado: ${OUTPUT}"
