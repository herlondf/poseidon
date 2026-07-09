---
name: poseidon-http1-src
description: Especialista em IMPLEMENTAR e corrigir o caminho HTTP/1.x do Poseidon — parser de request (Poseidon.Net.HTTP1.Parser), pipeline de despacho (Poseidon.Net.Dispatcher), montagem de resposta (Poseidon.Net.ResponseBuilder) e roteamento (Poseidon.Native.Router). Use ao aplicar patches de poseidon-http1-review ou adicionar suporte a headers/métodos/features HTTP/1. Herda regras de poseidon-src (patch mínimo, thread-safety, verificação obrigatória).
---

# Implementação HTTP/1.x — invariantes a preservar

Escopo: `Poseidon.Net.HTTP1.Parser.pas`, `Poseidon.Net.Dispatcher.pas`,
`Poseidon.Net.ResponseBuilder.pas`, `Poseidon.Native.Router.pas`.
Regras gerais em `poseidon-src`. Aqui só o que é específico do HTTP/1.

## Parser (RFC 7230) — invariantes que NÃO podem quebrar

- **Incompleto ≠ inválido**. Se faltam bytes, retornar sem setar `ABadRequest`
  e sem consumir. Cliente pode mandar mais.
- `AConsumed` é EXATO — quem chama shifta o AccumBuf por esse valor. Um byte a
  mais/a menos = corrupção da próxima request no pipelining.
- Hash de headers (open-addressing): sondagem termina em O(N) do slot livre.
  Após mudança na tabela, PROVE que `content-length`, `connection`,
  `transfer-encoding` ainda são detectados sem colisão.
- Content-Length: dígitos puros, sem sinal, `Int64` (não `Integer`). Duplicatas
  conflitantes (`CL1, CL2`) → 400. `CL` + `Transfer-Encoding: chunked` → 400
  (smuggling — regra dura).
- Transfer-Encoding: coding final DEVE ser `chunked`; espaço antes de `:` → 400.
- Chunked: tamanho em hex com cap; CRLF obrigatório após dados do chunk; após
  chunk `0` consumir trailers até CRLF final. Terminador ausente → aguardar
  mais (não completar cedo).
- `obs-fold` (linha iniciada por SP/HT) → 400.
- Limite de headers e de request line = REJEITA, não trunca.

## Parser Lightweight vs Full

Lightweight não materializa headers e não detecta upgrade. Ao mexer, mantenha
a paridade de comportamento OBSERVÁVEL (bad request no mesmo cenário, mesmo
`AConsumed`). SyncDispatch usa Lightweight.

## Dispatcher

- Steps rodam em ordem, um `TDispatchStep` de cada vez.
- `Handled := True` curto-circuita. Não retirar/adicionar step sem verificar o
  contrato dos vizinhos (BadRequest limpa buffer? o próximo assume que buffer
  está intacto?).
- Caminho de erro (400/413/503) devolve buffers ao pool. Vazamento aqui é bug.
- `KeepAlive` propaga p/ conexão — respeitar `Connection: close`.
- Detecção de upgrade só no pipeline Full.

## ResponseBuilder

- **Sizing tem que casar com escrita**. `_CalcTotal` (bytes previstos) deve
  bater com `_BuildCore` (bytes gravados). Divergência = overflow (memória
  corrompida) ou underfill (lixo no wire). Some fragmento por fragmento antes
  de enviar patch.
- Sanitizar nome E valor de headers extras contra CRLF (response splitting).
  Não confie em input do middleware.
- 1xx/204/304: suprimir Content-Length E body.
- `WriteIntToBuffer` / `DigitCount` acoplados — mudar um exige mudar o outro.
- `Date` é sempre comprimento fixo (RFC IMF-fixdate).
- Variante pooled: chamador devolve buffer; `AActualLen` correto.

## Router

- Estáticas: dicionário exato, método+path CASE-SENSITIVE.
- Param: filtro por contagem de segmentos ANTES de comparar; decode SÓ do valor
  do parâmetro (não do path inteiro).
- `Lookup` retorna ponteiros/referência internos — não invalide durante
  operação. Se `Add` em runtime, precisa lock.

## Bugs típicos (padrão a evitar)

- Setar `ABadRequest` em incompleto → cliente lento fica 400.
- Off-by-one em `ABuf[I+1]` sem checar `I+1 <= AEnd`.
- Concatenação de string em O(n²) no builder (usar `TStringBuilder` ou array
  de bytes).
- Novo header no builder sem atualizar `_CalcTotal`.
- Rota param aceitar contagem errada de segmentos (matching frouxo).

## Arquivos no escopo

`src/Poseidon.Net.HTTP1.Parser.pas`, `src/Poseidon.Net.Dispatcher.pas`,
`src/Poseidon.Net.ResponseBuilder.pas`, `src/Poseidon.Native.Router.pas`.

Cross-skill: mudança que afeta connection lifetime → veja `poseidon-server-src`
e `poseidon-concurrency-src`.
