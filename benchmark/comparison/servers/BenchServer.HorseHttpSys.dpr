program BenchServer.HorseHttpSys;
// Horse Latest (master) + HttpSys kernel provider (Windows only)
{$APPTYPE CONSOLE}
{$DEFINE HORSE_PROVIDER_HTTPSYS}
uses
  System.SysUtils, Horse, Bench.HorseRoutes;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9806);
  RegisterBenchRoutes('HorseLatest+HttpSys');
  THorse.Listen(LPort,
    procedure begin
      Writeln(Format('[Horse Latest + HttpSys] port %d', [LPort]));
    end);
  while True do Sleep(1000);
end.
