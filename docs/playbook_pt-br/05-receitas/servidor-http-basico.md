# Servidor HTTP básico

Servidor mínimo executável — responde `Olá, mundo!` a cada requisição.

```pascal
program AsyncIOBasico;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  AsyncIO.Net.HttpServer;

var
  LServer: TAsyncIONativeServer;
begin
  LServer := TAsyncIONativeServer.Create;
  try
    LServer.Listen('0.0.0.0', 9000,
      procedure(const AReq: TAsyncIONativeRequest;
                out AStatus: Integer; out AContentType: string;
                out ABody: TBytes;
                out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        AStatus      := 200;
        AContentType := 'text/plain; charset=utf-8';
        ABody        := TEncoding.UTF8.GetBytes('Olá, mundo!');
      end,
      procedure begin
        Writeln('Ouvindo em http://0.0.0.0:9000  — pressione Enter para parar');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
```

Veja o projeto completo em [`samples/01-basic-http-server/`](../../../samples/01-basic-http-server/).
