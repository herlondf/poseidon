-- bench-compare-wrk.lua
-- Mix ponderado 40% /plaintext + 30% /json + 30% /json-large, mesmas
-- proporcoes/estilo do bench-json-sizes.lua usado no comparativo Poseidon
-- vs Horse. Agrega contagem real por endpoint via thread:get/set.

threads = {}

function setup(thread)
   thread:set("id", #threads + 1)
   table.insert(threads, thread)
end

function init(args)
   requests_plaintext = 0
   requests_json = 0
   requests_json_large = 0
   math.randomseed(os.time() + id)
end

request = function()
   local r = math.random()
   if r < 0.4 then
      requests_plaintext = requests_plaintext + 1
      return wrk.format("GET", "/plaintext")
   elseif r < 0.7 then
      requests_json = requests_json + 1
      return wrk.format("GET", "/json")
   else
      requests_json_large = requests_json_large + 1
      return wrk.format("GET", "/json-large")
   end
end

function done(summary, latency, requests)
   local total_pt, total_json, total_large = 0, 0, 0
   for _, thread in ipairs(threads) do
      total_pt = total_pt + (thread:get("requests_plaintext") or 0)
      total_json = total_json + (thread:get("requests_json") or 0)
      total_large = total_large + (thread:get("requests_json_large") or 0)
   end
   io.write("\n=== breakdown por endpoint (requests gerados) ===\n")
   io.write(string.format("/plaintext:  %d (%.1f%%)\n", total_pt, 100 * total_pt / summary.requests))
   io.write(string.format("/json:       %d (%.1f%%)\n", total_json, 100 * total_json / summary.requests))
   io.write(string.format("/json-large: %d (%.1f%%)\n", total_large, 100 * total_large / summary.requests))
   io.write(string.format("\n=== erros ===\nconnect=%d read=%d write=%d timeout=%d status=%d\n",
      summary.errors.connect, summary.errors.read, summary.errors.write,
      summary.errors.timeout, summary.errors.status))
   io.write(string.format("\n=== percentis (us) ===\np50=%d p90=%d p95=%d p99=%d max=%d\n",
      latency:percentile(50), latency:percentile(90), latency:percentile(95),
      latency:percentile(99), latency.max))
end
