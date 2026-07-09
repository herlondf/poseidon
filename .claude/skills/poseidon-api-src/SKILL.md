---
name: poseidon-api-src
description: Especialista em IMPLEMENTAR e corrigir a API pública, DX e tipos-base do Poseidon — Poseidon.pas (fachada), Interfaces (contratos de injeção), Net.Types + Native.Types (contexto e tipos de rede), Status/MIME, Problem (RFC 7807), Validation (RTTI/atributos), Exception. Use ao aplicar patches de poseidon-api-review, evoluir a fachada, adicionar helpers no TNativeRequestContext, novo status/MIME, ou novo atributo de validação. Herda regras de poseidon-src. Mudança aqui é BREAKING por default — cuidado.
---

# Implementação da API pública — invariantes

Escopo: `src/Poseidon.pas`, `src/Poseidon.Net.Interfaces.pas`,
`src/Poseidon.Net.Types.pas`, `src/Poseidon.Native.Types.pas`,
`src/Poseidon.Status.pas`, `src/Poseidon.Problem.pas`,
`src/Poseidon.Validation.pas`, `src/Poseidon.Exception.pas`.
Regras gerais em `poseidon-src`.

## Regra de compatibilidade — API é contrato

Estas units definem o que usuários consomem. Mudança aqui quebra código
externo. Antes de editar:
- Assinatura de método público muda → é breaking. Só faça se o achado
  justificar. Documente.
- Novo método é aditivo (OK).
- Renomear identificador público = breaking.
- Mudar tipo de campo em `TNativeRequestContext` = breaking se afetar layout
  ou semântica.

## Interfaces

- Toda `IPoseidon*` DEVE ter GUID único. Nunca copie de outra. Gere pelo IDE
  ou por `CreateGUID`.
- ISP: interface pequena. Ao adicionar método, considere se cabe numa
  interface irmã em vez de engordar a existente.
- `IBufferPool` / `ISSLProvider` etc.: injeção via construtor do servidor;
  `nil` = default real. Nova interface segue mesmo padrão.

## TNativeRequestContext (Native.Types)

- Estrutura central passada por `var` para middlewares e handlers.
- Campos são MUTÁVEIS. Cada middleware pode ler/escrever headers, body,
  status, `Handled`.
- Novo helper (Header/Query/Param) → método/property no `TNativeRequestContext`
  ou função em `Poseidon.pas`. Escolha um lugar e não duplique.
- `Handled := True` = curto-circuita cadeia. Documente semântica em qualquer
  helper que setar isso.

## Status / MIME (Status.pas)

- Constantes `THttpStatus.*` cobrem 1xx-5xx. Se adicionar, mantenha ordem
  numérica e comentário RFC.
- `TMimeType` extensível. Novo MIME: constante + entrada no lookup se
  aplicável.

## Problem (RFC 7807)

- `TProblemDetails` conforma com o RFC: `type`, `title`, `status`, `detail`,
  `instance`, mais extensões arbitrárias.
- Content-Type de resposta = `application/problem+json` (não
  `application/json`).
- Ao gerar, escape valores. Não confie em input do handler.

## Validation (Validation.pas)

- Atributos declarativos via RTTI: `[Required]`, `[MinLen(3)]`, etc.
- Novo atributo: descende de `TCustomAttribute` do projeto; register em
  runtime pela RTTI (não precisa `RegisterClass`).
- Validação retorna coleção de erros — não relança. Chamador decide o que
  fazer (traduzir para problem+json normalmente).

## Exception

- `EPoseidonException` = base. Filhas por categoria (`EPoseidonHttp`,
  `EPoseidonProtocol`, `EPoseidonConfig`).
- Não use `Exception` genérica em API pública. O consumidor deve poder
  filtrar por tipo.

## Net.Types

- Tipos de rede compartilhados (aliases de socket, TSockAddr).
- Aliases plataforma-específicos ficam aqui. Ver `poseidon-portability-src`.
- Não vazar `Winapi.Winsock2.TSocket` cross-plat sem alias.

## Poseidon.pas (fachada)

- Construtor com dependências opcionais (Interfaces). Todas com default `nil`
  para preservar API atual.
- Métodos fluentes retornam `Self` para encadear (`Use(...).Get(...).Post(...)`).
- Ao adicionar overload, mantenha um sabor "sem opção" que compile código
  existente.

## Bugs típicos

- Interface nova com GUID copiado (bug clássico Delphi — dispatch aleatório).
- Adicionar campo em `TNativeRequestContext` mudando layout binário e
  quebrando middlewares compilados contra versão anterior (só relevante para
  usuários que distribuem binários; para lib source é OK).
- `TProblemDetails` gerado com `application/json` em vez de
  `application/problem+json`.
- Validation lançando exceção em vez de retornar coleção.
- Nova constante de status conflita com número existente.

## Arquivos no escopo

`src/Poseidon.pas`, `src/Poseidon.Net.Interfaces.pas`,
`src/Poseidon.Net.Types.pas`, `src/Poseidon.Native.Types.pas`,
`src/Poseidon.Status.pas`, `src/Poseidon.Problem.pas`,
`src/Poseidon.Validation.pas`, `src/Poseidon.Exception.pas`.

Cross-skill: middleware usa contexto → `poseidon-middlewares-src`. Handler
retorna problem+json → mesmo. Novo helper que muta body → veja
`poseidon-http1-src` (ResponseBuilder).
