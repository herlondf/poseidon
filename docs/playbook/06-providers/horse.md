# Horse Provider

`Horse.Provider.AsyncIO` replaces Horse's default Indy transport with AsyncIO's
IOCP/epoll engine. The application code stays exactly the same — only the define changes.

## Why use it

The default Horse/Indy provider creates **one OS thread per connection**.
At 700–800 concurrent connections: 800 threads × 8 MB stack = 6.4 GB virtual memory,
which corrupts the glibc heap on Linux → double free → crash.

AsyncIO uses IOCP/epoll: all connections share a bounded worker pool (`WorkerCount`,
default 200). Thread count is **fixed regardless of concurrent connections**.
200 workers × 8 MB = 1.6 GB — safe at any scale.

## Setup

### 1. Search path

Add both paths to your project's search path:

```
<asyncio>\src\
<asyncio>\providers\horse\
<horse>\src\
```

### 2. Define

Add `HORSE_ASYNCIO` to your project's conditional defines
(Project Options → Delphi Compiler → Conditional defines).

That's it. `Horse.pas` picks up `Horse.Provider.AsyncIO` automatically when the define is set.
No changes to application code.

### 3. Optional tuning (before `THorse.Listen`)

```pascal
THorse.WorkerCount       := 200;   // parallel processing threads (default 200)
THorse.MaxConnections    := 0;     // 0 = unlimited at TCP level
THorse.KeepConnectionAlive := True;
```

## Example

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
      Writeln('Listening on :9000');
      Readln;
      THorse.StopListen;
    end);
end.
```

See full runnable project at [`samples/05-horse-provider/`](../../../samples/05-horse-provider/).

## Compatibility

| | AsyncIO provider | Indy (default) |
|---|---|---|
| Thread model | Fixed pool (IOCP/epoll) | 1 thread per connection |
| 800 concurrent conns | ~1.6 GB RAM | ~6.4 GB RAM |
| Linux crash at high load | No | Yes (glibc heap corruption) |
| Horse middleware | Full compatibility | Full compatibility |
| SSL/TLS | Via `ConfigureSSL` on `THorse` | Via `IOHandleSSL` |
| WebSocket | `RegisterWSHandler` | Not supported |
| HTTP/2 | `HTTP2Enabled` | Not supported |
