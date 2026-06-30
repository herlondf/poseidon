program BenchServer.HorseIndyLatest;
// Horse Latest (master) + Indy (Console provider, default)
{$APPTYPE CONSOLE}
uses
  System.SysUtils, Horse;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9804);

  THorse.Get('/ping',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      ARes.ContentType('application/json').Send('"pong"');
    end);

  THorse.Get('/json',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      ARes.ContentType('application/json').Send('{"message":"Hello, World!","framework":"HorseLatest+Indy"}');
    end);

  THorse.Post('/upload',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      ARes.ContentType('text/plain').Send('received:' + IntToStr(Length(AReq.Body)));
    end);

  THorse.Get('/delay',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      Sleep(50);
      ARes.ContentType('text/plain').Send('ok');
    end);

  Writeln(Format('[Horse Latest + Indy] port %d', [LPort]));
  THorse.Listen(LPort);
end.
