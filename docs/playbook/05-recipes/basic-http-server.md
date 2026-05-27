# Basic HTTP server

Minimal runnable server — responds `Hello, world!` to every request.

```pascal
program PoseidonBasic;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    LServer.Listen('0.0.0.0', 9000,
      procedure(const AReq: TPoseidonNativeRequest;
                out AStatus: Integer; out AContentType: string;
                out ABody: TBytes;
                out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        AStatus      := 200;
        AContentType := 'text/plain; charset=utf-8';
        ABody        := TEncoding.UTF8.GetBytes('Hello, world!');
      end,
      procedure begin
        Writeln('Listening on http://0.0.0.0:9000  — press Enter to stop');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
```

See full project at [`samples/01-basic-http-server/`](../../../samples/01-basic-http-server/).
