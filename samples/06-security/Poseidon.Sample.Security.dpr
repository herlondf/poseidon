program Poseidon.Sample.Security;

// Sample 06 — Security Hardening (Native API)
// Demonstrates the security properties:
//
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
//   curl http://localhost:9006/ping                      -> 200 OK
//   curl http://localhost:9006/../etc/passwd             -> 400 (path traversal)
//   curl -v http://localhost:9006/ping 2>&1 | grep -i server  -> no Server: header

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

const
  CServerPort = 9006;
  CMaxBodyBytes = 1 * 1024 * 1024;
  CMaxHeaderBytes = 16 * 1024;
  CMaxQueue = 200;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.MaxRequestSize := CMaxBodyBytes;
    App.MaxHeaderSize := CMaxHeaderBytes;
    App.MaxQueueDepth := CMaxQueue;
    App.SecureHeadersEnabled := True;
    App.ServerBanner := '';

    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes(
          Format('{"path":"%s","method":"%s","remote":"%s"}',
            [Ctx.Path, Ctx.Method, Ctx.RemoteAddr]));
      end);

    Writeln('Poseidon Sample 06 — Security Hardening');
    Writeln(Format('Listening on http://0.0.0.0:%d', [CServerPort]));
    Writeln;
    Writeln('Max request     : ', CMaxBodyBytes div 1024, ' KB');
    Writeln('Max headers     : ', CMaxHeaderBytes div 1024, ' KB');
    Writeln('Max queue depth : ', CMaxQueue);
    Writeln('Secure headers  : enabled');
    Writeln('Server banner   : suppressed');
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
