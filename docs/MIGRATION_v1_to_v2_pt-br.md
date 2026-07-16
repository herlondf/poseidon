# Migrando para o Poseidon v2

O Poseidon **v2** é o motor nativo, zero-copy (`TPoseidonServer` +
`TNativeRequestContext`). O modelo de programação da **v1** é a API compatível
com Horse (`THorse` + `THorseRequest`/`THorseResponse`), sobre a qual muitos
serviços existentes rodam em produção hoje.

Você tem **dois caminhos de migração**. Escolha com base em quanto quer mudar
agora.

| Caminho | Esforço | Retorno |
|---|---|---|
| **A. Manter a camada de compatibilidade** | Mínimo — recompilar contra o shim de compatibilidade com Horse | Zero reescrita de handlers; roda no motor v2 como está |
| **B. Portar para a API nativa** | Reescrita por handler | Melhor throughput (~15% mais rápido que o compat no benchmark) e toda a DX do v2 (contexto tipado, middlewares nativos) |

Ambos os caminhos rodam sobre o mesmo motor v2 (IOCP/RIO no Windows,
epoll/io_uring no Linux). O Caminho A é o primeiro passo seguro; o Caminho B é
onde estão a performance e a ergonomia.

---

## Caminho A — Manter a camada compatível com Horse

O shim de compatibilidade (`compat/Horse.pas`) reexporta os tipos do Horse sobre
o Poseidon, então o código existente baseado em `THorse` compila e roda sem
alterações. Este é o primeiro movimento recomendado: troque o motor, mantenha
seus handlers, valide em staging e porte os caminhos quentes depois.

```pascal
uses
  Horse;  // resolves to the Poseidon compat shim on the search path

begin
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);
  THorse.Listen(9000);
end;
```

Nada no código do seu controller/middleware muda. Confirme que a unit de
compatibilidade está em primeiro lugar no seu unit search path.

---

## Caminho B — Portar para a API nativa

O modelo nativo funde request e response em um único
`var Ctx: TNativeRequestContext` alocado na pilha — sem alocação de heap, sem
contagem de referências por request. Este é o caminho mais rápido e libera o
conjunto de middlewares nativos.

### O formato da mudança

**v1 (Horse):** um singleton global, dois parâmetros, um construtor fluente de
resposta.

```pascal
procedure CustomersFind(Req: THorseRequest; Res: THorseResponse);
begin
  LObj := LDAO.FindById(StrToIntDef(Req.Params['id'], 0));
  if LObj = nil then
    Res.Status(404).Send('Not found')
  else
    Res.ContentType('application/json').Send(LObj.ToJSON);
end;

// registration
THorse.Get('/customers/:id', CustomersFind);
THorse.Listen(9000);
```

**v2 (nativo):** uma instância própria, um único `var Ctx`, campos de resposta
atribuídos.

```pascal
procedure CustomersFind(var Ctx: TNativeRequestContext);
var
  LObj: TCustomer;
begin
  LObj := LDAO.FindById(StrToIntDef(Ctx.Param('id'), 0));
  if LObj = nil then
  begin
    Ctx.Status := 404;
    Ctx.Body := TEncoding.UTF8.GetBytes('Not found');
  end
  else
  begin
    Ctx.ContentType := TMimeType.ApplicationJSON;   // 'application/json'
    Ctx.Body := TEncoding.UTF8.GetBytes(LObj.ToJSON);
  end;
end;

// registration
var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.Get('/customers/:id', CustomersFind);
    App.Listen(9000);
  finally
    App.Free;
  end;
end;
```

### Mapeamento da API

| v1 — Horse | v2 — nativo | Observações |
|---|---|---|
| `THorse` (singleton global) | `TPoseidonServer` (instância própria) | Faça `Create`; faça `Free`. Múltiplas instâncias em portas distintas são permitidas. |
| `THorse.Get/Post/Put/Delete/Patch(path, cb)` | `App.Get/Post/Put/Delete/Patch(path, cb)` | Mesmos verbos; também `Head` e `All`. Fluente — cada um retorna `App`. |
| `THorse.Use(mw)` | `App.Use(mw)` | Cadeia de middleware; veja o mapeamento de middlewares abaixo. |
| `THorse.Listen(9000)` | `App.Listen(9000)` | Bloqueia até o shutdown, igual à v1. |
| `procedure(Req; Res)` | `procedure(var Ctx: TNativeRequestContext)` | Um contexto fundido por `var`. |
| `procedure(Req; Res; Next)` | `procedure(var Ctx; ANext: TProc)` | Assinatura de middleware. Chame `ANext` para continuar, omita para interromper. |
| `Req.Params['id']` | `Ctx.Param('id')` | Parâmetros de rota. |
| `Req.Query['q']` | `Ctx.Query('q')` | Query string (URL-decoded). |
| `Req.Headers['X']` | `Ctx.Header('X')` | Headers de request (case-insensitive). |
| `Req.Body` (string) | `Ctx.RawBody` (`TBytes`) | O body de entrada é bytes; decodifique com `TEncoding.UTF8.GetString`. |
| `Res.Status(code)` | `Ctx.Status := code` | Atribua, não encadeie. Use as constantes `THTTPStatus.*` se preferir. |
| `Res.ContentType(ct)` | `Ctx.ContentType := ct` | Use as constantes `TMimeType.*`. |
| `Res.Send(text)` | `Ctx.Body := TEncoding.UTF8.GetBytes(text)` | O body de saída é `TBytes`. |
| `Res.Send(text)` e então 200 implícito | `Ctx.Status` tem padrão 200 | Defina `Ctx.Status` apenas para sobrescrever. |
| adicionar um header de resposta | `Ctx.ExtraHeaders` | Anexe `TPair<string,string>`. |

### Pegadinhas comuns

- **Bodies são `TBytes`, não `string`.** Tanto `RawBody` (entrada) quanto `Body`
  (saída) são arrays de bytes. Envolva com `TEncoding.UTF8.GetBytes` /
  `GetString`. É isso que torna o caminho zero-copy e binary-safe.
- **Sem `Res` fluente.** Atribua `Status`, `ContentType`, `Body` como campos —
  não há cadeia `.Status().Send()`.
- **O lifetime é seu.** `TPoseidonServer` é uma instância que você
  `Create`/`Free` (geralmente em um `try/finally`), não um singleton global do
  processo.
- **Handlers recebem `var Ctx`.** O `var` importa — o contexto é um record
  passado por referência; não o copie.

### Mapeamento de middlewares

Middlewares de terceiros do Horse (`HorseCORS`, `Jhonson`, shims de JWT, etc.)
mapeiam para units de middleware first-party do Poseidon em `middlewares/`.
Adicione a unit ao `uses` e instale com `App.Use(...)`:

| Preocupação | Factory de middleware do Poseidon |
|---|---|
| CORS | `CORSMiddleware` |
| Autenticação JWT bearer | `JWTMiddleware(secret, ...)` |
| Autenticação Digest | `DigestMiddleware(realm, getHA1)` |
| Headers de segurança (helmet) | `SecurityMiddleware` |
| Rate limiting | `RateLimitMiddleware(max, windowSec)` |
| Log de acesso | `LoggerMiddleware` / `LoggerMiddlewareJSON` |
| Compressão gzip | `CompressionMiddleware` |
| Arquivos estáticos | `StaticMiddleware(prefix, root)` |
| Request ID | `RequestIDMiddleware` |
| Health checks | Builder `TPoseidonHealthCheck` |
| Métricas (Prometheus) | `MetricsMiddleware` |
| Erros RFC 7807 | `ProblemDetailsMiddleware` |
| Validação de DTO → 422 | `ValidationMiddleware` (+ atributos de `Poseidon.Validation`) |

Veja a lista completa e as assinaturas na [Referência da API — Middlewares](./API-REFERENCE_pt-br.md#middlewares).

---

## Sequência de migração sugerida

1. **Recompile sobre a camada de compatibilidade (Caminho A).** Valide o app
   inteiro no motor v2 com zero alterações de handler. Rode a suíte; publique em
   staging.
2. **Soak & benchmark.** Confirme a estabilidade e meça seu throughput de
   baseline.
3. **Porte os caminhos quentes para o nativo (Caminho B).** Reescreva primeiro
   os controllers de maior tráfego — é aí que cai a folga de ~15% do motor.
4. **Adote os middlewares nativos.** Substitua os middlewares de terceiros do
   Horse pelos equivalentes first-party conforme porta cada grupo de rotas.
5. **Remova o shim de compatibilidade** quando não restar mais nenhum código
   `THorse`.

Resumo de breaking changes: as únicas quebras duras são a **fusão de
request/response** (`Req`+`Res` → `var Ctx`) e os **bodies em `TBytes`**. Todo o
resto é uma renomeação mecânica. A camada de compatibilidade permite adiar até
mesmo essas até você decidir portar.

---

> 🇺🇸 Read this document in English: [MIGRATION_v1_to_v2.md](./MIGRATION_v1_to_v2.md)
