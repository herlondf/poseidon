# 08 — API Nativa

A API nativa do Poseidon é baseada em instância de `TPoseidonServer`. Ela expõe
um estilo fluente onde a maioria dos métodos de configuração retorna `Self`,
permitindo encadeamento direto.

---

## TPoseidonServer

Ponto de entrada principal. Criado, configurado e iniciado pelo código da
aplicação:

```pascal
var
  LApp: TPoseidonServer;
begin
  LApp := TPoseidonServer.Create;
  try
    LApp
      .WorkerCount(8)
      .MaxConnections(10000)
      .IdleTimeoutMs(30000);

    LApp.Get('/ping', procedure(var ACtx: TNativeRequestContext)
    begin
      ACtx.Body := 'pong';
    end);

    LApp.Listen(9000);
  finally
    LApp.Free;
  end;
end;
```

---

## TNativeRequestContext

Record alocado na stack (zero-copy) que representa uma requisição HTTP em
andamento. Passado por referência (`var`) para handlers e middlewares.

Campos de leitura:

| Campo | Tipo | Descrição |
|-------|------|-----------|
| `Method` | `string` | Verbo HTTP (`GET`, `POST`, …) |
| `Path` | `string` | Caminho sem query string |
| `QueryString` | `string` | Query string bruta |
| `Headers` | `TNameValueList` | Headers da requisição |
| `Body` | `TBytes` | Corpo da requisição |
| `RemoteAddr` | `string` | IP do cliente |

Campos de resposta (escrita):

| Campo | Tipo | Descrição |
|-------|------|-----------|
| `Status` | `Integer` | Código HTTP de resposta (padrão: 200) |
| `ContentType` | `string` | Valor do header `Content-Type` |
| `Body` | `string` ou `TBytes` | Corpo da resposta |
| `ExtraHeaders` | `TNameValueList` | Headers adicionais da resposta |

Acesso a parâmetros de rota:

```pascal
// Rota registrada como '/usuarios/:id'
var
  LId: string;
begin
  LId := ACtx.Param('id');
end;
```

---

## Registro de Rotas

Métodos de registro retornam `Self` para encadeamento fluente:

```pascal
LApp
  .Get('/recurso', HHandlerGet)
  .Post('/recurso', HHandlerPost)
  .Put('/recurso/:id', HHandlerPut)
  .Delete('/recurso/:id', HHandlerDelete)
  .Patch('/recurso/:id', HHandlerPatch)
  .Head('/recurso', HHandlerHead)
  .All('/qualquer', HHandlerAll);   // captura todos os verbos
```

O handler tem assinatura:

```pascal
procedure(var ACtx: TNativeRequestContext)
```

---

## Middleware

### Assinatura

```pascal
TNativeMiddlewareFunc =
  reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

`ANext` avança para o próximo elemento da cadeia. Se não for chamado, a cadeia
é interrompida (útil para autenticação e rate limiting).

### Middleware global

```pascal
LApp.Use(LoggerMiddleware);
LApp.Use(CORSMiddleware);
```

Os middlewares globais são executados na ordem de registro, antes do handler da
rota.

---

## Grupos de Rotas

### Prefixo simples

```pascal
var
  LApi: TPoseidonRouteGroup;
begin
  LApi := LApp.Group('/api/v1');
  LApi.Get('/usuarios', HListarUsuarios);
  LApi.Post('/usuarios', HCriarUsuario);
end;
```

### Bloco inline

```pascal
LApp.GroupBlock('/api/v1', procedure(AGroup: TPoseidonRouteGroup)
begin
  AGroup.Get('/pedidos', HListarPedidos);
  AGroup.Get('/pedidos/:id', HObterPedido);
  AGroup.Use(JWTMiddleware('segredo'));   // middleware apenas para este grupo
end);
```

---

## WebSocket

```pascal
LApp.WebSocket('/ws/chat', procedure(AConn: TPoseidonWSConnection;
  AEvent: TWsEvent; const AData: TBytes)
begin
  case AEvent of
    wsOpen:    AConn.Send('bem-vindo');
    wsMessage: AConn.Broadcast(AData);
    wsClose:   { limpar estado };
  end;
end);
```

---

## Ciclo de Vida

```pascal
// Iniciar (bloqueante enquanto o servidor estiver rodando)
LApp.Listen(9000);

// Iniciar em thread separada (não bloqueante)
LApp.ListenAsync(9000);

// Parar graciosamente (aguarda conexões ativas drenarem)
LApp.Stop;
```

---

## Graceful Reload e PID File

```pascal
LApp.PIDFile := '/var/run/poseidon.pid';
InstallSignalHandler(LApp);   // Linux: SIGTERM / SIGHUP
LApp.Listen(9000);
```

No Windows, `PIDFile` é gravado normalmente, mas `InstallSignalHandler` não tem
efeito — o encerramento deve ser acionado por código ou serviço do SO.

---

## Propriedades de Configuração

| Propriedade | Tipo | Padrão | Descrição |
|-------------|------|--------|-----------|
| `WorkerCount` | `Integer` | `CPUCount` | Threads de I/O worker |
| `MaxConnections` | `Integer` | `10000` | Conexões simultâneas máximas |
| `IdleTimeoutMs` | `Integer` | `30000` | Timeout de conexão ociosa (ms) |
| `DrainTimeoutMs` | `Integer` | `5000` | Tempo máximo de drenagem no Stop (ms) |
| `PerCoreAccept` | `Boolean` | `False` | Habilita SO_REUSEPORT (Linux) |
| `PIDFile` | `string` | `''` | Caminho do arquivo de PID |
| `ReadBufferSize` | `Integer` | `32768` | Tamanho do buffer de leitura por conexão |

---

## SSL / TLS

```pascal
// Certificado único
LApp.ConfigureSSL('cert.pem', 'key.pem');

// SNI — múltiplos certificados por hostname
LApp.AddSSLCert('api.exemplo.com', 'api-cert.pem', 'api-key.pem');
LApp.AddSSLCert('admin.exemplo.com', 'admin-cert.pem', 'admin-key.pem');

// mTLS — exige certificado do cliente
LApp.ConfigureMTLS('ca-cert.pem');

// HTTP/2 (requer SSL configurado antes)
LApp.EnableHTTP2;

LApp.Listen(443);
```

---

## Veja também

- [09 — Middlewares](../09-middlewares/README.md)
- [03 — Protocolos](../03-protocolos/README.md)
- [05 — Receitas](../05-receitas/README.md)
