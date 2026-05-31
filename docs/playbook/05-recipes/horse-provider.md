# Horse provider

Poseidon can serve as the HTTP transport layer for the
[Horse](https://github.com/HashLoad/horse) framework via `Horse.Provider.Poseidon`.

## Setup

Add to your search path:

```
<poseidon>\src\
<poseidon>\providers\horse\
<horse>\src\
```

Add `{$DEFINE HORSE_ASYNCIO}` to your project options (or at the top of the DPR).

## Usage

```pascal
program MyHorseApp;

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
      Writeln('Running on :9000');
      Readln;
      THorse.StopListen;
    end, nil);
end.
```

## Configuration

Horse exposes Poseidon properties via `THorse.*`:

```pascal
THorse.WorkerCount := 50;           // worker threads
// All other TPoseidonNativeServer properties are accessible through
// THorse.GetProvider<TPoseidonNativeServer>
```

## Notes

- `{$DEFINE HORSE_ASYNCIO}` must be active **before** any Horse unit is compiled.
- Without the define, Horse falls back to its default (Indy) provider — Poseidon is not loaded.
- Requires Horse ≥ 3.1.9.

See full project at [`samples/05-horse-provider/`](../../../samples/05-horse-provider/).
