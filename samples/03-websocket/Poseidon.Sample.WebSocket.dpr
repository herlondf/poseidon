program Poseidon.Sample.WebSocket;

// Sample 03 — WebSocket Echo Server (Native API)
// Demonstrates WebSocket handler registration alongside a regular HTTP endpoint.
// The /ws path upgrades to WebSocket; /ping stays as plain HTTP.
//
// Run:
//   Poseidon.Sample.WebSocket.exe
//   # HTTP
//   curl http://localhost:9002/ping
//   # WebSocket (requires wscat or similar)
//   wscat -c ws://localhost:9002/ws
//   > hello
//   < echo: hello

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Net.WebSocket;

const
  CServerPort = 9002;
  CWSPath = '/ws';

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
        Ctx.Body := TEncoding.UTF8.GetBytes(
          '{"message":"pong","ws":"ws://localhost:' + IntToStr(CServerPort) + CWSPath + '"}');
      end);

    App.WebSocket(CWSPath,
      procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
      begin
        if AFrame.Opcode = OPCODE_TEXT then
          AConn.Send('echo: ' + TEncoding.UTF8.GetString(AFrame.Payload))
        else if AFrame.Opcode = OPCODE_BINARY then
          AConn.SendBinary(AFrame.Payload)
        else if AFrame.Opcode = OPCODE_CLOSE then
          AConn.Close(1000);
      end);

    Writeln('Poseidon Sample 03 — WebSocket Echo');
    Writeln('HTTP : http://0.0.0.0:', CServerPort, '/ping');
    Writeln('WS   : ws://0.0.0.0:', CServerPort, CWSPath);
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
