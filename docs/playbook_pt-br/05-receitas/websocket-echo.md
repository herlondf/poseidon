# Servidor WebSocket echo

```pascal
program PoseidonWSEcho;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer,
  Poseidon.Net.WebSocket;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    // Rejeitar frames maiores que 1 MB
    LServer.MaxWSFrameSize := 1 * 1024 * 1024;

    LServer.RegisterWSHandler('/ws',
      procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
      begin
        case AFrame.Opcode of
          OPCODE_TEXT:
            AConn.Send('echo: ' + TEncoding.UTF8.GetString(AFrame.Payload));
          OPCODE_BINARY:
            AConn.SendBinary(AFrame.Payload);
          OPCODE_CLOSE:
            AConn.Close(1000);
        end;
      end);

    LServer.Listen('0.0.0.0', 9000,
      procedure(const AReq: TPoseidonNativeRequest;
                out AStatus: Integer; out AContentType: string;
                out ABody: TBytes;
                out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        AStatus      := 200;
        AContentType := 'text/plain';
        ABody        := TEncoding.UTF8.GetBytes('WebSocket echo em ws://0.0.0.0:9000/ws');
      end,
      procedure begin
        Writeln('Ouvindo em :9000  — pressione Enter para parar');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
```

Veja o projeto completo em [`samples/03-websocket/`](../../../samples/03-websocket/).
