# Poseidon

> *Deus dos mares - poder bruto, velocidade incomparavel.*

<p align="center">
  <img src="docs/logo.png" alt="Poseidon" width="320"/>
</p>

<p align="center">
  Framework HTTP assincrono nativo, zero dependencias, para Delphi e Free Pascal.<br/>
  IOCP/RIO no Windows, io_uring/epoll no Linux - HTTP/1.1, HTTP/2, WebSocket e 20 middlewares integrados de fabrica.<br/>
  <strong>128k RPS, zero erros com 500 conexoes simultaneas.</strong>
</p>

---

## Inicio Rapido

```pascal
program MyServer;
{$APPTYPE CONSOLE}
uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"message":"pong"}');
      end);

    App.Get('/hello/:name',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"hello":"' + Ctx.Param('name') + '"}');
      end);

    App.Listen(9000, '0.0.0.0',
      procedure
      begin
        Writeln('Servidor pronto em http://localhost:9000');
        Readln;
        App.Stop;
      end);
  finally
    App.Free;
  end;
end.
```

## Por que Poseidon

| | Poseidon v2 | Horse Epoll 4.0 |
|---|---|---|
| **Throughput** (500 conn, 16 cores) | **127.532 RPS** | 3.780 RPS (61% erros) |
| **Latencia p50** | **1,92ms** | 103ms |
| **Latencia p99** | **5,51ms** | 287ms |
| **Erros** | **0** | 35K+ Non-2xx |
| **Arquitetura** | Shared-nothing per-core | Single epoll |
| **HTTP/2** | Integrado | Nao |
| **WebSocket** | Integrado | Nao |
| **SSL/TLS** | OpenSSL nativo (SNI, mTLS, ALPN) | Via Indy |
| **Middlewares** | 20 integrados | Comunidade |
| **API Nativa** | Zero-copy, baseada em instancia | N/A |

## Arquitetura: Shared-Nothing Per-Core

<p align="center">
  <img src="docs/architecture-flow_pt-br.svg" alt="Fluxo de requisicoes shared-nothing per-core do Poseidon vs. o loop unico de epoll do Horse" width="880"/>
</p>

Cada core faz tudo: accept, recv, parse, executa handler, envia resposta. Sem filas, sem locks, sem contencao. Escalamento linear com o numero de cores.

O backend de I/O e selecionado **uma unica vez** na inicializacao, com fallback automatico: **IOCP** (padrao no Windows) ou **RIO** (opt-in, polling sem syscall via `FORCE_RIO`); **io_uring** >= 5.1 (padrao no Linux) ou **epoll** (fallback / opt-in via `FORCE_EPOLL`).

---

## Performance vs. o Mercado

Sete servidores HTTP, um de cada vez, na mesma máquina e na mesma janela.

**Cenário.** Carga mista: 40% `/plaintext` (13 B), 30% `/json` (27 B), 30% `/json-large` (63 KB),
gerada por `wrk -t8 -c200` durante 300 s por framework, após 15 s de aquecimento descartado. Cada
servidor rodou em Docker com `--cpuset-cpus` fixando **2 núcleos físicos dedicados**, mais
`--cpus=2.0` e limite de **1 GB** de memória; o gerador de carga ficou isolado em outros 4 núcleos
físicos, então nunca disputou CPU com o servidor nem saturou (pico de 442% dos 800% disponíveis).
Os sete serviram payloads byte a byte idênticos e o mix medido saiu 40,0/30,0/30,0 em todos.
Host: Ryzen 7 5800H, WSL2, Linux 6.6.

uWebSockets (uws) não entra nesta tabela. Não é um framework HTTP de propósito geral: é uma
biblioteca de sockets/event-loop sem backpressure, sem timeout de conexão, sem headers de
segurança e sem upgrade de protocolo embutidos - nenhuma das features que todo outro concorrente
aqui (Poseidon incluso) paga no caminho quente. Medir throughput contra ela responde "quão rápido
é um event loop nu", não "quão rápido é este framework", que é a pergunta que esta tabela quer
responder.

| Posição | Framework | Tecnologia | Req/s | p50 | p99 | Máx | Erros |
|---:|---|---|---:|---:|---:|---:|---:|
| 1 | Actix | Rust | 37.146 | 5,12 ms | 15,21 ms | 143 ms | 0 |
| **2** | **Poseidon v2** | **Object Pascal** | **35.941** | **5,30 ms** | **10,19 ms** | **64 ms** | **0** |
| 3 | Go Fiber | Go | 30.641 | 6,39 ms | 18,60 ms | 52 ms | 0 |
| 4 | mORMot2 | Object Pascal | 28.077 | 6,88 ms | 44,80 ms | 1.810 ms | 1 |
| 5 | nginx | C | 20.281 | 9,29 ms | 20,08 ms | 307 ms | 0 |
| 6 | Kestrel | C# / .NET | 17.599 | 10,31 ms | 29,94 ms | 101 ms | 0 |
| 7 | Horse (Epoll) | Object Pascal | 2.554 | 79,63 ms | 799,25 ms | 1.990 ms | 64 |

### Consumo de recursos

Mesma execução, amostrada a cada 5 s no contêiner do servidor. Todos saturaram as duas CPUs, então
CPU não separa ninguém; memória sim.

| Posição | Framework | Tecnologia | Mem pico | Mem média | CPU média | Requisições servidas |
|---:|---|---|---:|---:|---:|---:|
| **1** | **Poseidon v2** | **Object Pascal** | **5,2 MB** | **4,3 MB** | **199%** | **10.785.241** |
| 2 | Go Fiber | Go | 7,2 MB | 6,7 MB | 197% | 9.195.118 |
| 3 | Actix | Rust | 19,2 MB | 17,1 MB | 202% | 11.145.622 |
| 4 | nginx | C | 21,8 MB | 20,8 MB | 198% | 6.086.278 |
| 5 | mORMot2 | Object Pascal | 33,8 MB | 31,3 MB | 202% | 8.425.615 |
| 6 | Kestrel | C# / .NET | 81,4 MB | 74,6 MB | 196% | 5.281.181 |
| 7 | Horse (Epoll) | Object Pascal | 116,5 MB | 99,1 MB | 196% | 766.574 |

### O que os números dizem

Segundo de sete em throughput bruto, a 3,2% do primeiro - dentro da variação entre execuções desta
máquina. Um servidor Rust escrito à mão e um framework Delphi são, nesta carga, igualmente rápidos.
Mas throughput bruto é a linha menos interessante da tabela. Leia as outras colunas:

- **Melhor p99 e melhor máximo de todo o comparativo.** 10,19 ms e 64 ms, contra 15,21 ms / 143 ms
  do Actix e 18,60 ms / 52 ms do Go Fiber. Sob limite de contêiner, a cauda é o que o usuário
  sente de verdade, e o Poseidon sustenta a cauda mais plana de todos aqui.
- **Menor consumo de memória de todo o comparativo.** 5,2 MB de pico, contra 19,2 MB do Actix,
  81 MB do Kestrel e 116 MB do Horse. São 15x menos RAM que o Kestrel para o dobro do throughput,
  o que é a diferença entre um contêiner e quatro.
- **Zero erros em 10,8 milhões de requisições.** Nenhum timeout, nenhum reset, nenhum non-2xx.
  Apenas três dos sete conseguiram isso.
- **14x o Horse**, no mesmo compilador e no mesmo runtime, com 22x menos memória.

Duas correções entraram no Poseidon durante a medição. Um relógio do idle sweep que estourava em
`UInt64` e fechava justamente as conexões **mais movimentadas** (6.405 erros de socket espúrios,
agora zero, e +12% de throughput de brinde), e o dimensionamento de IO workers que ignorava o
orçamento de CPU do contêiner (p99 31% menor em A/B pareado, 67% com 4 CPUs). A metodologia
completa vive no harness `Benchmark` separado (ponteiros em
[`docs/playbook_pt-br/07-benchmarking`](docs/playbook_pt-br/07-benchmarking)); os números
reproduzíveis deste próprio repo estão em [`samples/08-benchmark/`](samples/08-benchmark/).

<p align="center">
  <img src="docs/framework-features_pt-br.svg" alt="Comparacao de recursos de protocolo do Poseidon contra 6 outros frameworks" width="880"/>
</p>

Toda mudanca no caminho quente e validada com uma comparacao controlada antes/depois antes de ser mergeada - mesmo binario, uma mudanca por vez. A rodada de parser/dispatcher de 2026-08-07 (removeu uma alocacao redundante no header `Connection`, pulou a varredura de deteccao de upgrade em GETs sem upgrade) mediu **+1,7% de throughput**, com toda repeticao do lado "depois" superando toda repeticao do lado "antes".

---

## Funcionalidades

**Engine** - HTTP/1.1 keep-alive · HTTP/2 (ALPN h2, h2c, server push, flow control) · WebSocket (RFC 6455, permessage-deflate) · HTTPS com OpenSSL nativo (SNI, mTLS) · Compressao gzip + Brotli · Proxy Protocol v1/v2 · Graceful reload (PID file, SIGTERM, zero-downtime) · Windows 64-bit (IOCP/RIO) + Linux 64-bit (io_uring/epoll) · Delphi 11+ e Free Pascal 3.3.1

**Framework** - Router hash-map, lookup O(1), suporte a `:param` · Registro fluente de rotas (Get/Post/Put/Delete/Patch/Head/All) · Contexto de requisicao zero-copy, stack-allocated · Binding de DTO com atributos de validacao · OpenAPI 3.x + Swagger UI · RFC 7807 Problem Details · Cookies assinados (HMAC-SHA256)

**Engenharia de performance** - Contadores atomicos com padding de cache-line · I/O vetorizado (writev/WSASend) · Arquivos registrados no io_uring + multishot accept · Reciclagem de sockets via DisconnectEx (Windows) · Arena de headers thread-local · Buffer pool de 8 KB (Acquire/Release)

**20 middlewares integrados** - CORS, JWT, Logger, RateLimit, Compression, Timeout, BodyLimit, RequestID, CircuitBreaker, Metrics, Static, HealthCheck, Security, Proxy, Digest, Guard, Validation, ProblemDetails, OpenAPI, Cache

---

## Requisitos

- **Delphi 11 Alexandria ou superior**, ou **Free Pascal 3.3.1** (trunk)
- Windows 64-bit ou Linux 64-bit
- OpenSSL no PATH (apenas para HTTPS/HTTP2)

## Instalacao

Adicione `src/`, `src/compat/` e `middlewares/` ao search path do projeto:

```
<poseidon>\src
<poseidon>\src\compat
<poseidon>\middlewares
```

### Free Pascal / Lazarus

O Poseidon compila e serve sob FPC 3.3.1 no Win64 (IOCP) e Linux (io_uring/epoll)
alem do Delphi. Notas:

- Requer **FPC 3.3.1** (trunk) - `reference to` / metodos anonimos e RTTI de
  atributos nao existem no release 3.2.2. Compile com
  `-MDELPHIUNICODE -Mfunctionreferences -Manonymousfunctions -Mprefixedattributes`.
- No Linux, `cthreads` deve ser a **primeira** unit do programa (`{$IFDEF UNIX}`)
  para ativar o RTL com threads.
- Sob FPC o servidor usa **SyncDispatch** por padrao (dispatch inline); o modo
  async (worker pool) e best-effort no trunk atual do FPC.
- Gates de referencia: `tests/fpc/build-server-fpc.ps1` (Windows),
  `tests/fpc/build-linux-fpc.sh` (Linux).

## Exemplos de Uso

### Middleware

```pascal
uses
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Middleware.CORS,
  Poseidon.Middleware.JWT,
  Poseidon.Middleware.Logger;

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;

  App.Use(CORSMiddleware);
  App.Use(LoggerMiddleware);
  App.Use(JWTMiddleware('meu-segredo'));

  App.Get('/api/dados',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Status := 200;
      Ctx.ContentType := 'application/json';
      Ctx.Body := TEncoding.UTF8.GetBytes('{"dados":"protegidos"}');
    end);

  App.Listen(9000);
end.
```

### WebSocket

```pascal
App.WebSocket('/ws',
  procedure(Conn: IPoseidonWSConn; MsgType: Byte; Data: TBytes)
  begin
    Conn.Send(Data);  // echo
  end);
```

### SSL/TLS

```pascal
App.ConfigureSSL('cert.pem', 'key.pem');
App.AddSSLCert('api.exemplo.com', 'api-cert.pem', 'api-key.pem');  // SNI
App.EnableHTTP2;
App.Listen(443);
```

Mais receitas (grupos de rotas, graceful reload, hardening de seguranca, metricas) vivem no [playbook](docs/playbook_pt-br/README.md).

---

## Documentacao

- [Referência de API](docs/API-REFERENCE_pt-br.md) · [API Reference (EN)](docs/API-REFERENCE.md)
- [Playbook (English)](docs/playbook/README.md)
- [Playbook (Portugues)](docs/playbook_pt-br/README.md)
- [FuzzRunner - fuzzing contínuo dos parsers](tests/FUZZING.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Como contribuir (pt-BR)](docs/CONTRIBUTING_pt-br.md)

## A Familia Olimpica

> *Poseidon comanda os mares - poder bruto, a engine assíncrona sob as ondas.*
> *Triton, seu filho, guarda as profundezas - retém as conexões que não podem se perder.*
> *Hermes percorre todos os reinos - carrega mensagens, mais rápido que qualquer onda.*
> *Hefesto forja nas profundezas - invisível, incansável, transformando matéria bruta em obra acabada.*
> *Apollo é o deus da luz e da verdade - traz tudo à luz.*

| Projeto | Mito | Papel |
|---------|------|-------|
| **Poseidon** (este) | Deus dos mares | Framework HTTP assíncrono nativo + engine de I/O - IOCP/RIO, io_uring/epoll |
| [**Triton**](https://github.com/herlondf/triton) | Filho de Poseidon, guardião das profundezas | Pool de recursos genérico - conexões, clientes, SMTP |
| [**Hermes**](https://github.com/herlondf/hermes) | Mensageiro dos deuses, guia entre os reinos | Cliente Redis - chave-valor, pub/sub, mensageria |
| [**Hefesto**](https://github.com/herlondf/hefesto) | Forjador dos deuses, trabalha nas sombras | Jobs em background - filas, workers, retry, agendamento |
| [**Apollo**](https://github.com/herlondf/apollo) | Deus da luz e da verdade, traz as coisas à luz | Logging estruturado - sinks assíncronos, OTLP, Seq, Loki, Datadog |

---

## Licenca

MIT

---

> 🇺🇸 Read this document in English: [README_en.md](./README_en.md)
