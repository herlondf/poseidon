program BenchServer.HorseEpoll;
// Horse Latest (master) + Epoll native provider (Linux only)
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_EPOLL}
uses
  System.SysUtils, Horse, Bench.HorseRoutes;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9807);
  RegisterBenchRoutes('HorseLatest+Epoll');
  THorse.Listen(LPort,
    procedure begin
      Writeln(Format('[Horse Latest + Epoll] port %d', [LPort]));
    end);
  while True do Sleep(1000);
end.
