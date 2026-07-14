#!/usr/bin/env bash
# Isolate the Linux TLS crash: core TLS (no SNI/ALPN) vs SNI vs ALPN.
set -u
WORK=/opt/h2test
cd "$WORK"

run_case() {
  local label="$1"; shift
  : > server.log
  ./poseidon-h2spec-server 9444 >> server.log 2>&1 &
  local pid=$!
  for i in $(seq 1 40); do grep -q READY server.log && break; sleep 0.25; done
  echo | openssl s_client -connect 127.0.0.1:9444 "$@" >/dev/null 2>&1
  sleep 0.3
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if grep -q "AccessViolation" server.log; then
    echo "[$label] => CRASH (AccessViolation)"
  elif grep -qiE "\[recv\].*EX" server.log; then
    echo "[$label] => server exception: $(grep -iE '\[recv\].*EX' server.log | tail -1)"
  else
    echo "[$label] => no crash"
  fi
}

run_case "core TLS (no SNI, no ALPN)" -noservername
run_case "SNI only (servername=localhost)" -servername localhost
run_case "ALPN h2 (+SNI)" -servername localhost -alpn h2
