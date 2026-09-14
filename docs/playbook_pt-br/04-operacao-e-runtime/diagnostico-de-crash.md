# Diagnóstico de crash

O que o Poseidon imprime quando o processo morre, e como transformar isso numa
correção.

> **Por enquanto, só Delphi/`dcclinux64`.** Sob FPC, `Poseidon.Diagnostics`
> falha ao compilar — ver [Notas de plataforma](notas-de-plataforma.md#free-pascal--lazarus).
> Um deploy FPC/Linux roda sem esse crash handler instalado.

## O problema que isso resolve

Um servidor de longa duração que morre de corrupção de memória no Linux entrega,
por padrão, quase nada:

```
malloc(): unaligned tcache chunk detected
Runtime error 232 at 000000000048A2C5
```

`232` é o *"Fatal signal raised on a non-Delphi thread"* do RTL do Delphi. O
endereço sozinho é inútil sem o binário exato que o produziu, e a thread que
falhou não é identificada. Pior: um overflow de heap normalmente **não** aborta
onde acontece — ele destrói o header do chunk vizinho e só estoura depois, numa
alocação sem relação nenhuma. Então mesmo um endereço resolvido costuma apontar
para um inocente.

## O que passa a sair

`TPoseidonDiagnostics.InstallCrashHandler` é chamado automaticamente pelo
`Listen()`. Em SIGSEGV / SIGABRT / SIGBUS / SIGFPE / SIGILL ele escreve no
stderr:

```
=== POSEIDON CRASH REPORT (iid=a1b2c3) ===
build  : a696b2d806862683f30ec60aa7179563f93340ad
signal : 6 - SIGABRT (abort - usually glibc heap corruption)
tid    : 7
frames :
./server[0x521398]
/lib/x86_64-linux-gnu/libc.so.6(abort+0xdf)
/lib/x86_64-linux-gnu/libc.so.6(__libc_free+0x7e)   <- o free que detectou
./server[0x521457]                                   <- sua cadeia de chamada
./server[0x52166d]
breadcrumbs:
  [nfce.emissao] POST /nfce/v1/empresa/.../nfce serie=624 rp=800000879
=== END CRASH REPORT ===
Aborted (core dumped)
```

O glibc chama `abort()` no instante em que encontra metadado de heap
corrompido, então o backtrace tirado do handler de SIGABRT cai justamente na
cadeia de `malloc`/`free` que disparou.

O handler restaura a disposição padrão e re-levanta o sinal, então o processo
continua morrendo com o sinal original e **o core dump continua sendo gerado**.
Nada é engolido.

### Resolvendo os endereços

Os frames dentro do seu binário saem como endereço cru, não como nome — o
`backtrace_symbols_fd` só resolve a tabela de símbolos dinâmicos. Resolva contra
*o mesmo binário*:

```bash
addr2line -f -C -e ./server 0x521457 0x52166d
```

O `dcclinux64` mantém símbolos por padrão; não faça `strip` no binário
publicado.

### Contra qual binário resolver

`build  :` é o `.note.gnu.build-id` do binário em execução, o mesmo valor que
`readelf -n <binario> | grep 'Build ID'` imprime. Responde "qual binário eu
busco pro `addr2line`" sem precisar adivinhar por timestamp de deploy — um
palpite errado resolve em silêncio para símbolos sem sentido, sem erro
nenhum. `(unknown - ...)` quer dizer que o linker não emitiu a nota (raro) ou
que `/proc/self/exe` não pôde ser lido no startup; o resto do relatório sai
normal.

### O que estava acontecendo nas outras threads

Um abort de corrupção de heap quase nunca acontece onde foi causado (ver
acima), então os frames sozinhos costumam apontar pra um inocente, não pra
requisição que quebrou as coisas. Chame isso de dentro do código que trata a
requisição, onde for útil saber "o que essa thread estava fazendo":

```pascal
TPoseidonDiagnostics.Breadcrumb('nfce.emissao',
  Format('POST %s serie=%s rp=%s', [ARoute, ASerie, ARP]));
```

Os últimos 32 (de qualquer thread, o mais antigo cai primeiro) saem impressos
com o *próximo* crash report, na ordem em que aconteceram — não só os da
thread que morreu. Duas coisas que isso não é: um log de propósito geral (use
o logger existente pra isso — aqui o teto é 32 e só aparece junto de um
crash) e uma trilha de auditoria crítica pra correção (uma escrita
concorrendo com a leitura do handler de crash pode rasgar o texto de uma
entrada sob concorrência real; aceito, já que a alternativa — uma trava que a
própria thread que crashou pode já estar segurando — é exatamente o modo de
falha que este handler não pode sobreviver).

## Fazer o abort cair perto da causa

Por padrão o glibc só valida o que ele por acaso encosta, então um overflow pode
passar despercebido por minutos. O modo de checagem completa move o abort para o
`free()` que corrompeu:

```
LD_PRELOAD=libc_malloc_debug.so.0
GLIBC_TUNABLES=glibc.malloc.check=3
MALLOC_PERTURB_=165
```

> **`MALLOC_CHECK_` sozinho não faz nada em glibc 2.34+.** A checagem foi movida
> para `libc_malloc_debug.so.0`, e o tunable só é honrado quando essa biblioteca
> está no preload. Verificado: um overflow de heap deliberado passa
> despercebido sem o `LD_PRELOAD` e aborta com ele.

Isso custa throughput de verdade — é um alocador de depuração. Ligue em **uma**
instância, não na frota, e deixe até a falha reproduzir.

O `MALLOC_PERTURB_` preenche memória liberada com um padrão, o que transforma
use-after-free de "geralmente funciona" em falha determinística.

## Core dumps

O handler preserva, então vale habilitar:

```
ulimit -c unlimited
```

e montar um caminho gravável para o `/proc/sys/kernel/core_pattern`. Um core
mais o binário sem strip dá o estado completo, não só a pilha.

## Antes do crash: a linha de saúde

Um processo que só loga no startup deixa você sem como distinguir morte súbita
de deslizamento lento para saturação. O Poseidon emite, por padrão a cada
minuto:

```
[startup] backend=epoll (io_uring unavailable) io_workers=8 accept_threads=4 \
          req_pool=8..200 dispatch=worker-pool idle_timeout=10000ms \
          crash_handler=True build=a696b2d806862683f30ec60aa7179563f93340ad
[health] conns=42 inflight=3 pool=12 busy=8 idle=4 backend=epoll
```

`build` é o mesmo valor que a linha `build  :` de um crash report carrega —
impresso aqui também pra quem quer confirmar "é esse o build que está
implantado" sem precisar de um crash pra checar.

| Campo | Como ler |
|---|---|
| `backend` | Qual backend de I/O de fato subiu. O fallback io_uring → epoll é automático (perfil seccomp do container bloqueando `io_uring_setup` é o motivo usual) e antes era invisível |
| `dispatch` | `worker-pool` = handlers rodam fora da thread de I/O; `sync-inline` = nela |
| `conns` | Conexões abertas |
| `inflight` | Requisições na fila **ou** executando |
| `pool` / `busy` / `idle` | Threads do pool de requisição vivas / trabalhando / paradas |

`busy` subindo em direção a `pool` enquanto `pool` sobe em direção ao teto é a
assinatura da saturação: os handlers estão bloqueando tempo suficiente para o
pool continuar criando thread. Use `HeartbeatMs := 0` antes do `Listen()` para
silenciar a linha.

## Reproduzir falhas de memória de propósito

Dois harnesses no repositório Benchmark, ambos feitos para rodar sob a checagem
do glibc acima:

- `samples/delphi/crash-handler-test` — provoca double free, overflow de heap ou
  deref de nil de verdade, para confirmar que o handler está ligado.
- `samples/delphi/poseidon-fuzz` — o fuzzer de parsers do repo, cross-compilado
  para Linux. `FUZZ_SEED` varia o corpus entre rodadas; `FUZZ_SCALE` aprofunda.
  Sob `libc_malloc_debug` o invariante dele sobe de "nunca crashar" para "nunca
  corromper o heap".

## Veja também

- [Saúde e recuperação](saude-e-recuperacao.md)
- [Thread safety](thread-safety.md)
- [Worker threads](worker-threads.md)
