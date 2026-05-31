program Poseidon.Sample.Security;

// Sample 06 — Security hardening
// Demonstrates the security properties added in the S-* and A-* roadmap items:
//
//   S-1  AllowedMethods       — reject verbs not in the allowlist (405)
//   S-2  IsPathSafe           — reject path-traversal attempts (400, auto)
//   S-4  Request smuggling    — reject CL + TE:chunked (400, auto)
//   R-4  MaxRequestSize       — reject oversized bodies (413)
//   R-4  MaxHeaderSize        — reject oversized header sections (400)
//   R-5  MaxQueueDepth        — reject when too many requests are in-flight (503)
//   A-1  SecureHeadersEnabled — inject X-Content-Type-Options, X-Frame-Options, Referrer-Policy
//   A-2  ServerBanner         — custom or suppressed Server: header
//
// Run:
//   Poseidon.Sample.Security.exe
//   curl http://localhost:9006/ping                      → 200 OK
//   curl -X DELETE http://localhost:9006/ping            → 405 (not in allowlist)
//   curl http://localhost:9006/../etc/passwd             → 400 (path traversal)
//   curl -v http://localhost:9006/ping 2>&1 | grep -i server  → no Server: header

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Net.HttpServer;

const
  SERVER_PORT     = 9006;
  MAX_BODY_BYTES  = 1 * 1024 * 1024;  // 1 MB
  MAX_HEADER_KB   = 16 * 1024;         // 16 KB
  MAX_QUEUE       = 200;

procedure HandleRequest(
  const AReq:          TPoseidonNativeRequest;
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
  LJson := Format(
    '{"path":"%s","method":"%s","remote":"%s"}',
    [AReq.Path, AReq.Method, AReq.RemoteAddr]);
  ABody := TEncoding.UTF8.GetBytes(LJson);
end;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    // S-1: reject verbs not in this list
    LServer.AllowedMethods := ['GET', 'POST', 'HEAD', 'OPTIONS'];

    // R-4: size limits
    LServer.MaxRequestSize := MAX_BODY_BYTES;
    LServer.MaxHeaderSize  := MAX_HEADER_KB;

    // R-5: backpressure — 503 when more than MAX_QUEUE requests are in-flight
    LServer.MaxQueueDepth := MAX_QUEUE;

    // A-1: inject security headers
    LServer.SecureHeadersEnabled := True;

    // A-2: suppress the Server: header
    LServer.ServerBanner := '';

    Writeln('Poseidon Sample 06 — Security hardening');
    Writeln(Format('Listening on http://0.0.0.0:%d', [SERVER_PORT]));
    Writeln;
    Writeln('Allowed methods : GET, POST, HEAD, OPTIONS');
    Writeln('Max request     : ', MAX_BODY_BYTES div 1024, ' KB');
    Writeln('Max headers     : ', MAX_HEADER_KB  div 1024, ' KB');
    Writeln('Max queue depth : ', MAX_QUEUE);
    Writeln('Secure headers  : enabled');
    Writeln('Server banner   : suppressed');
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
