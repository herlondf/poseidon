---
name: poseidon-http1-review
description: Revisão focada do caminho HTTP/1.x do Poseidon — parser de request (Poseidon.Net.HTTP1.Parser), pipeline de despacho (Poseidon.Net.Dispatcher), montagem de resposta (Poseidon.Net.ResponseBuilder) e roteamento (Poseidon.Native.Router). Use ao auditar parsing de request line/headers/body, chunked, Content-Length vs Transfer-Encoding, keep-alive/pipelining, geração de resposta ou matching de rotas. Segue a Regra de Ouro da skill poseidon-review (só reporte o que provar).
---

# Revisão HTTP/1.x do Poseidon

Escopo: `Poseidon.Net.HTTP1.Parser.pas`, `Poseidon.Net.Dispatcher.pas`,
`Poseidon.Net.ResponseBuilder.pas`, `Poseidon.Native.Router.pas`.
Aplique a Regra de Ouro de `poseidon-review`: só reporte o que puder PROVAR
(cenário concreto + linha exata). Prove aritmética de índices e do hash de
headers à mão ou com harness `.dpr`.

## O que caçar

### Parser (RFC 7230)
- Request line: contagem de espaços, método/path/query, versão; off-by-one ao
  ler `ABuf[I+1]`; limites de tamanho da request line e do bloco de headers.
- Hash de headers (open-addressing): PROVE que nomes distintos não colidem de
  forma a se sobrescreverem; que a sondagem termina; que `content-length`,
  `connection`, `transfer-encoding` são sempre detectados.
- Content-Length: dígitos puros, overflow (Int64), OWS, duplicatas conflitantes
  (CL.CL), CL > limite de corpo.
- Transfer-Encoding: coding final deve ser `chunked`; TE desconhecido → 400;
  espaço antes de `:` (TE smuggling); CL + chunked (CL.TE) rejeitado.
- Chunked: tamanho hex (cap/overflow), CRLF após os dados de cada chunk,
  seção de trailers consumida até o CRLF terminador, terminador ausente →
  "aguardar mais dados" (não completar cedo), extensão após `;`.
- obs-fold (linha iniciada por SP/HT) → 400.
- Estado entre reads parciais: incompleto retorna sem `ABadRequest`; consumo
  (`AConsumed`) exato para o shift do AccumBuf; pipelining consome só 1 request.
- Contagem de headers: limite aplicado como rejeição, não truncamento silencioso.
- Parser Lightweight vs Full: paridade de comportamento (o Lightweight não
  materializa headers e não detecta upgrade — confirme que isso é intencional
  no fluxo SyncDispatch).

### Dispatcher (pipeline)
- Ordem dos steps; `Handled := True` curto-circuita corretamente.
- Shift do AccumBuf após `AConsumed`; `KeepAlive` propagado à conexão.
- Caminho de erro (400/413/503) libera buffers de pool e fecha/mantém conexão
  conforme keep-alive.
- Detecção de upgrade só existe no pipeline Full; método é case-sensitive.

### ResponseBuilder
- Sizing (`_CalcTotal`) casa exatamente com a escrita (`_BuildCore`) — qualquer
  divergência é overflow/underfill de buffer. PROVE somando os fragmentos.
- Sanitização de NOME e VALOR de header extra (response splitting).
- Content-Length suprimido em 1xx/204/304; body idem.
- `WriteIntToBuffer`/`DigitCount` consistentes; `Date` de comprimento fixo.
- Variante pooled: `AActualLen` correto; buffer devolvido ao pool pelo chamador.

### Router
- Estáticas: dicionário exato (método+path case-sensitive).
- Param: filtro por contagem de segmentos; comparação de método/segmento;
  decode só do valor do parâmetro. Estabilidade dos ponteiros internos de
  `TList` retornados por `Lookup` (não podem danglar se rotas forem adicionadas
  após servir).

## Lacunas comuns a verificar
100-continue, Expect, Range, HTTP/0.9, HTTP/1.0 keep-alive, header Date,
métodos incomuns, `Connection` com múltiplos tokens.

## Não reporte sem provar
Ex.: uma "colisão de hash" só é bug se você mostrar dois nomes reais que caem no
mesmo slot E que o segundo sobrescreve o primeiro de forma observável. Um
"overflow de buffer" só é bug se o sizing < bytes escritos — some e mostre.
