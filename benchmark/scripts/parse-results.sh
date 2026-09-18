#!/bin/bash
# Parses benchmark/results/raw/<framework>.log (wrk + bench.lua output) into
# the "Performance vs. the Field" Markdown table, ranked by throughput.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RAW="$ROOT/results/raw"

FRAMEWORKS=("$@")
[ ${#FRAMEWORKS[@]} -eq 0 ] && FRAMEWORKS=(uws actix poseidon-v2 gofiber mormot2 nginx horse-epoll kestrel)

display_name() {
  case "$1" in
    uws) echo "uws" ;;
    actix) echo "Actix" ;;
    poseidon-v2) echo "Poseidon v2" ;;
    gofiber) echo "Go Fiber" ;;
    mormot2) echo "mORMot2" ;;
    nginx) echo "nginx" ;;
    horse-epoll) echo "Horse" ;;
    kestrel) echo "Kestrel" ;;
    *) echo "$1" ;;
  esac
}

display_tech() {
  case "$1" in
    uws) echo "C++" ;;
    actix) echo "Rust" ;;
    poseidon-v2) echo "Object Pascal" ;;
    gofiber) echo "Go" ;;
    mormot2) echo "Object Pascal" ;;
    nginx) echo "C" ;;
    horse-epoll) echo "Object Pascal" ;;
    kestrel) echo "C#/.NET" ;;
    *) echo "?" ;;
  esac
}

TMP="$(mktemp)"

for fw in "${FRAMEWORKS[@]}"; do
  log="$RAW/$fw.log"
  if [ ! -s "$log" ]; then
    echo "-1|$fw|$(display_name "$fw")|$(display_tech "$fw")|no data|no data|no data|no data" >> "$TMP"
    continue
  fi

  reqps=$(grep -oP 'Requests/sec:\s*\K[0-9.]+' "$log" | head -1)
  errline=$(grep 'connect=' "$log" | head -1)
  connect=$(echo "$errline" | grep -oP 'connect=\K[0-9]+')
  readerr=$(echo "$errline" | grep -oP 'read=\K[0-9]+')
  writeerr=$(echo "$errline" | grep -oP 'write=\K[0-9]+')
  timeouterr=$(echo "$errline" | grep -oP 'timeout=\K[0-9]+')
  statuserr=$(echo "$errline" | grep -oP 'status=\K[0-9]+')
  p50us=$(grep -oP 'p50=\K[0-9]+' "$log" | head -1)
  p99us=$(grep -oP 'p99=\K[0-9]+' "$log" | head -1)
  maxus=$(grep -oP 'max=\K[0-9]+' "$log" | tail -1)

  if [ -z "$reqps" ] || [ -z "$p50us" ] || [ -z "$p99us" ]; then
    echo "-1|$fw|$(display_name "$fw")|$(display_tech "$fw")|parse error|parse error|parse error|parse error" >> "$TMP"
    continue
  fi

  errors=$(( ${connect:-0} + ${readerr:-0} + ${writeerr:-0} + ${timeouterr:-0} + ${statuserr:-0} ))
  p50ms=$(awk "BEGIN{printf \"%.2f\", $p50us/1000}")
  p99ms=$(awk "BEGIN{printf \"%.2f\", $p99us/1000}")
  maxms=$(awk "BEGIN{printf \"%.0f\", ${maxus:-0}/1000}")
  reqps_fmt=$(awk "BEGIN{printf \"%.0f\", $reqps}")

  echo "$reqps|$fw|$(display_name "$fw")|$(display_tech "$fw")|${p50ms} ms|${p99ms} ms|${maxms} ms|$errors" >> "$TMP"
done

echo "| Posição | Framework | Tecnologia | Req/s | p50 | p99 | Máx | Erros |"
echo "|---:|---|---|---:|---:|---:|---:|---:|"

rank=1
sort -t'|' -k1 -rn "$TMP" | while IFS='|' read -r reqps fw name tech p50 p99 max errors; do
  if [ "$reqps" = "-1" ]; then
    echo "| — | $name | $tech | $p50 | $p99 | $max | $errors |"
  else
    reqps_fmt=$(awk "BEGIN{printf \"%.0f\", $reqps}" | sed ':a;s/\B[0-9]\{3\}\>/.&/;ta')
    echo "| $rank | $name | $tech | $reqps_fmt | $p50 | $p99 | $max | $errors |"
  fi
  rank=$((rank + 1))
done

rm -f "$TMP"
