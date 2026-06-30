program BenchServer.HorsePoseidonLatest;
// Horse Latest (master) + Poseidon provider
{$APPTYPE CONSOLE}
{$DEFINE HORSE_ASYNCIO}
uses
  System.SysUtils, Horse, Bench.HorseRoutes;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9808);
  RegisterBenchRoutes('HorseLatest+Poseidon');
  THorse.Listen(LPort,
    procedure begin
      Writeln(Format('[Horse Latest + Poseidon] port %d', [LPort]));
    end);
  while True do Sleep(1000);
end.
