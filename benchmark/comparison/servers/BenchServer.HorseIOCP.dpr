program BenchServer.HorseIOCP;
// Horse Latest (master) + IOCP native provider (Windows only)
// Uses the exact same pattern as Horse's own benchmarks/win_comparison/HorseBench.dpr
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_IOCP}
uses
  System.SysUtils,
  Horse,
  Horse.Provider.IOCP;
begin
  try
    THorse.Get('/ping',
      procedure(Req: THorseRequest; Res: THorseResponse)
      begin
        Res.ContentType('application/json').Send('"pong"');
      end);

    THorse.Get('/json',
      procedure(Req: THorseRequest; Res: THorseResponse)
      begin
        Res.ContentType('application/json')
          .Send('{"message":"Hello, World!","framework":"HorseLatest+IOCP"}');
      end);

    THorse.Post('/upload',
      procedure(Req: THorseRequest; Res: THorseResponse)
      begin
        Res.ContentType('text/plain').Send('received:' + IntToStr(Length(Req.Body)));
      end);

    THorse.Get('/delay',
      procedure(Req: THorseRequest; Res: THorseResponse)
      begin
        Sleep(50);
        Res.ContentType('text/plain').Send('ok');
      end);

    Writeln('[Horse Latest + IOCP] port 9805');
    THorse.Listen(9805);
  except
    on E: Exception do
      Writeln(E.ClassName, ': ', E.Message);
  end;
end.
