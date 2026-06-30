#!/bin/bash
# generate-report.sh — Generates HTML comparison report from bombardier JSON results.
# Usage: bash scripts/generate-report.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_DIR="$(dirname "$SCRIPT_DIR")"
REPORT="$BASE_DIR/results/report.html"

# Collect results from both platforms
get_metric() {
    local file="$1"
    local jq_expr="$2"
    if [ -f "$file" ]; then
        python3 -c "
import json, sys
try:
    d = json.load(open('$file'))
    val = $jq_expr
    print(f'{val:.2f}')
except:
    print('N/A')
" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# Build HTML
cat > "$REPORT" << 'HTMLHEAD'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<title>Poseidon Benchmark Comparison</title>
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
         background: #1a1a2e; color: #e0e0e0; margin: 40px; }
  h1 { color: #00d4ff; border-bottom: 2px solid #00d4ff; padding-bottom: 10px; }
  h2 { color: #7fdbca; margin-top: 40px; }
  table { border-collapse: collapse; width: 100%; margin: 20px 0; }
  th { background: #16213e; color: #00d4ff; padding: 12px 16px; text-align: right;
       border-bottom: 2px solid #00d4ff; }
  th:first-child { text-align: left; }
  td { padding: 10px 16px; text-align: right; border-bottom: 1px solid #333; }
  td:first-child { text-align: left; font-weight: bold; color: #7fdbca; }
  tr:hover { background: #1f2b47; }
  .winner { color: #00ff88; font-weight: bold; }
  .meta { color: #888; font-size: 0.85em; margin-top: 30px; }
  .badge { display: inline-block; padding: 2px 8px; border-radius: 4px;
           font-size: 0.8em; margin-left: 8px; }
  .badge-1 { background: #00ff88; color: #000; }
  .badge-2 { background: #ffaa00; color: #000; }
  .badge-3 { background: #666; color: #fff; }
</style>
</head>
<body>
<h1>Poseidon Benchmark Comparison</h1>
<p>Methodology: <strong>bombardier</strong> — 100 connections, 20,000 requests (upload: 200 requests with 5MB payload)</p>
HTMLHEAD

# Generate table for a platform
generate_table() {
    local platform=$1
    local dir="$BASE_DIR/results/${platform}64"
    local title=$2

    if [ ! -d "$dir" ] || [ -z "$(ls -A "$dir" 2>/dev/null)" ]; then
        return
    fi

    echo "<h2>$title</h2>"
    echo '<table>'
    echo '<tr><th>Provider</th><th>Ping (RPS)</th><th>Ping Lat (ms)</th>'
    echo '<th>JSON (RPS)</th><th>JSON Lat (ms)</th>'
    echo '<th>Upload (RPS)</th><th>Upload Lat (ms)</th>'
    echo '<th>Delay (RPS)</th><th>Delay Lat (ms)</th></tr>'

    for name in "Poseidon" "Horse+Indy" "Horse+Poseidon"; do
        local has_data=false
        for sc in ping json upload delay; do
            [ -f "$dir/${name}-${sc}.json" ] && has_data=true && break
        done
        $has_data || continue

        echo -n "<tr><td>$name</td>"
        for sc in ping json upload delay; do
            local f="$dir/${name}-${sc}.json"
            local rps=$(get_metric "$f" "d['result']['rps']['mean']")
            local lat=$(get_metric "$f" "d['result']['latency']['mean'] / 1000000")
            echo -n "<td>$rps</td><td>$lat</td>"
        done
        echo "</tr>"
    done

    echo '</table>'
}

{
    generate_table "win" "Windows (Win64)"
    generate_table "linux" "Linux (WSL2 Totvs — Ubuntu 24.04)"

    echo "<div class='meta'>"
    echo "<p>Generated: $(date -u '+%Y-%m-%d %H:%M UTC')</p>"
    echo "<p>bombardier -c 100 -n 20000 | Upload: -c 100 -n 200 -m POST -f payload5mb.bin</p>"
    echo "</div>"
    echo "</body></html>"
} >> "$REPORT"

echo "Report generated: $REPORT"
