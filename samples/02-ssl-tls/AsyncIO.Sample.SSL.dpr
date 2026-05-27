program AsyncIO.Sample.SSL;

// Sample 02 — SSL/TLS + SNI
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
//   AsyncIO.Sample.SSL.exe
//   curl -k https://localhost:9443/ping
//   curl -k --resolve api.example.com:9443:127.0.0.1 https://api.example.com:9443/ping

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Generics.Collections,
  AsyncIO.Net.HttpServer;

const
  SERVER_PORT    = 9443;
  DEFAULT_CERT   = 'default.crt';
  DEFAULT_KEY    = 'default.key';
  API_CERT       = 'api.crt';
  API_KEY        = 'api.key';
  API_HOSTNAME   = 'api.example.com';

procedure HandleRequest(
  const AReq:          TAsyncIONativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string, string>>);
var
  LJson: string;
begin
  AExtraHeaders := [];
  AStatus       := 200;
  AContentType  := 'application/json';
  LJson         := Format(
    '{"path":"%s","method":"%s","tls":true}',
    [AReq.Path, AReq.Method]);
  ABody := TEncoding.UTF8.GetBytes(LJson);
end;

var
  LServer: TAsyncIONativeServer;
begin
  LServer := TAsyncIONativeServer.Create;
  try
    // Default certificate — used when no SNI matches or client sends no SNI
    LServer.ConfigureSSL(DEFAULT_CERT, DEFAULT_KEY);

    // Additional certificate for a specific hostname (SNI)
    if FileExists(API_CERT) then
      LServer.AddSSLCert(API_HOSTNAME, API_CERT, API_KEY);

    Writeln('AsyncIO Sample 02 — SSL/TLS + SNI');
    Writeln('Listening on https://0.0.0.0:', SERVER_PORT);
    Writeln;

    LServer.Listen('0.0.0.0', SERVER_PORT,
      HandleRequest,
      procedure
      begin
        Writeln('Server ready. Press Enter to stop...');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
