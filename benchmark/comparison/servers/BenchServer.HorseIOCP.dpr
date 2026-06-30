program BenchServer.HorseIOCP;
// Horse Latest (master) + IOCP native provider (Windows only)
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_IOCP}
uses
  System.SysUtils, Horse, Bench.HorseRoutes;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9805);
  RegisterBenchRoutes('HorseLatest+IOCP');
  THorse.Listen(LPort,
    procedure begin
      Writeln(Format('[Horse Latest + IOCP] port %d', [LPort]));
    end);
  while True do Sleep(1000);
end.
