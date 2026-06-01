#!/usr/bin/env bash
# benchmark/linux/generate-report.sh
# Lê um arquivo JSON de resultados e gera um relatório HTML com Plotly.js.
#
# Uso:
#   ./generate-report.sh bench-results-<timestamp>.json report.html

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
  jq -r "(${1}) // \"N/A\"" "${INPUT}"
}

extract_num() {
  jq -r "(${1}) // 0" "${INPUT}"
}

TIMESTAMP="$(extract '.timestamp')"

# Ping — latência em microsegundos → ms (÷ 1000)
PING_RPS="$(extract_num '.scenarios.ping.result.rps.mean')"
PING_P50="$(extract_num '(.scenarios.ping.result.latency.mean // 0) / 1000')"
PING_P95="$(extract_num '(.scenarios.ping.result.latency.percentiles["95"] // 0) / 1000')"
PING_P99="$(extract_num '(.scenarios.ping.result.latency.percentiles["99"] // 0) / 1000')"
PING_2XX="$(extract_num '.scenarios.ping.result.req2xx')"

# Payload
PAYLOAD_RPS="$(extract_num '.scenarios.payload_1kb.result.rps.mean')"
PAYLOAD_P50="$(extract_num '(.scenarios.payload_1kb.result.latency.mean // 0) / 1000')"
PAYLOAD_P95="$(extract_num '(.scenarios.payload_1kb.result.latency.percentiles["95"] // 0) / 1000')"
PAYLOAD_P99="$(extract_num '(.scenarios.payload_1kb.result.latency.percentiles["99"] // 0) / 1000')"
PAYLOAD_2XX="$(extract_num '.scenarios.payload_1kb.result.req2xx')"

# ---------------------------------------------------------------------------
# Substitute placeholders in template
# ---------------------------------------------------------------------------

sed \
  -e "s|{{TIMESTAMP}}|${TIMESTAMP}|g" \
  -e "s|{{PING_RPS}}|${PING_RPS}|g" \
  -e "s|{{PING_P50}}|${PING_P50}|g" \
  -e "s|{{PING_P95}}|${PING_P95}|g" \
  -e "s|{{PING_P99}}|${PING_P99}|g" \
  -e "s|{{PING_2XX}}|${PING_2XX}|g" \
  -e "s|{{PAYLOAD_RPS}}|${PAYLOAD_RPS}|g" \
  -e "s|{{PAYLOAD_P50}}|${PAYLOAD_P50}|g" \
  -e "s|{{PAYLOAD_P95}}|${PAYLOAD_P95}|g" \
  -e "s|{{PAYLOAD_P99}}|${PAYLOAD_P99}|g" \
  -e "s|{{PAYLOAD_2XX}}|${PAYLOAD_2XX}|g" \
  "${TEMPLATE}" > "${OUTPUT}"

echo "Relatório gerado: ${OUTPUT}"
