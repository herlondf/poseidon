program poseidon_h2spec_server;

// Headless HTTP/2 (h2 via ALPN over TLS) server used as the target for the
// h2spec conformance suite (run by tests/run-h2spec.ps1 inside a throwaway WSL
// distro). Unlike samples/04-http2 it never blocks on Readln — it listens and
// sleeps until the harness kills it.
//
// Expects server.crt / server.key in the working directory (the harness
// generates them with openssl) and libssl / libcrypto available at runtime.
//
// Usage: poseidon-h2spec-server [port]   (default 9444)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  Poseidon.Net.Types,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

const
  CDefaultPort = 9444;

var
  App:   TPoseidonServer;
  LPort: Integer;
begin
  LPort := CDefaultPort;
  if ParamCount >= 1 then
    LPort := StrToIntDef(ParamStr(1), CDefaultPort);

  App := TPoseidonServer.Create;
  try
    App.OnLog :=
      procedure(ALevel: TLogLevel; const AMessage: string)
      begin
        Writeln(ErrOutput, '[log:', Ord(ALevel), '] ', AMessage);
        Flush(ErrOutput);
      end;
    App.ConfigureSSL('server.crt', 'server.key');
    App.EnableHTTP2;

    App.Get('/',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'text/plain';
        Ctx.Body := TEncoding.UTF8.GetBytes('ok');
      end);

    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"h2":true}');
      end);

    Writeln('h2spec target listening on https://0.0.0.0:', LPort);
    Flush(Output);

    App.Listen(LPort, '0.0.0.0',
      procedure
      begin
        Writeln('READY');
        Flush(Output);
        while True do
          TThread.Sleep(60000);
      end);
  finally
    App.Free;
  end;
end.
