# Poseidon — Referência da API

Referência completa da superfície de API **pública** exposta através de `uses Poseidon`
(a unit de fachada) mais as units de middleware sob `middlewares/`. As assinaturas são
copiadas literalmente das seções `interface` do código-fonte.

> Esta página é a referência navegável, mantida à mão. Para uma referência HTML
> navegável gerada diretamente dos doc-comments do código-fonte, execute
> [`docs/api/gen-api.ps1`](./api/gen-api.ps1) (PasDoc).
>
> Novo no Poseidon? Comece pelo [playbook da API nativa](./playbook/08-native-api/README.md).
> Migrando da v1? Veja o [guia de migração v1 → v2](./MIGRATION_v1_to_v2.md).

---

## Conteúdo

- [A fachada — `uses Poseidon`](#a-fachada--uses-poseidon)
- [`TPoseidonServer`](#tposeidonserver)
- [`TNativeRequestContext`](#tnativerequestcontext)
- [Tipos de callback de handler e middleware](#tipos-de-callback-de-handler-e-middleware)
- [`TNativeGroup` / grupos de rotas](#tnativegroup--grupos-de-rotas)
- [WebSocket — `IPoseidonWSConn`](#websocket--iposeidonwsconn)
- [Validação (atributos RTTI)](#validação-atributos-rtti)
- [Códigos de status e tipos MIME](#códigos-de-status-e-tipos-mime)
- [Problem Details (RFC 7807)](#problem-details-rfc-7807)
- [Exceções](#exceções)
- [Logging](#logging)
- [Middlewares](#middlewares)

---

## A fachada — `uses Poseidon`

Um único `uses Poseidon;` reexporta toda a API primária. Você raramente precisa
referenciar as units subjacentes diretamente.

| Nome reexportado | Unit de origem |
|---|---|
| `TPoseidonServer` | `Poseidon.Native.Server` |
| `TNativeRequestContext`, `PNativeRequestContext` | `Poseidon.Native.Types` |
| `TNativeHandler`, `TNativeHandlerFunc` | `Poseidon.Native.Types` |
| `TNativeMiddleware`, `TNativeMiddlewareFunc` | `Poseidon.Native.Types` |
| `TNativeGroup`, `TNativeGroupBlock` | `Poseidon.Native.Group` |
| `IPoseidonWSConn`, `TWSMessageCallback` | `Poseidon.Net.WebSocket` |
| `EPoseidonException`, `EPoseidonCallbackInterrupted`, `EPoseidonValidation` | `Poseidon.Exception` |
| `TProblemDetail` | `Poseidon.Problem` |
| `THTTPStatus`, `TMimeType` | `Poseidon.Status` |
| `TPoseidonValidator`, `TPoseidonValidationError`, atributos de validação | `Poseidon.Validation` |
| `TLogLevel`, `TOnPoseidonLog`, `TOnPoseidonRequestLog` | `Poseidon.Net.Types` |

As fábricas de middleware ficam em `middlewares/` e **não** são reexportadas pela
fachada — adicione a unit `Poseidon.Middleware.*` específica à sua cláusula `uses`.

---

## `TPoseidonServer`

*(unit `Poseidon.Native.Server`)* — servidor HTTP nativo baseado em instância com uma
API de roteamento fluente e zero-copy; é dono do router, dos grupos de rotas e do
transporte subjacente. Crie uma instância por processo (múltiplas instâncias em portas
distintas são suportadas).

### Construção / ciclo de vida

| Assinatura | Descrição |
|---|---|
| `constructor Create;` | Cria o servidor, o router, a lista de grupos e o evento de shutdown. |
| `destructor Destroy; override;` | Para o servidor se estiver rodando, então libera todos os recursos que possui. |
| `procedure Listen(APort: Integer; const AHost: string = '0.0.0.0'; AOnListen: TProc = nil);` | Começa a escutar, grava o arquivo PID, invoca `AOnListen`, então bloqueia até o shutdown. Lança exceção se já estiver escutando. |
| `procedure Stop;` | Para o transporte, remove o arquivo PID, sinaliza o shutdown. Não faz nada se não estiver rodando. |

### Registro de rotas

Cada verbo tem duas sobrecargas — um `TNativeHandler` (ponteiro de método) e um
`TNativeHandlerFunc` (função anônima). Todas retornam `TPoseidonServer` para
encadeamento fluente.

| Assinatura | Descrição |
|---|---|
| `function Get(const APath: string; AHandler: TNativeHandler): TPoseidonServer; overload;` | Registra uma rota `GET`. |
| `function Get(const APath: string; AHandler: TNativeHandlerFunc): TPoseidonServer; overload;` | Rota `GET` (função anônima). |
| `function Post(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registra uma rota `POST`. |
| `function Put(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registra uma rota `PUT`. |
| `function Delete(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registra uma rota `DELETE`. |
| `function Patch(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registra uma rota `PATCH`. |
| `function Head(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registra uma rota `HEAD`. |
| `function All(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TPoseidonServer; overload;` | Registra o handler para todos os métodos (`GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS`). |

Parâmetros de rota usam `:name` (ex.: `/users/:id`); leia-os com `Ctx.Param('id')`.

### Middleware global

| Assinatura | Descrição |
|---|---|
| `function Use(AMiddleware: TNativeMiddleware): TPoseidonServer; overload;` | Anexa um middleware global (ponteiro de método), executado antes de cada rota. |
| `function Use(AMiddleware: TNativeMiddlewareFunc): TPoseidonServer; overload;` | Anexa um middleware global (função anônima). |

### Grupos de rotas

| Assinatura | Descrição |
|---|---|
| `function Group(const APrefix: string): TNativeGroup;` | Cria e retorna um grupo de rotas sob `APrefix` (de propriedade do servidor). |
| `procedure GroupBlock(const APrefix: string; ABlock: TNativeGroupBlock);` | Cria um grupo sob `APrefix` e o passa para o callback do bloco. |

### WebSocket

| Assinatura | Descrição |
|---|---|
| `procedure WebSocket(const APath: string; AHandler: TWSMessageCallback);` | Registra um handler de mensagens WebSocket em `APath`. |

### Configuração TLS / HTTP/2

| Assinatura | Descrição |
|---|---|
| `procedure ConfigureSSL(const ACertFile, AKeyFile: string);` | Habilita TLS com os arquivos de certificado e chave privada informados. |
| `procedure AddSSLCert(const AHostName, ACertFile, AKeyFile: string);` | Adiciona um certificado SNI vinculado a `AHostName`. |
| `procedure ConfigureMTLS(const ACAFile: string);` | Habilita TLS mútuo, verificando os certs do cliente contra o arquivo da CA. |
| `procedure EnableHTTP2(AEnabled: Boolean = True);` | Habilita (ou desabilita) o HTTP/2. |

### Propriedades

| Propriedade | Descrição |
|---|---|
| `Server: TPoseidonNativeServer` (somente leitura) | Transporte nativo subjacente. |
| `Running: Boolean` (somente leitura) | Verdadeiro enquanto estiver escutando. |
| `MaxConnections: Integer` | Máximo total de conexões concorrentes. |
| `MaxConnectionsPerIP: Integer` | Máximo de conexões concorrentes por IP de cliente. |
| `WorkerCount: Integer` | Tamanho máximo do pool de threads de trabalho. |
| `MinWorkerCount: Integer` | Número mínimo (baseline) de threads de trabalho. |
| `IdleTimeoutMs: Integer` | Timeout de conexão ociosa (ms). |
| `MaxRequestSize: Integer` | Tamanho máximo aceito do corpo da requisição (bytes). |
| `MaxHeaderSize: Integer` | Tamanho máximo aceito do bloco de headers (bytes). |
| `DrainTimeoutMs: Integer` | Timeout de drenagem graciosa no shutdown (ms). |
| `MaxQueueDepth: Integer` | Profundidade máxima da fila de despacho de workers. |
| `SecureHeadersEnabled: Boolean` | Alterna os headers de resposta de segurança automáticos. |
| `ServerBanner: string` | Valor enviado no header de resposta `Server`. |
| `TCPFastOpen: Boolean` | Habilita o TCP Fast Open no listener. |
| `PerCoreAccept: Boolean` | Habilita sockets de accept por núcleo (escala no estilo SO_REUSEPORT). |
| `SyncDispatch: Boolean` | Despacha na thread de IO em vez do pool de workers. |
| `OnH2Push: TOnH2Push` | Hook de server-push do HTTP/2. |
| `PIDFile: string` | Caminho do arquivo PID gravado no `Listen`, removido no `Stop`. |
| `OnLog: TOnPoseidonLog` | Callback de log geral. |
| `OnRequestLog: TOnPoseidonRequestLog` | Callback de log de acesso por requisição. |

> A porta é um argumento obrigatório de `Listen`; não há constante de porta padrão.
> O host padrão é o valor default do parâmetro de `Listen`, `'0.0.0.0'`.

---

## `TNativeRequestContext`

*(unit `Poseidon.Native.Types`)* — `record` alocado na pilha, passado por `var` para
todo handler e middleware. Os campos do lado da requisição referenciam a requisição
parseada sem copiar; os campos do lado da resposta são o que você escreve. `PNativeRequestContext`
é `^TNativeRequestContext`.

### Campos

```pascal
// --- request (read) ---
Method: string;                              // "GET", "POST", ...
Path: string;                                // request path, no query string
QueryString: string;                         // raw query (after "?"), undecoded
RemoteAddr: string;                          // client remote address
RawBody: TBytes;                             // raw inbound body bytes
KeepAlive: Boolean;                          // connection is keep-alive
Headers: TArray<TPair<string,string>>;       // request headers
Params: TArray<TPair<string,string>>;        // route params (e.g. :id)

// --- response (write) ---
Status: Integer;                             // response status code
ContentType: string;                         // response Content-Type
Body: TBytes;                                // response body bytes
ExtraHeaders: TArray<TPair<string,string>>;  // additional response headers
Handled: Boolean;                            // set True to short-circuit the pipeline
```

### Métodos

| Assinatura | Descrição |
|---|---|
| `function Param(const AName: string): string;` | Parâmetro de rota por nome (case-insensitive); `''` se ausente. |
| `function Header(const AName: string): string;` | Header da requisição por nome (case-insensitive); `''` se ausente. |
| `function Query(const AName: string): string;` | Valor da query-string decodificado por URL, por nome (case-insensitive); `''` se ausente. |

Não há helper de JSON embutido no record — escreva `Body`/`ContentType`
diretamente (ex.: `Ctx.ContentType := TMimeType.ApplicationJSON`), ou use os
middlewares `Validation` / `ProblemDetails`. `RawBody` é o corpo de entrada;
`Body` é o corpo de saída.

---

## Tipos de callback de handler e middleware

*(unit `Poseidon.Native.Types`)*

```pascal
TNativeHandler       = procedure(var ACtx: TNativeRequestContext) of object;
TNativeHandlerFunc   = reference to procedure(var ACtx: TNativeRequestContext);
TNativeMiddleware    = procedure(var ACtx: TNativeRequestContext; ANext: TProc) of object;
TNativeMiddlewareFunc = reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);
```

Um middleware recebe `ANext: TProc`; chame-o para executar o restante da cadeia, ou
omita a chamada para curto-circuitar (ex.: um middleware de auth retornando 401).

---

## `TNativeGroup` / grupos de rotas

*(unit `Poseidon.Native.Group`)* — grupo de rotas fluente que registra rotas sob um
prefixo comum, com middleware por grupo aplicado a toda rota adicionada através dele.

| Assinatura | Descrição |
|---|---|
| `constructor Create(ARouter: TNativeRouter; const APrefix: string);` | Grupo vinculado a um router; prefixo normalizado para uma única barra inicial. |
| `function Use(AMiddleware: TNativeMiddleware / TNativeMiddlewareFunc): TNativeGroup; overload;` | Adiciona middleware aplicado às rotas registradas em seguida neste grupo. |
| `function Get/Post/Put/Delete/Patch/Head(const APath: string; AHandler: TNativeHandler / TNativeHandlerFunc): TNativeGroup; overload;` | Registra uma rota sob o prefixo do grupo (duas sobrecargas cada). |
| `property Prefix: string` (somente leitura) | O prefixo normalizado do grupo. |

`TNativeGroup` **não** possui sobrecarga `All` (ao contrário de `TPoseidonServer`).

```pascal
TNativeGroupBlock = reference to procedure(G: TNativeGroup);
```

Usado por `TPoseidonServer.GroupBlock` para configurar um grupo inline.

---

## WebSocket — `IPoseidonWSConn`

*(unit `Poseidon.Net.WebSocket`)* — handle por conexão que um handler de WebSocket
usa para enviar frames e controlar uma conexão de cliente ativa.
GUID `{B2C3D4E5-F607-8901-BCDE-F01234567891}`.

| Assinatura | Descrição |
|---|---|
| `procedure Send(const AText: string);` | Envia um frame de texto (UTF-8); permessage-deflate quando negociado. Não faz nada se fechado. |
| `procedure SendBinary(const AData: TBytes);` | Envia um frame binário; permessage-deflate quando negociado. Não faz nada se fechado. |
| `procedure Close(ACode: Word = 1000);` | Envia um frame de close (padrão 1000) e derruba a conexão; idempotente. |
| `property RemoteAddr: string` (somente leitura) | Endereço remoto do cliente. |
| `property Closed: Boolean` (somente leitura) | Se a conexão foi fechada. |
| `property DeflateEnabled: Boolean` (somente leitura) | Se o permessage-deflate foi negociado. |

```pascal
TWSMessageCallback = reference to procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame);
```

Invocado a cada mensagem de entrada com o handle da conexão e o frame decodificado
(opcode, flags fin/RSV, payload).

---

## Validação (atributos RTTI)

*(unit `Poseidon.Validation`)* — decore os **campos** de um DTO (a validação é
dirigida por `GetFields`, não por propriedades) com atributos e então valide.

```pascal
type
  TCreateUserDTO = class
  public
    [Required][MinLength(3)][MaxLength(30)] Name: string;
    [Required][Email]                       Email: string;
    [Range(18, 120)]                        Age: Integer;
    [Pattern('^\+?\d{8,15}$', 'phone must be 8-15 digits')] Phone: string;
  end;
```

| Atributo | Construtor | Exige |
|---|---|---|
| `Required` | *(nenhum)* | String não-vazia / objeto não-nil / array não-vazio (0 numérico é válido). |
| `MinLength` | `Create(AMin: Integer)` | Comprimento de string ≥ `AMin`. |
| `MaxLength` | `Create(AMax: Integer)` | Comprimento de string ≤ `AMax`. |
| `Email` | *(nenhum)* | Casa com uma regex de e-mail. |
| `Range` | `Create(AMin, AMax: Double)` | Valor numérico em `[AMin, AMax]`; não-numérico falha de forma limpa. |
| `Pattern` | `Create(const APattern: string; const AMessage: string = '')` | String casa com a regex `APattern`; mensagem customizada opcional. |

```pascal
TPoseidonValidationError = record
  Field: string;
  Message: string;
end;

TPoseidonValidator = class
  class function Validate(AObject: TObject; out AErrors: TArray<TPoseidonValidationError>): Boolean;
  class procedure ValidateOrRaise(AObject: TObject);   // raises EPoseidonValidation (422)
end;
```

`Validate` retorna `True` quando válido; em caso de falha, `AErrors` coleta **todas**
as violações. `ValidateOrRaise` junta todas as mensagens com `'; '` e lança
`EPoseidonValidation` (status 422). Combine com o middleware `Validation` para
transformar isso em uma resposta JSON 422 estruturada.

---

## Códigos de status e tipos MIME

*(unit `Poseidon.Status`)* — records sem dependências (sem `Web.HTTPApp`).

```pascal
THTTPStatus = record
  constructor Create(ACode: Integer);
  function ToInteger: Integer;
  class operator Implicit(AStatus: THTTPStatus): Integer;  // usable anywhere an Integer status is expected
end;
```

Constantes representativas (`class var: THTTPStatus`): `Ok` (200), `Created` (201),
`NoContent` (204), `MovedPermanently` (301), `Found` (302), `NotModified` (304),
`BadRequest` (400), `Unauthorized` (401), `Forbidden` (403), `NotFound` (404),
`MethodNotAllowed` (405), `Conflict` (409), `PayloadTooLarge` (413),
`UnprocessableEntity` (422), `TooManyRequests` (429), `InternalServerError` (500),
`BadGateway` (502), `ServiceUnavailable` (503).

```pascal
TMimeType = record
  class var ApplicationJSON: string;               // 'application/json'
  class var ApplicationXWWWFormURLEncoded: string; // 'application/x-www-form-urlencoded'
  class var MultiPartFormData: string;             // 'multipart/form-data'
  class var TextPlain: string;                      // 'text/plain'
  class var TextHTML: string;                       // 'text/html'
  class var ApplicationOctetStream: string;         // 'application/octet-stream'
  class var ApplicationProblemJSON: string;         // 'application/problem+json'
end;
```

Uso: `Ctx.Status := THTTPStatus.Ok;  Ctx.ContentType := TMimeType.ApplicationJSON;`

---

## Problem Details (RFC 7807)

*(unit `Poseidon.Problem`)*

```pascal
TProblemDetail = record
  TypeURI: string;    // -> "type"     (defaults to 'about:blank')
  Title: string;      // -> "title"    (CanonicalTitle(Status))
  Status: Integer;    // -> "status"
  Detail: string;     // -> "detail"   (emitted only when non-empty)
  Instance: string;   // -> "instance" (emitted only when non-empty)
  function ToJSON: TJSONObject;                                             // application/problem+json
  class function CanonicalTitle(AStatus: Integer): string; static;         // status -> reason phrase
  class function FromException(E: EPoseidonException; const AInstance: string): TProblemDetail; static;
end;
```

`FromException` constrói um problem a partir de um `EPoseidonException`
(`Status := E.Status.ToInteger`, `Detail := E.Message`). O middleware `ProblemDetails`
faz esse encadeamento automaticamente para erros não tratados.

---

## Exceções

*(unit `Poseidon.Exception`)*

```pascal
EPoseidonException = class(Exception)     // carries an HTTP status
  constructor Create(const AMessage: string; const AStatus: THTTPStatus); reintroduce;
  property Status: THTTPStatus read FStatus;

EPoseidonValidation = class(EPoseidonException)   // always status 422
  constructor Create(const AMessage: string);

EPoseidonCallbackInterrupted = class(Exception)   // deliberately interrupted callback
  constructor Create;
```

- `EPoseidonException` — exceção base da aplicação, pareia uma mensagem com um `THTTPStatus`.
- `EPoseidonValidation` — descende de `EPoseidonException`; status fixo 422.
- `EPoseidonCallbackInterrupted` — descende de `Exception` (não de
  `EPoseidonException`); sinaliza um callback interrompido deliberadamente.

Lançar `EPoseidonException('not found', THTTPStatus.NotFound)` em um handler é
traduzido para a resposta HTTP correspondente (problem JSON quando o middleware
`ProblemDetails` está instalado).

---

## Logging

*(unit `Poseidon.Net.Types`)*

```pascal
TLogLevel = (llDebug, llInfo, llWarning, llError);

TOnPoseidonLog = reference to procedure(ALevel: TLogLevel; const AMessage: string);

TPoseidonRequestLogEvent = record
  Method: string; Path: string; Status: Integer; DurationMs: Int64;
  RemoteAddr: string; RxBytes: Int64; TxBytes: Int64;
end;

TOnPoseidonRequestLog = reference to procedure(const AEvent: TPoseidonRequestLogEvent);
```

Atribua `App.OnLog` para diagnósticos do framework e `App.OnRequestLog` para um
log de acesso estruturado por requisição. Para um log de acesso pronto, use o
middleware `Logger` em vez disso.

---

## Middlewares

As fábricas ficam em `middlewares/Poseidon.Middleware.<Name>.pas`. Adicione a unit à
sua cláusula `uses` e instale com `App.Use(...)`. A maioria retorna um
`TNativeMiddlewareFunc`; `HealthCheck` e `OpenAPI` usam uma classe builder cujo
`.Build` retorna o middleware.

### Segurança e controle de acesso

| Middleware | Fábrica (literal) | Use quando |
|---|---|---|
| **CORS** | `CORSMiddleware` / `CORSMiddleware(const AOptions: TCORSOptions)`; `DefaultCORSOptions` | Um front-end de navegador em outra origem chama a API. |
| **JWT** | `JWTMiddleware(const ASecret: string; const AUnauthorizedMsg: string = 'Unauthorized'; const AIssuer: string = ''; const AAudience: string = ''; ARequireExp: Boolean = False)`; também `JWTSign(APayload: TJSONObject; const ASecret: string): string` | Auth bearer HS256 sem estado; defina issuer/audience/require-exp para bloquear replay entre serviços. |
| **Digest** | `DigestMiddleware(const ARealm: string; AGetHA1: TGetHA1Func)`; `DigestHA1(const AUser, ARealm, APass: string): string` | Clientes exigem digest auth conforme RFC 2617. |
| **Security** | `SecurityMiddleware` / `SecurityMiddleware(const AOptions: TSecurityOptions)`; `DefaultSecurityOptions` | Qualquer app exposto publicamente — HSTS/CSP/X-Frame-Options/etc. |
| **Guard** | `GuardMiddleware` / `GuardMiddleware(const AAllowedMethods: TArray<string>)` | Restringir um app/grupo a verbos específicos. |
| **RateLimit** | `RateLimitMiddleware(AMaxRequests, AWindowSeconds: Integer; const AMessage: string = 'Too Many Requests'; ATrustProxy: Boolean = False; const ATrustedProxies: TArray<string> = nil; AMaxTrackedKeys: Integer = 100000)` | Limitar clientes abusivos (429). Habilite `ATrustProxy` apenas atrás de um LB confiável. |

**`TCORSOptions`**: `AllowOrigin, AllowMethods, AllowHeaders, ExposeHeaders: string; AllowCredentials: Boolean; MaxAge: Integer`.
**`TSecurityOptions`**: `HSTSMaxAge: Integer; HSTSIncludeSubDomains, HSTSPreload: Boolean; CSP, XFrameOptions, XContentTypeOptions, ReferrerPolicy, PermissionsPolicy: string`.

### Observabilidade

| Middleware | Fábrica (literal) | Use quando |
|---|---|---|
| **Logger** | `LoggerMiddleware` / `LoggerMiddleware(AOutput: TLogOutput)`; `LoggerMiddlewareJSON` / `LoggerMiddlewareJSON(AOutput)`; `LogToFile(const AFileName: string): TLogOutput` | Rastreamento de requisições; variante JSON para pipelines estruturados. |
| **Metrics** | `MetricsMiddleware(const APath: string = '/metrics')` | Expor métricas no estilo Prometheus para scraping. |
| **RequestID** | `RequestIDMiddleware` | Correlacionar logs/traces ao longo de uma requisição. |
| **HealthCheck** | builder: `TPoseidonHealthCheck.Create.BasePath(...).AddCheck(name, proc).Build` | Probes de liveness/readiness (`/health`, `/health/live`, `/health/ready`). |

`THealthCheckResult`: `Healthy: Boolean; Error: string; class function OK; class function Failed(const AReason: string)`.

### Payload e conteúdo

| Middleware | Fábrica (literal) | Use quando |
|---|---|---|
| **Compression** | `CompressionMiddleware(AMinSize: Integer = 860)` | Encolher respostas de texto/JSON (gzip). |
| **BodyLimit** | `BodyLimitMiddleware(AMaxBytes: Int64)` | Defender contra DoS de payload superdimensionado. |
| **Cache** | `CacheMiddleware(ATTLSeconds: Integer = 60; AMaxBytes: Int64 = 52428800)` / `CacheMiddleware(const AOptions: TCacheOptions)` | Cachear GETs idempotentes caros (ETag/304). |
| **Static** | `StaticMiddleware(const AUrlPrefix, ARootDir: string; AEnableGzip: Boolean = True)` | Servir um diretório de assets sob um prefixo de URL. |

**`TCacheOptions`**: `TTLSeconds: Integer; MaxBytes: Int64; MaxEntries: Integer; class function Default`.

### Resiliência e roteamento

| Middleware | Fábrica (literal) | Use quando |
|---|---|---|
| **Timeout** | `TimeoutMiddleware(ATimeoutMs: Integer)` | Limitar handlers/upstreams lentos. |
| **CircuitBreaker** | `CircuitBreakerMiddleware(AErrorThresholdPct: Integer = 50; AWindowSec: Integer = 60; AOpenDurationSec: Integer = 30)` | Falhar rápido (503) quando a taxa de erro do downstream dispara. |
| **Proxy** | `ProxyMiddleware(const AUpstream: string)`; `ProxyMiddlewareWithPrefix(const AUpstream, APrefix: string)` | Reverse-proxy para um backend (gateway). |

### Definição de API e erros

| Middleware | Fábrica (literal) | Use quando |
|---|---|---|
| **OpenAPI** | builder: `TPoseidonOpenAPI.Create.Title(...).Version(...).AddRoute(m, p, s, tags).Build` | Publicar uma spec OpenAPI 3.x + Swagger UI. |
| **ProblemDetails** | `ProblemDetailsMiddleware` | Respostas de erro padronizadas conforme RFC 7807. |
| **Validation** | `ValidationMiddleware` | Transformar falhas de validação por atributo em JSON 422. |

---

> 🇺🇸 Read this document in English: [API-REFERENCE.md](./API-REFERENCE.md)
