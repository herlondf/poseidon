#!/usr/bin/env bash
# diag-send.sh [porta] — captura os logs [SEND ...] durante corrupcao e verifica:
# (1) todo send comeca com header de record TLS valido? (type 14-17, ver 0303)
# (2) sends de um mesmo fd vem de multiplas threads (tid)?
set -u
PORT="${1:-9444}"
WORK=/opt/h2test
cp -f /mnt/d/IA/Projetos/Delphi/Poseidon/tests/h2spec/bin/poseidon-h2spec-server "$WORK/poseidon-h2spec-server"
chmod +x "$WORK/poseidon-h2spec-server"
cd "$WORK"
[ -f server.crt ] || openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost" >/dev/null 2>&1

for attempt in $(seq 1 8); do
  ./poseidon-h2spec-server "$PORT" > s.log 2>&1 &
  SRV=$!
  for j in $(seq 1 40); do grep -q READY s.log && break; sleep 0.25; done
  h2spec -t -k -h 127.0.0.1 -p "$PORT" http2/6 > o.txt 2>&1
  kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null
  if grep -qiE "bad record mac|received record with version" o.txt; then
    echo "attempt $attempt: CORRUPCAO. Analisando [SEND]:"
    echo "  total sends: $(grep -c '\[SEND' s.log)"
    echo "  headers de record DISTINTOS (hdr=XXYYZZ):"
    grep -oE "hdr=[0-9A-F]{6}" s.log | sort | uniq -c | sort -rn | head
    echo "  sends com header TLS INVALIDO (nao 14/15/16/17 + 0303):"
    grep "\[SEND" s.log | grep -vE "hdr=(14|15|16|17)0303" | head -8
    echo "  qtd de tids distintos por fd (multi-thread no mesmo socket?):"
    grep -oE "fd=[0-9]+ len=[0-9]+ hdr" s.log >/dev/null
    grep -oE "tid=[0-9]+ fd=[0-9]+" s.log | awk "{print \$2, \$1}" | sort -u | awk "{c[\$1]++} END{for(f in c) if(c[f]>1) print \"  \" f \" -> \" c[f] \" tids\"}" | head
    exit 0
  fi
  echo "attempt $attempt: sem corrupcao"
done
echo "nao reproduziu em 8 tentativas"
