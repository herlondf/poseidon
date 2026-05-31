# When to use Poseidon

## Good fit

- High-concurrency HTTP APIs on Linux or Windows where latency matters
- Replacing Indy or Delphi-Cross-Socket as the transport layer in Horse/Pegasus
- Scenarios where you need WebSocket alongside HTTP on the same port
- Zero-dependency deployments (no vcl, no indy, no cross-socket DLL)

## Not a fit

- 32-bit targets (io_uring/epoll/IOCP implementation is 64-bit only)
- macOS / ARM targets (not implemented)
- Applications that need full WebBroker middleware pipeline without Horse or Pegasus
  (use `Poseidon.Net.WebAdapters.Native` as bridge, but the glue code is your responsibility)

## Comparison

| | Poseidon | Indy | Delphi-Cross-Socket |
|---|---|---|---|
| External deps | none | none | CnPack (crypto) |
| Linux io_uring (kernel ≥ 5.1) | ✅ | ❌ | ❌ |
| Linux epoll (fallback) | ✅ | ❌ | ✅ |
| Windows IOCP | ✅ | ❌ (blocking) | ✅ |
| HTTP/2 | ✅ | ❌ | ❌ |
| WebSocket | ✅ | partial | ✅ |
| Single send | ✅ | ❌ | ❌ |
