#!/usr/bin/env bash
set -euo pipefail

BIN="/app/bench-poseidon.linux64"

if [ ! -f "${BIN}" ]; then
  echo "ERROR: ${BIN} not found. Run build-bench.sh first." >&2
  exit 1
fi

chmod +x "${BIN}"
exec "${BIN}"
