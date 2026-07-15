#!/usr/bin/env bash
# capture-11.sh [porta] — captura o stream TLS durante um run h2spec que corrompe
# e caminha os records p/ achar o mecanismo (drop/dup/interleave).
set -u
PORT="${1:-9444}"
WORK=/opt/h2test
cd "$WORK" || exit 1
[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

for attempt in $(seq 1 10); do
  ./poseidon-h2spec-server "$PORT" > server.log 2>&1 &
  SRV=$!
  for j in $(seq 1 40); do grep -q READY server.log && break; sleep 0.25; done

  rm -f cap.pcap
  tcpdump -i lo -U -w cap.pcap "tcp port $PORT" >/dev/null 2>&1 &
  TCP=$!
  sleep 0.4
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/6 > o.txt 2>&1
  sleep 0.3
  kill "$TCP" 2>/dev/null; wait "$TCP" 2>/dev/null
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null

  if grep -qiE "bad record mac|received record with version|decryption failed" o.txt; then
    echo "attempt $attempt: CORRUPCAO capturada. Sinal do cliente:"
    grep -iE "bad record mac|received record with version" o.txt | head -2
    echo "--- record walk ---"
    python3 /mnt/d/IA/Projetos/Delphi/Poseidon/tests/h2spec/walk-records.py cap.pcap "$PORT"
    echo "--- server.log (erros?) ---"
    grep -iE "_EX|WORKER|EAccess|error|ssl" server.log | head -10
    exit 0
  fi
  echo "attempt $attempt: sem corrupcao, repetindo..."
done
echo "nao reproduziu corrupcao em 10 tentativas"
