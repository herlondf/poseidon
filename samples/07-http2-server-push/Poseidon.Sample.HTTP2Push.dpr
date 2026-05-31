program Poseidon.Sample.HTTP2Push;

// HTTP/2 Server Push — demonstrates proactive asset delivery via OnH2Push.
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
// To test from the command line (requires curl ≥ 7.36 with nghttp2):
//   curl --http2 -k -v https://localhost:9007/

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer,
  Poseidon.Net.Types;

const
  PORT      = 9007;
  CERT_FILE = '..\certs\test-server.crt';
  KEY_FILE  = '..\certs\test-server.key';

// ---------------------------------------------------------------------------
// Request handler — serves the HTML page and the stylesheet
// ---------------------------------------------------------------------------

procedure HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
const
  HTML_PAGE =
    '<!DOCTYPE html><html>' +
    '<head><title>HTTP/2 Push Demo</title>' +
    '<link rel="stylesheet" href="/style.css"></head>' +
    '<body><h1>Hello from HTTP/2 with Server Push!</h1>' +
    '<p>Check DevTools Network tab — style.css should show Initiator: Push.</p>' +
    '</body></html>';
  CSS_BODY  = 'body { font-family: sans-serif; background: #f0f4ff; color: #222; }' +
              'h1 { color: #1a3a8f; }';
begin
  SetLength(AExtraHeaders, 0);

  if AReq.Path = '/style.css' then
  begin
    // Serve the stylesheet normally for HTTP/1.1 clients or cache misses
    AStatus      := 200;
    AContentType := 'text/css';
    ABody        := TEncoding.UTF8.GetBytes(CSS_BODY);
  end
  else
  begin
    AStatus      := 200;
    AContentType := 'text/html; charset=utf-8';
    ABody        := TEncoding.UTF8.GetBytes(HTML_PAGE);
  end;
end;

// ---------------------------------------------------------------------------
// Push callback — called by Poseidon before each HTTP/2 response
// ---------------------------------------------------------------------------

procedure HandlePush(
  const AReq:           TPoseidonNativeRequest;
  var   APushResources: TArray<TPoseidonPushResource>);
const
  CSS_BODY = 'body { font-family: sans-serif; background: #f0f4ff; color: #222; }' +
             'h1 { color: #1a3a8f; }';
var
  LCss: TPoseidonPushResource;
begin
  // Only push the stylesheet when the main page is requested.
  // Push a resource whose path the client's <link> tag will later request.
  if AReq.Path = '/' then
  begin
    LCss.Path        := '/style.css';
    LCss.ContentType := 'text/css';
    LCss.Body        := TEncoding.UTF8.GetBytes(CSS_BODY);
    LCss.Extra       := [];
    APushResources   := [LCss];
  end;
end;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    LServer.HTTP2Enabled := True;
    LServer.ConfigureSSL(CERT_FILE, KEY_FILE);
    LServer.OnH2Push := HandlePush;

    LServer.Listen('0.0.0.0', PORT, HandleRequest,
      procedure
      begin
        Writeln('HTTP/2 + Server Push listening on https://localhost:', PORT, '/');
        Writeln('Press Enter to stop...');
      end);

    Readln;
    LServer.Stop;
  finally
    LServer.Free;
  end;
end.
