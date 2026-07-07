program Poseidon.Sample.SSL;

// Sample 02 — SSL/TLS + SNI (Native API)
// Demonstrates HTTPS setup with a primary certificate and SNI-based
// additional certificates for multiple hostnames on the same port.
//
// Prerequisites:
//   OpenSSL libssl / libcrypto in PATH (or same folder as binary).
//   Self-signed certs for testing:
//     openssl req -x509 -newkey rsa:2048 -keyout default.key -out default.crt -days 365 -nodes -subj "/CN=localhost"
//     openssl req -x509 -newkey rsa:2048 -keyout api.key    -out api.crt    -days 365 -nodes -subj "/CN=api.example.com"
//
// Run:
//   Poseidon.Sample.SSL.exe
//   curl -k https://localhost:9443/ping
//   curl -k --resolve api.example.com:9443:127.0.0.1 https://api.example.com:9443/ping

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

const
  CServerPort = 9443;
  CDefaultCert = 'default.crt';
  CDefaultKey = 'default.key';
  CApiCert = 'api.crt';
  CApiKey = 'api.key';
  CApiHostname = 'api.example.com';

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.ConfigureSSL(CDefaultCert, CDefaultKey);
    if FileExists(CApiCert) then
      App.AddSSLCert(CApiHostname, CApiCert, CApiKey);

    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes(
          Format('{"path":"%s","method":"%s","tls":true}',
            [Ctx.Path, Ctx.Method]));
      end);

    Writeln('Poseidon Sample 02 — SSL/TLS + SNI');
    Writeln('Listening on https://0.0.0.0:', CServerPort);
    Writeln('  GET /ping -> {"path":"/ping","method":"GET","tls":true}');
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
