#!/usr/bin/env bash
# Runs inside the throwaway WSL distro. Sets up the h2 target (cert + binary),
# starts it, runs h2spec over TLS, and prints a compact summary + failures.
# Arg 1: path to the Linux ELF (Windows path under /mnt). Arg 2: port.
set -u

ELF="${1:-/mnt/d/IA/Projetos/Delphi/Poseidon/tests/h2spec/bin/poseidon-h2spec-server}"
PORT="${2:-9444}"
WORK=/opt/h2test

mkdir -p "$WORK"
cp -f "$ELF" "$WORK/poseidon-h2spec-server"
chmod +x "$WORK/poseidon-h2spec-server"
cd "$WORK"

if [ ! -f server.crt ]; then
  openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt \
    -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1
fi

# Fail fast if a runtime lib is missing
if ldd poseidon-h2spec-server 2>&1 | grep -qi "not found"; then
  echo "RUNTIME_LIB_MISSING"
  ldd poseidon-h2spec-server 2>&1 | grep -i "not found"
  exit 2
fi

./poseidon-h2spec-server "$PORT" > server.log 2>&1 &
SRVPID=$!

ready=0
for i in $(seq 1 40); do
  if grep -q READY server.log; then ready=1; break; fi
  sleep 0.25
done
if [ "$ready" != "1" ]; then
  echo "SERVER_NOT_READY"; cat server.log; kill "$SRVPID" 2>/dev/null; exit 3
fi

h2spec -t -k -h 127.0.0.1 -p "$PORT" > h2spec.out 2>&1
kill "$SRVPID" 2>/dev/null

echo "===H2SPEC_SUMMARY==="
grep -E "[0-9]+ tests?, [0-9]+ passed|passed, [0-9]+ (skipped, )?[0-9]+ failed|All tests passed" h2spec.out | tail -3
echo "===H2SPEC_FAILURES==="
# h2spec marks failures with a red ✕; strip ANSI then list the failing lines
sed -r 's/\x1b\[[0-9;]*m//g' h2spec.out | grep -E "^\s*✕" | head -60
echo "===END==="
