# Security hardening

A hardened server with HTTP verb allowlist, size limits, backpressure,
secure headers, and suppressed server banner.

```pascal
program PoseidonSecure;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    LServer.AllowedMethods       := ['GET', 'POST', 'HEAD', 'OPTIONS'];
    LServer.MaxRequestSize       := 1 * 1024 * 1024;  // 1 MB — 413 on exceed
    LServer.MaxHeaderSize        := 16384;             // 16 KB — 400 on exceed
    LServer.MaxQueueDepth        := 200;               // 503 when full
    LServer.SecureHeadersEnabled := True;              // X-Content-Type-Options etc.
    LServer.ServerBanner         := '';                // suppress Server: header

    LServer.Listen('0.0.0.0', 9006,
      procedure(const AReq: TPoseidonNativeRequest;
                out AStatus: Integer; out AContentType: string;
                out ABody: TBytes;
                out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        AStatus      := 200;
        AContentType := 'application/json';
        ABody        := TEncoding.UTF8.GetBytes('{"ok":true}');
      end,
      procedure begin
        Writeln('Hardened server on :9006 — press Enter to stop');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
```

**Built-in protections (always active, no code needed):**
- Path traversal (`..`, `%2e%2e`, `\`, NUL) → `400`
- Request smuggling (CL + TE:chunked) → `400`
- CRLF injection in response headers → stripped silently

See [security.md](../04-operations/security.md) for property details and
[`samples/06-security/`](../../../samples/06-security/) for the full project.
