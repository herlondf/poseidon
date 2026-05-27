program AsyncIO.Sample.HTTP2;

// Sample 04 — HTTP/2 (h2 via ALPN)
// Demonstrates HTTP/2 enabled via ALPN negotiation over TLS.
// Requires ConfigureSSL to be called before EnableHTTP2.
// HTTP/1.1 clients on the same port still work transparently
// (ALPN falls back when client doesn't advertise h2).
//
// Prerequisites:
//   OpenSSL libssl / libcrypto in PATH.
//   Self-signed cert:
//     openssl req -x509 -newkey rsa:2048 -keyout server.key -out server.crt -days 365 -nodes -subj "/CN=localhost"
//
// Run:
//   AsyncIO.Sample.HTTP2.exe
//   curl -k --http2 https://localhost:9444/ping           # HTTP/2
//   curl -k --http1.1 https://localhost:9444/ping         # HTTP/1.1 fallback

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Generics.Collections,
  AsyncIO.Net.HttpServer;

const
  SERVER_PORT  = 9444;
  SERVER_CERT  = 'server.crt';
  SERVER_KEY   = 'server.key';

procedure HandleRequest(
  const AReq:          TAsyncIONativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string, string>>);
begin
  AExtraHeaders := [];
  AStatus       := 200;
  AContentType  := 'application/json';

  ABody := TEncoding.UTF8.GetBytes(
    Format('{"path":"%s","tls":true}', [AReq.Path]));
end;

var
  LServer: TAsyncIONativeServer;
begin
  LServer := TAsyncIONativeServer.Create;
  try
    // Order: ConfigureSSL → HTTP2Enabled → Listen
    LServer.ConfigureSSL(SERVER_CERT, SERVER_KEY);
    LServer.HTTP2Enabled := True;

    Writeln('AsyncIO Sample 04 — HTTP/2');
    Writeln('Listening on https://0.0.0.0:', SERVER_PORT, '  (h2 + http/1.1)');
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
