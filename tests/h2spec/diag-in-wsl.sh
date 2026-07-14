#!/usr/bin/env bash
# Diagnose the h2-over-TLS activation: does ALPN negotiate "h2", and what does
# the server do when a client sends the HTTP/2 preface?
set -u
WORK=/opt/h2test
mkdir -p "$WORK"
cp -f /mnt/d/IA/Projetos/Delphi/Poseidon/tests/h2spec/bin/poseidon-h2spec-server "$WORK/"
chmod +x "$WORK/poseidon-h2spec-server"
cd "$WORK"
[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

./poseidon-h2spec-server 9444 > server.log 2>&1 &
SRVPID=$!
for i in $(seq 1 40); do grep -q READY server.log && break; sleep 0.25; done

echo "=== ALPN negotiation (openssl s_client -alpn h2) ==="
echo | openssl s_client -connect 127.0.0.1:9444 -alpn h2 -quiet 2>&1 | grep -iE "ALPN|protocol|verify|error" | head -8

echo "=== server.log after connect ==="
cat server.log

kill "$SRVPID" 2>/dev/null
