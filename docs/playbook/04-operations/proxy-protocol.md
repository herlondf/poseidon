# Proxy Protocol

When Poseidon runs behind a load-balancer (nginx, HAProxy, AWS NLB, …), the direct
`RemoteAddr` of each connection is the load-balancer's IP, not the original client IP.
Proxy Protocol (v1/v2) solves this by having the load-balancer prepend the real
client address to every TCP connection.

## Enabling

```pascal
LServer.ProxyProtocol := ppAuto;   // accept v1 or v2 (auto-detect by signature)
// LServer.ProxyProtocol := ppV1;  // enforce v1 only
// LServer.ProxyProtocol := ppV2;  // enforce v2 only
// LServer.ProxyProtocol := ppDisabled;  // default — ignore any PP header
LServer.Listen('0.0.0.0', 9000, @HandleRequest, nil);
```

`ProxyProtocol` must be set before `Listen`.

## Modes

| Value | Meaning |
|-------|---------|
| `ppDisabled` | Proxy Protocol not expected (default) |
| `ppV1` | Expect Proxy Protocol v1 (text format) |
| `ppV2` | Expect Proxy Protocol v2 (binary format) |
| `ppAuto` | Auto-detect v1 vs v2 by signature |

## Effect

When Proxy Protocol is active, `TPoseidonNativeRequest.RemoteAddr` contains the
**original client IP** extracted from the PP header — not the load-balancer IP.
Rate limiting, per-IP connection limits, and metrics all use this resolved address.

## Security warning

**Only enable Proxy Protocol on connections from trusted load-balancers.**  
Accepting PP from untrusted sources allows any client to spoof their IP address.
Use firewall rules or `MaxConnectionsPerIP` to restrict which hosts can connect
to a PP-enabled port.

## Notes

- The PP header is parsed before any HTTP data is processed; malformed headers
  close the connection immediately.
- `ppAuto` adds one branch per connection but has negligible overhead.
