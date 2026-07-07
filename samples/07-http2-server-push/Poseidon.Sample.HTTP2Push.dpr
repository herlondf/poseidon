program Poseidon.Sample.HTTP2Push;

// Sample 07 — HTTP/2 Server Push (Native API)
// Demonstrates proactive asset delivery via OnH2Push.
//
// What this sample shows:
//   - Registering an OnH2Push callback to push a CSS file with the main page
//   - How TPoseidonPushResource is filled in
//   - Fallback: non-h2 clients (HTTP/1.1) receive the HTML without push
//
// How to run:
//   1. Place a valid PEM certificate pair as:
//        samples\certs\test-server.crt
//        samples\certs\test-server.key
//   2. Compile and run. Then open https://localhost:9007/ in a browser
//      that supports HTTP/2 and inspect the "Initiator" column in DevTools
//      to see /style.css loaded as "Push" instead of "Request".
//
// To test from the command line (requires curl >= 7.36 with nghttp2):
//   curl --http2 -k -v https://localhost:9007/

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Net.Types;

const
  CServerPort = 9007;
  CCertFile = '..\certs\test-server.crt';
  CKeyFile = '..\certs\test-server.key';

  CHtmlPage =
    '<!DOCTYPE html><html>' +
    '<head><title>HTTP/2 Push Demo</title>' +
    '<link rel="stylesheet" href="/style.css"></head>' +
    '<body><h1>Hello from HTTP/2 with Server Push!</h1>' +
    '<p>Check DevTools Network tab — style.css should show Initiator: Push.</p>' +
    '</body></html>';

  CCssBody =
    'body { font-family: sans-serif; background: #f0f4ff; color: #222; }' +
    'h1 { color: #1a3a8f; }';

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.ConfigureSSL(CCertFile, CKeyFile);
    App.EnableHTTP2;

    App.OnH2Push :=
      procedure(const AReq: TPoseidonNativeRequest;
        var APushResources: TArray<TPoseidonPushResource>)
      var
        LCss: TPoseidonPushResource;
      begin
        if AReq.Path = '/' then
        begin
          LCss.Path := '/style.css';
          LCss.ContentType := 'text/css';
          LCss.Body := TEncoding.UTF8.GetBytes(CCssBody);
          LCss.Extra := [];
          APushResources := [LCss];
        end;
      end;

    App.Get('/style.css',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'text/css';
        Ctx.Body := TEncoding.UTF8.GetBytes(CCssBody);
      end);

    App.Get('/',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'text/html; charset=utf-8';
        Ctx.Body := TEncoding.UTF8.GetBytes(CHtmlPage);
      end);

    Writeln('Poseidon Sample 07 — HTTP/2 Server Push');
    Writeln('Listening on https://0.0.0.0:', CServerPort);
    Writeln('  GET /          -> HTML page (pushes /style.css)');
    Writeln('  GET /style.css -> CSS');
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
