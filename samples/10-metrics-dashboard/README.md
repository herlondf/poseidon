# Sample 10 — Real-time metrics dashboard (#47)

A self-contained live dashboard (`public/dashboard.html`) that renders the
Poseidon Prometheus metrics with Chart.js: requests/sec, errors/sec, error rate,
and latency percentiles (p50/p95/p99) computed from the histogram buckets. It
polls the `/metrics` endpoint every 2 s and updates live.

## What it consumes

The `MetricsMiddleware` (`middlewares/Poseidon.Middleware.Metrics.pas`) exposes,
in Prometheus text format at `/metrics`:

- `poseidon_requests_total{path}` — counter
- `poseidon_errors_total{path}` — counter (status ≥ 400)
- `poseidon_request_duration_ms_bucket{path,le}` / `_sum` / `_count` — histogram

The dashboard parses these, derives per-second rates from the counter deltas, and
estimates percentiles from the cumulative buckets.

## Wiring it into a server

```pascal
uses
  Poseidon.Native.Types, Poseidon.Native.Server,
  Poseidon.Middleware.Metrics, Poseidon.Middleware.Static;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  // 1. Expose Prometheus metrics.
  App.Use(MetricsMiddleware('/metrics'));
  // 2. Serve the dashboard (this folder's public/ dir) at /dashboard.
  App.Use(StaticMiddleware('/dashboard', './public'));

  App.Get('/ping', procedure(var Ctx: TNativeRequestContext)
    begin Ctx.Status := 200; Ctx.Body := TEncoding.UTF8.GetBytes('pong'); end);

  App.Listen('0.0.0.0', 9001);
end;
```

Then open `http://localhost:9001/dashboard/dashboard.html`. Generate some traffic
(e.g. `hey`, `k6`, or a loop of `curl`) and watch the charts move.

## Serving the page from another origin

If you host `dashboard.html` separately from the server, pass the metrics URL and
enable CORS on the metrics route:

```
dashboard.html?src=http://your-host:9001/metrics
```

## Notes

- Chart.js loads from a CDN (`cdn.jsdelivr.net`) — the page needs internet, or
  vendor the library locally and adjust the `<script src>`.
- The page is theme-aware (honours the OS light/dark preference).
- Percentiles are histogram estimates (bucket granularity), not exact quantiles.
