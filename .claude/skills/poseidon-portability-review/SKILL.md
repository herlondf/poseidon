---
name: poseidon-portability-review
description: Revisão focada de portabilidade Windows 64-bit ↔ Linux 64-bit do Poseidon e dos backends de I/O (IOCP, RIO, epoll, io_uring, Pool.Socket). Use ao auditar código específico de plataforma, divergência de tipos em parâmetros var, APIs que resolvem para a unit errada, tamanho de handle de socket, ou qualquer coisa sob {$IFDEF MSWINDOWS}/{$ELSE}. Especialmente útil porque o CI Linux não compila o backend Windows (e vice-versa), então bugs de uma plataforma ficam latentes. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão de portabilidade Win64/Linux do Poseidon

Escopo: `src/Poseidon.Net.IO.IOCP.pas`, `IO.RIO.pas`, `IO.Epoll.pas`,
`IO.IOUring.pas`, `Poseidon.Net.Pool.Socket.pas`, e qualquer `{$IFDEF}` de
plataforma no restante da lib. Aplique a Regra de Ouro de `poseidon-review`.

## Por que esta skill existe
O `HttpServer` seleciona o backend por `{$IFDEF MSWINDOWS}`. No Linux, o código
Windows (RIO/IOCP/Pool.Socket) vira stub e NUNCA é compilado pelo CI — então
erros de tipo/compilação e bugs de runtime específicos do Win64 passam
despercebidos (e o simétrico vale para o backend Linux). Revise cada backend na
sua plataforma alvo mentalmente, e confirme os tipos de RTL/WinAPI no fonte.

## Padrões de bug a caçar (com exemplos reais já corrigidos)

- **`var` vs ponteiro em APIs**: passar `@X` onde a assinatura pede `var`.
  Ex.: `WSAIoctl(..., @LBytes, ...)` — o parâmetro `lpcbBytesReturned` é
  `var DWORD`, então o correto é `LBytes` (sem `@`). Verifique CADA parâmetro
  contra `Winapi.Winsock2`/`Winapi.Windows`.
- **Divergência de tipo em `var`/`TInterlocked`**: `TInterlocked.Read` só aceita
  `var Int64` na RTL 11 — um campo `Integer` (ex.: `FShutdown`) usado com `Read`
  dá E2033. Prefira `Int64` para flags atômicas lidas com `Read`.
- **`const` passado como `var`**: `TBufferPool.Release(var TBytes)` não aceita um
  parâmetro `const AData`. Copie para uma local antes.
- **API resolvida para a unit errada**: `DeleteFile(string)` resolve para a
  versão `PWideChar` de `Winapi.Windows` quando essa unit vem depois de
  `System.SysUtils` no uses → E2010. Qualifique: `System.SysUtils.DeleteFile`.
  Cuidado com `FileExists`, `MoveFile`, `GetTickCount`, etc. idem.
- **Visibilidade transitiva frágil**: units que usam `TPair<>` sem
  `System.Generics.Collections` no `uses` só compilam por transitividade em
  certos contextos → adicione a unit explicitamente.
- **Tamanho de handle de socket**: `TSocket`/`NativeUInt` (64-bit no Win64) vs
  `Integer` — truncamento ao converter; comparações com `INVALID_SOCKET`.
- **Endianness / packing**: leitura de campos de rede via `PUInt32`/`Move`
  assume little-endian do host; structs de WinAPI/io_uring com alinhamento.
- **Ifdef assimétrico**: um `{$IFDEF MSWINDOWS}` sem o `{$ELSE}` correspondente,
  ou branch Linux que não cobre o mesmo caso.

## Como validar
Compile o backend alvo isoladamente com `dcc64` (Windows) num `.dpr` mínimo que
apenas `uses Poseidon.Net.HttpServer;` — isso puxa IOCP+RIO+Pool.Socket e revela
erros latentes de Win64 sem precisar da suíte inteira. No Linux, o análogo com o
compilador Linux do Delphi (ou revisão manual, se indisponível).

## Não reporte sem provar
Um "erro de tipo Win64" deve citar a assinatura da RTL/WinAPI e o parâmetro
divergente. Prefira compilar e mostrar o erro do compilador a especular.
