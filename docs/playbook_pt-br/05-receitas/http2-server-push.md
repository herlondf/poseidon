# Receita: HTTP/2 Server Push

O server push HTTP/2 (RFC 7540 §8.2) permite que o servidor envie recursos ao cliente
**antes** que sejam requisitados, eliminando um round-trip para assets críticos.

## Quando usar

- Página HTML que sempre precisa de um CSS ou bundle JavaScript.
- Resposta de API que sempre inclui um recurso relacionado.
- Qualquer caso em que você já sabe antecipadamente o que o cliente vai requisitar.

**Não** envie via push recursos que o cliente provavelmente já tem em cache; clientes
modernos enviam `Cache-Digest` ou simplesmente desativam o push com `SETTINGS_ENABLE_PUSH = 0`.

## Exemplo mínimo

```pascal
uses
  Poseidon.Net.HttpServer,
  Poseidon.Net.Types;

procedure HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
begin
  AStatus      := 200;
  AContentType := 'text/html';
  ABody        := TEncoding.UTF8.GetBytes(
    '<html><head><link rel="stylesheet" href="/style.css"></head>' +
    '<body><h1>Olá!</h1></body></html>');
end;

procedure HandlePush(
  const AReq:           TPoseidonNativeRequest;
  var   APushResources: TArray<TPoseidonPushResource>);
var
  LCss: TPoseidonPushResource;
begin
  if AReq.Path = '/' then
  begin
    LCss.Path        := '/style.css';
    LCss.ContentType := 'text/css';
    LCss.Body        := TEncoding.UTF8.GetBytes('body { margin: 0; }');
    LCss.Extra       := [];
    APushResources   := [LCss];
  end;
end;

var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  LServer.HTTP2Enabled := True;
  LServer.ConfigureSSL('server.crt', 'server.key');
  LServer.OnH2Push := HandlePush;   // <- conecta o push
  LServer.Listen('0.0.0.0', 443, HandleRequest, nil);
end;
```

## Como funciona

Para cada requisição, o Poseidon chama `OnH2Push` **antes** de enviar a resposta.
O callback pode preencher `APushResources` com quantos recursos desejar.
Para cada recurso:

1. Um frame `PUSH_PROMISE` é enviado no stream do cliente (anuncia o push).
2. Frames `HEADERS + DATA` são enviados em um novo stream iniciado pelo servidor (ID par).
3. A resposta normal para a requisição original é enviada em seguida.

A sequência no protocolo fica assim:

```
cliente → HEADERS  (stream 1, GET /)
servidor ← PUSH_PROMISE (stream 1, stream prometido 2, :path /style.css)
servidor ← HEADERS  (stream 2, 200 text/css)
servidor ← DATA     (stream 2, corpo CSS, END_STREAM)
servidor ← HEADERS  (stream 1, 200 text/html)
servidor ← DATA     (stream 1, corpo HTML, END_STREAM)
```

## Referência de TPoseidonPushResource

| Campo | Tipo | Descrição |
|-------|------|-----------|
| `Path` | `string` | Caminho da URL do recurso enviado (ex: `'/app.js'`) |
| `ContentType` | `string` | Valor de `Content-Type` para a resposta push |
| `Body` | `TBytes` | Corpo completo da resposta push |
| `Extra` | `TArray<TPair<string,string>>` | Headers adicionais opcionais da resposta |

## Observações importantes

- O push só funciona sobre **h2** (TLS + ALPN). Conexões com upgrade h2c também suportam push.
- Um cliente pode enviar `SETTINGS_ENABLE_PUSH = 0` para desabilitar o push a qualquer momento.
  O Poseidon respeita isso e para de chamar `_SendPushPromiseAndResponse` automaticamente.
- Só use push para recursos pequenos e sempre necessários — pushes grandes ou condicionais
  desperdiçam banda quando o cliente já tem o recurso em cache.
- Cada recurso enviado via push consome um ID de stream iniciado pelo servidor (números pares: 2, 4, 6 …).
  Esses são distintos dos streams iniciados pelo cliente (números ímpares).

## Veja também

- [HTTP/2](../03-protocolos/http2.md) — configuração geral de HTTP/2
- [Controle de Fluxo HTTP/2](../03-protocolos/http2-flow-control.md) — gerenciamento de janelas
- [Sample: 07-http2-server-push](../../../samples/07-http2-server-push/)
