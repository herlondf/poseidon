# Testes & Conformidade

Como o Poseidon é validado: testes unitários/de lógica, fuzzing in-process, um
gate de compilação das duas faces e suítes de conformidade de protocolo.

## Suíte DUnitX (Windows)

O projeto de testes fica em `tests/`. Compilar e rodar:

```
tests\build_tests.bat
tests\Poseidon.Tests.exe
```

A suíte cobre as superfícies puras/de lógica (parser, HPACK, router, segurança,
validação, response builder, buffer pool, workers) e os middlewares embutidos,
além das fixtures de integração via socket real do servidor.

> **Nota:** as fixtures de integração via socket real exigem um host cujo Winsock
> suporte o I/O de extensão sobreposto (`AcceptEx` / RIO). Alguns Windows
> sandboxed ou Insider rejeitam essas chamadas com `WSAEINVAL (10022)`, o que faz
> essas fixtures falharem por motivo **ambiental** — não é defeito do Poseidon.
> Ver [Notas de plataforma](notas-de-plataforma.md). As fixtures puras/de lógica
> e de fuzz rodam sempre, sem socket.

## Fuzzing in-process

`tests/Poseidon.Tests.Fuzz.pas` fuzza as superfícies de parsing que recebem
bytes não confiáveis — `ParseHTTP1Request`, `DecodeHTTP1Chunked`,
`TH2HpackCodec.DecodeHeaders`, `TWebSocketUtils.ParseFrame` e o validador de
UTF-8 do WebSocket (`IsValidUTF8`, RFC 3629). Cada uma roda dezenas de milhares
de entradas determinísticas com seed (aleatórias + mutação) sob uma thread
watchdog **por-stall** que detecta loop infinito (um DoS). A invariante:
**nunca crashar, nunca travar, nunca vazar exceção** — o parser sempre retorna,
por mais malformada que seja a entrada.

O fuzzing roda de forma **contínua**, hospedado pelo `Poseidon.FuzzRunner`
(socket-free):

- **A cada push / PR** — `ci/run-ci.ps1` (via `.github/workflows/ci.yml`) roda o
  runner sobre o corpus determinístico de regressão como **hard gate**; qualquer
  crash bloqueia o merge.
- **Nightly** — `.github/workflows/fuzz-nightly.yml` (04:00 UTC) re-roda com
  `FUZZ_SCALE` grande e um `FUZZ_SEED` novo por-run, explorando um espaço de
  entrada muito maior e gravando o seed exato como artifact para replay
  determinístico.

O fuzzing já pegou um DoS remoto real no decoder HPACK (octetos não-UTF-8
levantavam `EEncodingError`); ver as notas de segurança.

> Referência completa do runner — knobs, fixtures, como reproduzir uma falha
> noturna: [`tests/FUZZING.md`](../../../tests/FUZZING.md).

## Gate de compilação das duas faces

Um bug de plataforma atrás de `{$IFDEF MSWINDOWS}` / `{$ELSE}` (IOCP/RIO vs
epoll/io_uring) fica latente até o deploy porque cada CI compila só uma face. O
gate compila as duas:

```
pwsh ci\build-both-faces.ps1
```

- **Windows (Win64):** build completo do projeto DUnitX (`dcc64`).
- **Linux (Linux64):** compile-check dos backends epoll / io_uring
  (`dcclinux64`). Sem o SDK Linux o passo de link é pulado (só erro de
  COMPILAÇÃO reprova o gate); num runner Linux com o SDK, linka de verdade.

Workflow de CI: `.github/workflows/ci-both-faces.yml` (aponta para um runner
self-hosted rotulado `delphi`, já que o compilador Delphi é licenciado e não
existe nos runners hospedados do GitHub).

## Conformidade HTTP/2 (h2spec) no Linux

Como o caminho via socket real é exercitado no **Linux** (onde a limitação de
Winsock do Windows acima não se aplica), a conformidade HTTP/2 roda contra um
build Linux numa distro WSL descartável:

```
pwsh tests\run-h2spec.ps1              # cria a distro, compila, roda o h2spec
pwsh tests\run-h2spec.ps1 -Cleanup     # remove a distro no final
```

O script cross-compila um servidor h2-over-TLS headless para Linux64, (re)cria
uma distro WSL Ubuntu, provisiona (OpenSSL + h2spec), roda a suíte e imprime o
sumário. Precisa dos stubs de linker Linux do repo Benchmark (ver o cabeçalho do
script para o caminho esperado).

> **Status atual:** **h2spec 145/146** sobre TLS/ALPN contra o backend io_uring
> do Linux (0 falhas, 1 skip). A corrida de TLS pós-handshake que bloqueava isso
> foi resolvida (ver [Notas de plataforma](notas-de-plataforma.md)).

## Conformidade WebSocket (Autobahn)

Roda a Autobahn TestSuite contra um build Linux (`tests/autobahn/`). Atual:
**247/247** core (suites 1–8, 10, 11) + **42/42** nos casos 9.\* de payload
grande, 0 falhas.
