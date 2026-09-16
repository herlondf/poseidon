# Métricas Prometheus

O Poseidon expõe métricas do servidor no
[formato exposition Prometheus](https://prometheus.io/docs/instrumenting/exposition_formats/) 0.0.4
através do `MetricsMiddleware`, um middleware comum (não uma property de
`TPoseidonNativeServer`) — veja [middlewares #10](../09-middlewares/README.md#10-metrics)
pro lado de contagem de requisições/erros/histograma.

> **Correção 16/09/2026:** esta página costumava documentar uma API
> server-native `LServer.MetricsEnabled` / `LServer.Metrics.IncrementCounter`.
> Essa API não existe na árvore de código atual (confirmado por busca em todo
> o repo) — a única implementação é o middleware descrito abaixo. Se você tem
> código escrito contra a API antiga, ela nunca funcionou de fato; migre para
> `MetricsMiddleware`.

## Habilitando o endpoint

```pascal
uses Poseidon.Middleware.Metrics;

App.Use(MetricsMiddleware('/metrics'));  // '/metrics' também é o padrão
```

## Scraping

```
GET /metrics
```

Retorna uma resposta texto (`Content-Type: text/plain; version=0.0.4`) com
todas as métricas expostas. O intervalo padrão de scraping Prometheus é de
15-60 s.

## Métricas por caminho

`poseidon_requests_total`, `poseidon_errors_total` (status >= 400) e o
histograma `poseidon_request_duration_ms`, todos rotulados por `path`. Veja
[middlewares #10](../09-middlewares/README.md#10-metrics) pros limites do
histograma e o teto de cardinalidade de caminhos.

## Gauges no nível do processo

Adicionados em 16/09/2026, junto com o [diagnóstico de heap](../../../src/Poseidon.Diagnostics.pas)
que veio de uma investigação de crescimento de memória em produção num deploy
downstream. Um valor por processo, sem label `path` — diferente de tudo mais
que este endpoint expõe:

| Métrica | Fonte | Significado |
|---|---|---|
| `poseidon_rss_kb` | `TPoseidonDiagnostics.RSSKB` | Tamanho do resident set. Inclui páginas de biblioteca compartilhada contadas de novo em cada outro processo que as mapeia. |
| `poseidon_malloc_inuse_kb` | `MallocInfo` (mallinfo2 `uordblks`) | Bytes que o glibc reporta que a aplicação ainda segura vivos. Só Linux, `-1` no Windows. |
| `poseidon_malloc_arena_kb` | `MallocInfo` (mallinfo2 `arena`) | Footprint do heap não-mmap, obtido via sbrk do SO — inclui espaço liberado mas ainda retido. Só Linux. |
| `poseidon_malloc_mmap_kb` | `MallocInfo` (mallinfo2 `hblkhd`) | Alocações grandes via mmap, devolvidas ao SO na hora do free. Só Linux. |
| `poseidon_delphi_heap_kb` | `DelphiHeapInUseKB` (`GetMemoryManagerState`) | Memory manager do próprio Delphi, bytes em uso. Só Windows/OSX, `-1` no Linux (lá, `SysGetMem` já chama `malloc` direto — `poseidon_malloc_inuse_kb` já cobre esse caso por completo). |
| `poseidon_fd_count` | `OpenFDCount` (contagem de `/proc/self/fd`) | Descritores de arquivo abertos. Só Linux. |
| `poseidon_private_dirty_kb` | `PrivateDirtyKB` (`/proc/self/smaps_rollup`) | Memória que só esta instância escreveu e segura, sem páginas de biblioteca compartilhada — mais preciso que `poseidon_rss_kb` pra "quanto a saída desta instância realmente liberaria". Só Linux. |

**Lendo em conjunto, a pergunta que cada par responde:**

- `poseidon_malloc_inuse_kb` parado enquanto `poseidon_rss_kb` sobe → o
  allocator está retendo memória liberada mas não devolvida (fragmentação),
  não vazamento. Olhe o ajuste de `MALLOC_TRIM_THRESHOLD_`/
  `MALLOC_MMAP_THRESHOLD_` do glibc antes de supor vazamento no código.
- `poseidon_malloc_inuse_kb` subindo também → vazamento real em código
  nativo/C (sockets, OpenSSL, zlib, libcurl, ou qualquer outra coisa chamando
  `malloc` direto) — não em objetos gerenciados pelo Delphi.
- `poseidon_delphi_heap_kb` subindo no Windows enquanto `poseidon_malloc_inuse_kb`
  fica parado → o vazamento é no nível Delphi (objeto/string/interface não
  liberado) — essa separação não se aplica no Linux (veja a tabela acima).
- `poseidon_fd_count` subindo junto com `poseidon_rss_kb` → provavelmente
  "algo não sendo fechado" (conexão, stream, handle), não uma questão pura de
  allocator — um socket/stream vazado quase sempre carrega buffer junto.

Mesmo padrão de linha de log do `[health]` (veja o heartbeat periódico do
servidor) — esses gauges são os mesmos números, só que numa forma
"scrapeável" em vez de uma linha de log texto.

## Forçando uma tentativa de trim do heap

Se `poseidon_malloc_arena_kb - poseidon_malloc_inuse_kb` (heap retido mas não
usado) cresceu bastante, `TPoseidonDiagnostics.TryMallocTrim` (só Linux) força
o glibc a tentar devolver esse espaço ao SO agora, em vez de esperar seu
próprio limite de trim ser cruzado sozinho:

```pascal
if TPoseidonDiagnostics.TryMallocTrim then
  // devolveu algo ao SO
else
  // nada pra devolver agora
```

Isso é uma ferramenta de diagnóstico/operação, não um fix — se a diferença
volta a crescer logo depois de um trim bem-sucedido, é retenção/fragmentação
recorrente, não algo pra mascarar chamando isso num timer. Em vez disso ajuste
`MALLOC_TRIM_THRESHOLD_`/`MALLOC_MMAP_THRESHOLD_` (veja os comentários do
Dockerfile num deploy que já ajustou isso, se existir na sua stack) pra que o
kernel receba a memória de volta sozinho.

O Poseidon não instala um signal handler pra isso por conta própria —
seguindo o mesmo padrão do [graceful reload](../05-receitas/graceful-reload.md)
(`SIGUSR2` é nível de aplicação, não forçado pela lib), conecte a um sinal
livre no seu próprio `.dpr` se quiser um trim disparável pelo operador sem
reiniciar:

```pascal
{$IFNDEF MSWINDOWS}
uses Posix.Signal;

procedure TrimSignalHandler(ASigNum: Integer); cdecl;
begin
  // Seguro em signal handler: o unico efeito colateral do TryMallocTrim
  // aqui e a propria chamada libc. Loga o resultado na proxima linha
  // [health] em vez de logar inline, mesmo raciocinio que o
  // InstallCrashHandler documenta pra explicar por que _CrashHandler evita
  // alocar tipos string a partir de contexto de sinal.
  TPoseidonDiagnostics.TryMallocTrim;
end;

// no startup, junto com InstallCrashHandler:
signal(SIGUSR1, @TrimSignalHandler);
{$ENDIF}
```

Depois `kill -USR1 <pid>` dispara uma tentativa de trim sob demanda.

## Observações

- As métricas são atualizadas atomicamente; o endpoint `/metrics` é seguro para scraping concorrente.
- O endpoint é servido pelo mesmo pool de workers que as requisições regulares.
- Não exponha `/metrics` em uma porta pública sem uma ACL de reverse-proxy ou
  restrição em nível de rede (não há allowlist de CIDR embutida no middleware
  atual, ao contrário do que uma versão anterior desta página afirmava).
