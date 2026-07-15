program poseidon_autobahn_server;

// Headless WebSocket ECHO server used as the target for the Autobahn|Testsuite
// (fuzzingclient), run inside a throwaway WSL distro by tests/run-autobahn.ps1.
// Pure echo: TEXT -> same TEXT, BINARY -> same BINARY. Fragment reassembly,
// UTF-8 validation, PING/PONG and CLOSE are handled by the WebSocket manager;
// the handler only ever sees a complete, validated data message.
//
// Usage: poseidon-autobahn-server [port]   (default 9011)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  Poseidon.Net.Types,
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Net.WebSocket;

const
  CDefaultPort = 9011;
  CWSPath = '/';

var
  App:   TPoseidonServer;
  LPort: Integer;
begin
  LPort := CDefaultPort;
  if ParamCount >= 1 then
    LPort := StrToIntDef(ParamStr(1), CDefaultPort);

  App := TPoseidonServer.Create;
  try
    App.WebSocket(CWSPath,
      procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
      begin
        // Echo the reassembled message back with the same opcode, byte-exact.
        if AFrame.Opcode = OPCODE_TEXT then
          AConn.Send(TEncoding.UTF8.GetString(AFrame.Payload))
        else if AFrame.Opcode = OPCODE_BINARY then
          AConn.SendBinary(AFrame.Payload);
      end);

    Writeln('autobahn echo target listening on ws://0.0.0.0:', LPort, CWSPath);
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
