---
name: poseidon-server-review
description: Revisão focada da camada de servidor e ciclo de vida do Poseidon — orquestração start/stop (Poseidon.Net.HttpServer), API fluente nativa (Poseidon.Native.Server), grupos de rotas (Poseidon.Native.Group), graceful reload (Poseidon.GracefulReload) e a fachada de seleção de backend de I/O (Poseidon.Net.IO). Use ao auditar Listen/Stop/Destroy, teardown sob carga, composição de rotas/middlewares/grupos, troca de handler/config em voo e a fronteira camada fluente ↔ dispatcher. Segue a Regra de Ouro de poseidon-review (só reporte o que provar).
---

# Revisão da camada de servidor do Poseidon

Escopo: `Poseidon.Net.HttpServer.pas`, `Poseidon.Native.Server.pas`,
`Poseidon.Native.Group.pas`, `Poseidon.GracefulReload.pas`, `Poseidon.Net.IO.pas`.
Aplique a Regra de Ouro de `poseidon-review`: só reporte o que puder PROVAR
(cenário concreto + linha exata). Marque a plataforma afetada — `HttpServer`
seleciona o backend por `{$IFDEF}` (IOCP/RIO no Windows, epoll/io_uring no Linux),
então um bug de start/stop pode existir só em uma delas.

## O que caçar

### Ciclo de vida (Listen / Stop / Destroy)
- `Listen` idempotente? Chamar duas vezes vaza socket/thread ou levanta?
- `Stop` seguido de `Destroy`: ordem de liberação. O backend de I/O é parado
  ANTES de liberar pools/managers que suas threads ainda tocam? Um worker em voo
  acessando `FServer`/pool já liberado é use-after-free (CRITICAL).
- `Destroy` sem `Listen` prévio (construído e liberado): nenhum `nil` deref.
- Sinalização de parada: evento/flag lido pelas IO-threads com barreira de
  memória adequada (não um `Boolean` cru sem `TInterlocked`/volatile semantics).
- Drain gracioso (R-1): requisições em voo terminam antes do socket fechar?
  Novas conexões são recusadas durante o drain?

### API fluente (Native.Server)
- `Get/Post/Put/Delete/Use`: registro de rota/middleware é permitido APÓS
  `Listen`? Se sim, a estrutura de rotas é thread-safe contra as IO-threads
  que fazem `Lookup` (ver Router). Registro concorrente com serving → corrida.
- `TNativeMiddlewareEntry` guarda `MethodPtr` OU `FuncPtr` conforme `IsFunc`:
  confirme que a chamada respeita o discriminador (chamar o ponteiro errado é
  call em `nil`/lixo).
- Captura de variáveis em closures de handler/middleware: `reference to` captura
  por referência — variável de loop capturada compartilhada é bug clássico.
- Propriedades de segurança/limite (`MaxRequestSize`, `MaxQueueDepth`,
  `AllowedMethods`, `SecureHeaders`, `ServerBanner`, `RateLimit`): lidas pelo
  dispatcher a cada request — set após `Listen` cria corrida de leitura/escrita.

### Grupos (Native.Group)
- Composição de prefixo: concatenação de path evita `//` duplo e prefixo sem `/`.
- Middlewares do grupo aplicados na ordem certa e SÓ às rotas do grupo.
- `TNativeGroupBlock` (bloco anônimo): o grupo é liberado/estável durante o
  registro? Ponteiro para o servidor pai não dangla.

### Graceful reload
- Troca de handler/config sob carga: publicação atômica do novo conjunto de
  rotas. Uma IO-thread lendo o ponteiro antigo enquanto o novo é instalado —
  o antigo continua válido até o último leitor terminar? (RCU/refcount ou lock).
  Sem isso: use-after-free ou rota parcialmente instalada servida.
- Recarga não deve derrubar conexões keep-alive existentes sem necessidade.

### Fachada de I/O (Net.IO)
- Seleção de backend por `{$IFDEF}`: cada plataforma resolve para uma unit real
  existente; não deixar um branch referenciando símbolo inexistente na outra.
- Tipo de retorno/registro consistente entre backends (a fronteira comum não
  pode assumir um campo que só um backend preenche).

## Não reporte sem provar
Uma "corrida no shutdown" só é bug se você apontar as duas threads, a ordem de
acesso e o campo compartilhado tocado após liberação. Um "vazamento no Stop" só
conta se houver um caminho em que o recurso alocado não é liberado — mostre-o.
