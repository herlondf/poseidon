program Poseidon.Sample.HTTP2;

// Sample 04 — HTTP/2 (h2 via ALPN) (Native API)
// Demonstrates HTTP/2 enabled via ALPN negotiation over TLS.
// HTTP/1.1 clients on the same port still work transparently.
//
// Prerequisites:
//   OpenSSL libssl / libcrypto in PATH.
//   Self-signed cert:
//     openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost"
//
// Run:
//   Poseidon.Sample.HTTP2.exe
//   curl -k --http2 https://localhost:9444/ping           # HTTP/2
//   curl -k --http1.1 https://localhost:9444/ping         # HTTP/1.1 fallback

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

const
  CServerPort = 9444;
  CServerCert = 'server.crt';
  CServerKey = 'server.key';

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.ConfigureSSL(CServerCert, CServerKey);
    App.EnableHTTP2;

    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes(
          Format('{"path":"%s","h2":true}', [Ctx.Path]));
      end);

    Writeln('Poseidon Sample 04 — HTTP/2');
    Writeln('Listening on https://0.0.0.0:', CServerPort, '  (h2 + http/1.1)');
    Writeln('  GET /ping -> {"path":"/ping","h2":true}');
    Writeln;

    App.Listen(CServerPort, '0.0.0.0',
      procedure
      begin
        Writeln('Server ready. Press Enter to stop...');
        Readln;
        App.Stop;
      end);
  finally
    App.Free;
  end;
end.
