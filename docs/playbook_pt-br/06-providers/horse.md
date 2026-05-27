# Provider Horse

`Horse.Provider.Poseidon` substitui o transporte padrão Indy do Horse pelo engine
IOCP/epoll do Poseidon. O código da aplicação permanece idêntico — só o define muda.

## Por que usar

O provider padrão Horse/Indy cria **uma thread do SO por conexão**.
Com 700–800 conexões simultâneas: 800 threads × 8 MB de stack = 6,4 GB de memória virtual,
o que corrompe o heap do glibc no Linux → double free → crash do processo.

O Poseidon usa IOCP/epoll: todas as conexões compartilham um pool fixo de workers
(`WorkerCount`, padrão 200). O número de threads é **fixo, independente das conexões**.
200 workers × 8 MB = 1,6 GB — seguro em qualquer escala.

## Configuração

### 1. Search path

Adicione os dois caminhos ao search path do projeto:

```
<asyncio>\src\
<asyncio>\providers\horse\
<horse>\src\
```

### 2. Define

Adicione `HORSE_ASYNCIO` nos defines condicionais do projeto
(Opções do Projeto → Delphi Compiler → Conditional defines).

Pronto. O `Horse.pas` seleciona `Horse.Provider.Poseidon` automaticamente quando o define está ativo.
Nenhuma alteração no código da aplicação.

### 3. Ajuste opcional (antes de `THorse.Listen`)

```pascal
THorse.WorkerCount       := 200;   // threads de processamento paralelo (padrão 200)
THorse.MaxConnections    := 0;     // 0 = ilimitado no nível TCP
THorse.KeepConnectionAlive := True;
```

## Exemplo

```pascal
{$APPTYPE CONSOLE}
{$DEFINE HORSE_ASYNCIO}

uses
  Horse,
  Horse.Jhonson;

begin
  THorse.WorkerCount := 200;
  THorse.Use(Jhonson);

  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse; Next: TProc)
    begin
      Res.Send('{"message":"pong"}');
    end);

  THorse.Listen(9000,
    procedure begin
      Writeln('Ouvindo em :9000');
      Readln;
      THorse.StopListen;
    end);
end.
```

Veja o projeto executável completo em [`samples/05-horse-provider/`](../../../samples/05-horse-provider/).

## Compatibilidade

| | Provider Poseidon | Indy (padrão) |
|---|---|---|
| Modelo de threads | Pool fixo (IOCP/epoll) | 1 thread por conexão |
| 800 conexões simultâneas | ~1,6 GB RAM | ~6,4 GB RAM |
| Crash sob alta carga no Linux | Não | Sim (corrupção heap glibc) |
| Middlewares Horse | Compatibilidade total | Compatibilidade total |
| SSL/TLS | Via `ConfigureSSL` no `THorse` | Via `IOHandleSSL` |
| WebSocket | `RegisterWSHandler` | Não suportado |
| HTTP/2 | `HTTP2Enabled` | Não suportado |
