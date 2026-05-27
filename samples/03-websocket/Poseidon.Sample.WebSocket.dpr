program Poseidon.Sample.WebSocket;

// Sample 03 — WebSocket Echo Server
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
  System.Generics.Collections,
  Poseidon.Net.HttpServer,
  Poseidon.Net.WebSocket;

const
  SERVER_PORT = 9002;
  WS_PATH     = '/ws';

procedure HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string, string>>);
begin
  AExtraHeaders := [];
  AStatus       := 200;
  AContentType  := 'application/json';
  ABody         := TEncoding.UTF8.GetBytes(
    '{"message":"pong","ws":"ws://localhost:' + IntToStr(SERVER_PORT) + WS_PATH + '"}');
end;

procedure HandleWebSocket(
  AConn:        IPoseidonWSConn;
  const AFrame: TWebSocketFrame);
begin
  if AFrame.Opcode = OPCODE_TEXT then
    AConn.Send('echo: ' + TEncoding.UTF8.GetString(AFrame.Payload))
  else if AFrame.Opcode = OPCODE_BINARY then
    AConn.SendBinary(AFrame.Payload)
  else if AFrame.Opcode = OPCODE_CLOSE then
    AConn.Close(1000);
end;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    // Register WebSocket handler — upgrades connections on WS_PATH
    LServer.RegisterWSHandler(WS_PATH, HandleWebSocket);

    Writeln('Poseidon Sample 03 — WebSocket Echo');
    Writeln('HTTP  : http://0.0.0.0:', SERVER_PORT, '/ping');
    Writeln('WS    : ws://0.0.0.0:',  SERVER_PORT, WS_PATH);
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
