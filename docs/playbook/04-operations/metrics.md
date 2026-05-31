# Prometheus metrics

Poseidon can expose an HTTP endpoint that returns server metrics in
[Prometheus exposition format](https://prometheus.io/docs/instrumenting/exposition_formats/) 0.0.4.

## Enabling the endpoint

```pascal
LServer.MetricsEnabled     := True;
LServer.MetricsPath        := '/metrics';    // default
LServer.MetricsAllowedCIDR := '10.0.0.0/8'; // optional — restrict scraping to internal network
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

`MetricsEnabled` must be set before `Listen`.

## Scraping

```
GET /metrics
```

Returns a plain-text response (`Content-Type: text/plain; version=0.0.4`) with all
exposed metrics. Standard Prometheus scrape interval is 15–60 s.

## Restricting access

`MetricsAllowedCIDR` accepts an IPv4 CIDR block. Scrape requests from outside the
block receive `403 Forbidden`. Set to `''` (default) to allow any source.

```pascal
LServer.MetricsAllowedCIDR := '172.16.0.0/12';  // only internal Docker / VPC networks
```

## Programmatic access

The read-only `Metrics` property exposes the `TPoseidonMetrics` object for custom
instrumentation from inside the request handler:

```pascal
LServer.Metrics.IncrementCounter('my_custom_requests_total');
```

`Metrics` is `nil` when `MetricsEnabled = False` — check before accessing.

## Notes

- Metrics are updated atomically; the `/metrics` endpoint is safe to scrape concurrently.
- The endpoint is served by the same worker pool as regular requests.
- Do not expose `/metrics` on a public port without `MetricsAllowedCIDR` or an external proxy.
