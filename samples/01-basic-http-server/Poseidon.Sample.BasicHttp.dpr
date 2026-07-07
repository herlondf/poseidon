program Poseidon.Sample.BasicHttp;

// Sample 01 — Basic HTTP Server (Native API)
// Demonstrates the minimal setup with TPoseidonServer.
// Covers: route registration, params, middleware, graceful Stop.
//
// Run:
//   Poseidon.Sample.BasicHttp.exe
//   curl http://localhost:9001/ping
//   curl http://localhost:9001/hello/world

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

const
  CServerPort = 9001;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"message":"pong"}');
      end);

    App.Get('/hello/:name',
      procedure(var Ctx: TNativeRequestContext)
      var
        LName: string;
      begin
        LName := Ctx.Param('name');
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"hello":"' + LName + '"}');
      end);

    Writeln('Poseidon Sample 01 — Basic HTTP Server (Native API)');
    Writeln('Listening on http://0.0.0.0:', CServerPort);
    Writeln('  GET /ping        -> {"message":"pong"}');
    Writeln('  GET /hello/:name -> {"hello":"<name>"}');
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
