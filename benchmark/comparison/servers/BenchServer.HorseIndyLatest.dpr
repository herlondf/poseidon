program BenchServer.HorseIndyLatest;
// Horse Latest (master) + Indy (Console provider, default)
{$APPTYPE CONSOLE}
uses
  System.SysUtils, Horse, Bench.HorseRoutes;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9804);
  RegisterBenchRoutes('HorseLatest+Indy');
  THorse.Listen(LPort,
    procedure begin
      Writeln(Format('[Horse Latest + Indy] port %d', [LPort]));
    end);
  while True do Sleep(1000);
end.
