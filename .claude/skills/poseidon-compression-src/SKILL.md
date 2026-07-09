---
name: poseidon-compression-src
description: Especialista em IMPLEMENTAR e corrigir compressão e streaming de arquivo do Poseidon — Poseidon.Net.Brotli (load lazy da lib nativa), Poseidon.Net.SendFile (kernel-side send: TransmitFile Windows / sendfile Linux). Use ao aplicar patches de poseidon-compression-review (thread-safety do load lazy, limites de descompressão, negociação Content-Encoding) ou adicionar codec/estratégia de envio. Middleware Compression NÃO entra aqui: use poseidon-middlewares-src. Herda regras de poseidon-src.
---

# Implementação de compressão e SendFile — invariantes

Escopo: `src/Poseidon.Net.Brotli.pas`, `src/Poseidon.Net.SendFile.pas`.
Regras gerais em `poseidon-src`. O middleware de resposta comprimida vive em
`middlewares/Poseidon.Middleware.Compression.pas` — outra skill.

## Brotli — load lazy da lib nativa

- `libbrotli` carregada em runtime (dlopen/LoadLibrary). Primeira chamada
  paga o custo; depois é rápida.
- **Thread-safety do load**: primeira request paralela pode iniciar 2x. Use
  `TInterlocked.CompareExchange` ou lock ao inicializar. Nunca "if not
  loaded then load" sem proteção.
- Falha ao carregar: `Encode`/`Decode` retornam erro (não crash). Middleware
  deve degradar para outro codec (`gzip`, `deflate`).
- Descarga (unload) na shutdown: chamada única, com barreira de que ninguém
  mais usa.

## Descompressão — teto obrigatório

- Bomba de brotli/gzip/deflate: 1KB comprimido pode virar 100MB. Aplicar
  teto:
  - Limite de tamanho descomprimido acumulado por request.
  - Verificar EM CADA ITERAÇÃO de descompressão, não só no fim.
  - Excedeu → abortar + erro (usuário do middleware retorna 413 ou fecha
    conexão conforme protocolo).
- Nunca descomprima TODO o corpo em memória sem checar limite intermediário.

## Negociação de codec (visto pelo middleware, aplicado aqui)

`Poseidon.Net.Brotli` só faz encode/decode. Escolha do codec fica no
middleware. Aqui:
- API de encode aceita nível de compressão (0-11 para brotli). Middleware
  passa; skill valida faixa.
- Erro de encode → propagar, não silenciar.

## SendFile — kernel-side transfer

- Windows: `TransmitFile` (kernel32 / mswsock). Sobre socket TCP. Suporta
  header/trailer buffers.
- Linux: `sendfile(2)` do kernel. Envia direto do descritor de arquivo para
  socket sem cópia user-space.

Invariantes:
- Handle de arquivo aberto SÓ para leitura, offset controlado por chamador.
- Fechar handle após uso; `try/finally CloseHandle(...)`.
- Sob TLS, `sendfile` do kernel NÃO se aplica (TLS ofusca). Ou usa `SSL_write`
  em chunks lendo o arquivo, ou desliga sendfile quando TLS ativo.
- Range Request: chamador passa offset + tamanho; skill não interpreta
  `Range` header.

## Bugs típicos

- Load duplo do Brotli sob concorrência inicial.
- Descompressão sem teto → OOM por bomba.
- Handle de arquivo vazando em erro (falta `finally`).
- `sendfile` chamado sobre TLS achando que é transparente (não é).
- Range Request com offset > file size → SendFile silencia; validar antes.

## Arquivos no escopo

`src/Poseidon.Net.Brotli.pas`, `src/Poseidon.Net.SendFile.pas`.

Cross-skill: middleware que USA estes → `poseidon-middlewares-src`
(Compression, Static). Portabilidade das syscalls → `poseidon-portability-src`.
WebSocket permessage-deflate compartilha ideia mas mora em
`poseidon-websocket-src`.
