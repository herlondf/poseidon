---
name: poseidon-compression-review
description: Revisão focada de compressão do Poseidon — carregamento lazy do Brotli (Poseidon.Net.Brotli), o middleware de compressão de resposta (middlewares/Poseidon.Middleware.Compression) e a negociação Accept-Encoding/Content-Encoding (gzip, deflate, br), incluindo o permessage-deflate do WebSocket. Use ao auditar seleção de codec, limites de tamanho/OOM na (des)compressão, thread-safety do load lazy da lib nativa, e correção do quadro comprimido. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão de compressão do Poseidon

Escopo: `Poseidon.Net.Brotli.pas`, `middlewares/Poseidon.Middleware.Compression.pas`
e o caminho `permessage-deflate` em `Poseidon.Net.WebSocket*`. Aplique a Regra de
Ouro de `poseidon-review`: só reporte o que puder PROVAR (cenário + linha).

## O que caçar

### Brotli (load lazy de lib nativa)
- `EnsureInit` protegido por `FLock` (TCriticalSection): confirme que a checagem
  de `FInitDone` é feita DENTRO do lock (double-checked locking sem barreira é
  bug em teoria; aqui verifique se há corrida real entre threads no primeiro uso).
- `IsAvailable`/`Compress` quando a lib está ausente: `Compress` levanta
  `EPoseidonBrotli` — o chamador (middleware) trata e cai para não-comprimido,
  nunca deixa a exceção vazar para a conexão.
- `BrotliEncoderCompress` recebe `encoded_size` como IN/OUT: o buffer de saída
  é dimensionado com folga (encoder pode exigir > input em dados incompressíveis).
  Se `SetLength` do output < necessário e a API retornar sucesso truncado → corpo
  corrompido. PROVE o dimensionamento.
- `NativeUInt`/`PNativeUInt` e `cdecl`: assinaturas idênticas em Win64 e Linux64
  (ambos LP64/LLP64 têm NativeUInt = 8 bytes — ok, mas confirme).
- `Decompress` (usado em testes): sem teto de tamanho → bomba de descompressão.
  Marcar se exposto a entrada não confiável.

### Middleware de compressão de resposta
- Negociação `Accept-Encoding`: parse de qualidade (`q=`), `identity`, `*`,
  `br` vs `gzip` vs `deflate`; escolher codec suportado E disponível em runtime.
- Não comprimir o que não vale: 204/304, corpo vazio, tipos já comprimidos
  (image/*, video/*, application/zip). Comprimir 204 e ainda setar
  `Content-Encoding` é violação.
- Setar `Content-Encoding` e `Vary: Accept-Encoding`; recalcular/deixar o
  ResponseBuilder recomputar `Content-Length` do corpo comprimido (Content-Length
  do corpo original após comprimir = desync → HIGH).
- Duplo-encoding: middleware roda sobre resposta que já tem `Content-Encoding`.
- Interação com `SendFile`/static: arquivo servido via sendfile não passa pelo
  buffer — o middleware não deve alegar tê-lo comprimido.

### permessage-deflate (WebSocket)
- RSV1 setado só quando o codec foi negociado no handshake; inflar antes de
  checar o limite de payload é bomba de descompressão (ver poseidon-websocket-review).
- Contexto de deflate por-mensagem vs persistente (`no_context_takeover`).

## Não reporte sem provar
Um "buffer truncado do Brotli" só é bug se você mostrar o caminho em que o output
alocado < bytes que a API escreve. "Não comprime X" só é bug se X deveria ser
comprimido por contrato — cite a regra.
