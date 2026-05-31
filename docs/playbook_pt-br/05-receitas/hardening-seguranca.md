# Hardening de segurança

Servidor com allowlist de verbos HTTP, limites de tamanho, backpressure,
security headers e banner suprimido.

```pascal
program PoseidonSeguro;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    LServer.AllowedMethods       := ['GET', 'POST', 'HEAD', 'OPTIONS'];
    LServer.MaxRequestSize       := 1 * 1024 * 1024;  // 1 MB — 413 se excedido
    LServer.MaxHeaderSize        := 16384;             // 16 KB — 400 se excedido
    LServer.MaxQueueDepth        := 200;               // 503 quando fila cheia
    LServer.SecureHeadersEnabled := True;              // X-Content-Type-Options etc.
    LServer.ServerBanner         := '';                // suprime header Server:

    LServer.Listen('0.0.0.0', 9006,
      procedure(const AReq: TPoseidonNativeRequest;
                out AStatus: Integer; out AContentType: string;
                out ABody: TBytes;
                out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        AStatus      := 200;
        AContentType := 'application/json';
        ABody        := TEncoding.UTF8.GetBytes('{"ok":true}');
      end,
      procedure begin
        Writeln('Servidor com hardening em :9006 — pressione Enter para parar');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
```

**Proteções embutidas (sempre ativas, sem código necessário):**
- Path traversal (`..`, `%2e%2e`, `\`, NUL) → `400`
- Request smuggling (CL + TE:chunked) → `400`
- Injeção CRLF em headers de resposta → removida silenciosamente

Veja [security.md](../04-operacao-e-runtime/security.md) para detalhes das propriedades e
[`samples/06-security/`](../../../samples/06-security/) para o projeto completo.
