---
name: poseidon-api-review
description: Revisão focada da API pública, DX e tipos-base do Poseidon — a fachada (Poseidon.pas), contratos de injeção (Poseidon.Net.Interfaces), tipos de rede e do contexto nativo (Poseidon.Net.Types, Poseidon.Native.Types), status/MIME (Poseidon.Status), problem+json RFC 7807 (Poseidon.Problem), exceções (Poseidon.Exception) e validação por RTTI/atributos (Poseidon.Validation). Use ao auditar semântica do TNativeRequestContext, helpers de header/query/param, conformidade do problem+json, e o validador de atributos. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão da API pública e tipos-base do Poseidon

Escopo: `Poseidon.pas`, `Poseidon.Net.Interfaces.pas`, `Poseidon.Net.Types.pas`,
`Poseidon.Native.Types.pas`, `Poseidon.Status.pas`, `Poseidon.Problem.pas`,
`Poseidon.Exception.pas`, `Poseidon.Validation.pas`. Aplique a Regra de Ouro de
`poseidon-review`: só reporte o que puder PROVAR (cenário + linha). Aqui muitos
"achados" são de correção sutil + DX, não crash — mas ainda exigem prova.

## O que caçar

### TNativeRequestContext (Native.Types) — o record é stack-allocated, campos
referenciam o request parseado sem cópia.
- `Header`/`Param`: busca linear O(n) case-insensitive (`SameText`). Confirme que
  headers duplicados retornam o primeiro (comportamento definido) e que nomes
  vazios não casam acidentalmente.
- `Query`: faz `Split(['&'])` e `Split(['='], 2)` + `TNetEncoding.URL.Decode`.
  Caça: chave sem `=` (ignorada — ok?), `+` vs `%20`, valor com `=` interno
  (preservado pelo limite 2 — confirme), decode lançando em `%`-inválido.
- `ExtraHeaders` é `TArray<TPair<string,string>>` que middlewares crescem com
  `SetLength(n+1)` — O(n²) sob muitos headers (perf) e NENHUMA sanitização aqui
  (a sanitização está no ResponseBuilder — confirme que TODO valor extra passa
  por lá; ver poseidon-security-review sobre Content-Type).
- `Body` vs `RawBody`: `RawBody` é o corpo da requisição; `Body` é a resposta.
  Um handler que lê `Body` esperando o request lê lixo/resposta anterior.

### Fachada (Poseidon.pas)
- Só re-exporta tipos (`X = Unit.X`). Confirme que todo tipo público prometido
  no README está re-exportado e que nenhum alias aponta para tipo renomeado.

### Interfaces (Net.Interfaces)
- `DefaultBufferPool`/`DefaultSSLProvider`: singletons lazy com comentário
  explícito "not thread-safe at init". PROVE se o primeiro uso pode vir de uma
  IO-thread (não só do main no startup) — se sim, corrida de init com dois
  objetos criados e um vazando. Marque plataforma.
- `IBufferPool.Release(var ABuf)` zera o `var`? O chamador não pode reter o
  buffer após release (use-after-release lógico).

### Problem (RFC 7807)
- `ToJSON` emite `type`/`title`/`status` sempre; `detail`/`instance` só se não
  vazios. Confirme que `TJSONObject` retornado é liberado pelo chamador (vaza se
  não). `CanonicalTitle` cobre os status usados; default "Error" para desconhecido.
- `FromException` usa `E.Status.ToInteger` — se `EPoseidonException` sem status
  setado, vira 0 → problem+json com `status:0` (inválido). Verifique o default.

### Validation (RTTI + atributos)
- `TPoseidonValidator.Validate` percorre `GetFields` (campos, não properties!):
  atributos em properties são ignorados silenciosamente — DX trap. Confirme se é
  intencional.
- `RequiredAttribute`: numérico 0 é "válido" (comentário linha 98) — então
  `Required` num Integer nunca falha. Correto por design, mas documente.
- `MinLength`/`MaxLength` usam `AValue.ToString` (não `AsString`): para um campo
  não-string, `ToString` dá representação textual e mede errado. Prove com um
  Integer anotado com `MinLength`.
- `EmailAttribute`/`PatternAttribute`: `TRegEx.IsMatch` com input gigante →
  ReDoS? O padrão de email é linear, mas `Pattern` custom é escolha do dev.
- `RangeAttribute` usa `AsExtended`: em campo string lança exceção (não retorna
  erro de validação) — falha dura vs falha de validação.
- `Validate` cria `TRttiContext` e libera em `finally` — ok. `ValidateOrRaise`
  junta mensagens com `; ` e levanta `EPoseidonValidation`.

### Status/Exception
- `THTTPStatus`/`TMimeType`: enum→código/texto sem furos; conversões
  `ToInteger`/`ToString` consistentes.
- Hierarquia de `EPoseidon*`: cada exceção carrega status coerente; nenhuma
  engole a mensagem original.

## Não reporte sem provar
"Vaza TJSONObject" só é bug se houver um caminho que chama `ToJSON` e não libera —
mostre o call-site. "MinLength mede errado" exige o tipo de campo concreto e o
valor que passa/falha indevidamente.
