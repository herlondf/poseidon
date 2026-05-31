# Servidor HTTP/2

HTTP/2 requer SSL. Defina `HTTP2Enabled := True` antes de `ConfigureSSL` para que
o callback ALPN negocie o protocolo `"h2"` durante o handshake TLS.

```pascal
program PoseidonH2;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    // Ajusta SETTINGS HTTP/2 enviados aos clientes
    LServer.H2MaxConcurrentStreams := 200;
    LServer.H2InitialWindowSize    := 1048576;  // janela inicial de 1 MB

    LServer.HTTP2Enabled := True;
    LServer.ConfigureSSL('server.crt', 'server.key');

    LServer.Listen('0.0.0.0', 443,
      procedure(const AReq: TPoseidonNativeRequest;
                out AStatus: Integer; out AContentType: string;
                out ABody: TBytes;
                out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        AStatus      := 200;
        AContentType := 'text/plain';
        ABody        := TEncoding.UTF8.GetBytes('Olá via HTTP/2!');
      end,
      procedure begin
        Writeln('Ouvindo em https://0.0.0.0:443  (h2 + http/1.1)');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
```

## HTTP/2 cleartext (h2c)

Sem SSL. O cliente envia `Upgrade: h2c` em uma conexão TCP simples:

```pascal
LServer := TPoseidonNativeServer.Create;
// HTTP2Enabled := True NÃO é necessário para h2c — detectado pelo header Upgrade
LServer.Listen('0.0.0.0', 8080, @HandleRequest, nil);
```

Veja [h2c-upgrade.md](h2c-upgrade.md) para o fluxo completo do protocolo e
[`samples/04-http2/`](../../../samples/04-http2/) para um projeto executável.
