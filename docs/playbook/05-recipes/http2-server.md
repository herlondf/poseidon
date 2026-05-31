# HTTP/2 server

HTTP/2 requires SSL. Set `HTTP2Enabled := True` before `ConfigureSSL` so that the
ALPN callback negotiates the `"h2"` protocol during the TLS handshake.

```pascal
program PoseidonH2;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    // Tune HTTP/2 SETTINGS sent to clients
    LServer.H2MaxConcurrentStreams := 200;
    LServer.H2InitialWindowSize    := 1048576;  // 1 MB initial window

    LServer.HTTP2Enabled := True;
    LServer.ConfigureSSL('server.crt', 'server.key');

    LServer.Listen('0.0.0.0', 443,
      procedure(const AReq: TPoseidonNativeRequest;
                out AStatus: Integer; out AContentType: string;
                out ABody: TBytes;
                out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        AStatus      := 200;
        AContentType := 'text/plain';
        ABody        := TEncoding.UTF8.GetBytes('Hello via HTTP/2!');
      end,
      procedure begin
        Writeln('Listening on https://0.0.0.0:443  (h2 + http/1.1)');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
```

## HTTP/2 cleartext (h2c)

No SSL needed. The client sends `Upgrade: h2c` on a plain TCP connection:

```pascal
LServer := TPoseidonNativeServer.Create;
// HTTP2Enabled := True is NOT required for h2c — it is detected from the Upgrade header
LServer.Listen('0.0.0.0', 8080, @HandleRequest, nil);
```

See [h2c-upgrade.md](h2c-upgrade.md) for the full protocol flow and
[`samples/04-http2/`](../../../samples/04-http2/) for a runnable project.
