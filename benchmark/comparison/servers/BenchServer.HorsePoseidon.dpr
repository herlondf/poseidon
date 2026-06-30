program BenchServer.HorsePoseidon;

// Benchmark server: Horse + Poseidon provider (async IOCP/epoll).
// Endpoints: /ping, /json, /upload, /delay
// Port: 9803 (configurable via BENCH_PORT env var)

{$APPTYPE CONSOLE}
{$DEFINE HORSE_ASYNCIO}

uses
  System.SysUtils,
  Horse;

const
  JSON_RESPONSE = '{"message":"Hello, World!","framework":"Horse+Poseidon"}';

var
  LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9803);

  THorse.Get('/ping',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.ContentType('application/json').Send('"pong"');
    end);

  THorse.Get('/json',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.ContentType('application/json').Send(JSON_RESPONSE);
    end);

  THorse.Post('/upload',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.ContentType('text/plain')
        .Send('received:' + IntToStr(Length(AReq.Body)));
    end);

  THorse.Get('/delay',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      Sleep(50);
      ARes.ContentType('text/plain').Send('ok');
    end);

  THorse.Listen(LPort,
    procedure
    begin
      Writeln(Format('[Horse+Poseidon] listening on port %d', [LPort]));
      Writeln('Running... kill process to stop.');
    end);

  // THorse.Listen returns after callback — keep process alive until killed
  while True do Sleep(1000);
end.
