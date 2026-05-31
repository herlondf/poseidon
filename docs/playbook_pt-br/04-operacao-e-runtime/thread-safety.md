# Thread safety

## Modelo de threading do handler

Cada requisição recebida é despachada para uma worker thread do pool.
O callback do handler é sempre chamado de uma **worker thread**, nunca da thread
principal ou da thread de conclusão de I/O.

```pascal
// Este handler pode ser chamado concorrentemente por múltiplas worker threads
procedure HandleRequest(
  const AReq: TPoseidonNativeRequest; ...);
begin
  // SEGURO: leitura dos campos de AReq (imutáveis durante esta chamada)
  // NÃO SEGURO sem lock: acesso a variáveis de módulo compartilhadas entre requisições
end;
```

## O que é seguro

| Operação | Seguro? | Observações |
|----------|---------|-------------|
| Leitura dos campos de `AReq` | ✅ | Imutável por chamada |
| Escrita em `AStatus`, `ABody`, `AContentType`, `AExtraHeaders` | ✅ | Parâmetros de saída por chamada |
| Leitura de propriedades de `LServer` | ✅ | Propriedades são somente leitura após `Listen` |
| Acesso a conexão de banco por requisição | ✅ | Se cada requisição cria a sua |
| Acesso a `TDictionary` global | ❌ | Proteger com `TMonitor` ou `TCriticalSection` |
| Acesso a `TStringList` compartilhado | ❌ | Não é thread-safe |

## Protegendo estado compartilhado

```pascal
var
  GLock: TCriticalSection;
  GContador: Integer;

procedure HandleRequest(...);
begin
  GLock.Enter;
  try
    Inc(GContador);
  finally
    GLock.Leave;
  end;
  // ...
end;
```

Para contadores inteiros simples, prefira `TInterlocked`:

```pascal
TInterlocked.Increment(GContador);
```

## Separação de thread de I/O

A thread de conclusão de I/O (IOCP/epoll) é separada do pool de workers.
Ela chama callbacks internos de `OnRecv`/`OnSend`, mas nunca invoca o handler
da aplicação. Os únicos objetos compartilhados entre a thread de I/O e os workers
são os objetos de conexão `TNativeConn`, que são ref-counted para controle seguro
do tempo de vida entre threads.

## Handlers WebSocket

Handlers WebSocket (`RegisterWSHandler`) seguem as mesmas regras — chamados de
uma worker thread, um de cada vez por conexão, mas múltiplas conexões são concorrentes.

## Observações

- `WorkerCount` (padrão 200) controla o nível de concorrência. Projete estado
  compartilhado para suportar até `WorkerCount` escritores concorrentes.
- Para locking de granularidade grossa, `TMonitor` (embutido em todo objeto Delphi)
  é conveniente, mas tem overhead maior que um `TCriticalSection` dedicado.
