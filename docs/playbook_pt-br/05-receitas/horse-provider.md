# Provider Horse

O Poseidon pode ser usado como camada de transporte HTTP do framework
[Horse](https://github.com/HashLoad/horse) via `Horse.Provider.Poseidon`.

## Configuração

Adicione ao search path:

```
<poseidon>\src\
<poseidon>\providers\horse\
<horse>\src\
```

Adicione `{$DEFINE HORSE_ASYNCIO}` às opções do projeto (ou no início do DPR).

## Uso

```pascal
program MinhaAppHorse;

{$APPTYPE CONSOLE}
{$DEFINE HORSE_ASYNCIO}

uses
  Horse;

begin
  THorse.Get('/ping',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.Send('{"message":"pong"}');
    end);

  THorse.Listen(9000,
    procedure
    begin
      Writeln('Rodando em :9000');
      Readln;
      THorse.StopListen;
    end, nil);
end.
```

## Configuração

O Horse expõe propriedades do Poseidon via `THorse.*`:

```pascal
THorse.WorkerCount := 50;           // worker threads
// Outras propriedades de TPoseidonNativeServer são acessíveis via
// THorse.GetProvider<TPoseidonNativeServer>
```

## Observações

- `{$DEFINE HORSE_ASYNCIO}` deve estar ativo **antes** de qualquer unit do Horse ser compilada.
- Sem o define, o Horse usa seu provider padrão (Indy) — o Poseidon não é carregado.
- Requer Horse ≥ 3.1.9.

Veja o projeto completo em [`samples/05-horse-provider/`](../../../samples/05-horse-provider/).
