program BenchServer.HorsePoseidon320;
// Horse 3.2.0 + Poseidon provider
{$APPTYPE CONSOLE}
{$DEFINE HORSE_ASYNCIO}
uses
  System.SysUtils, Horse, Bench.HorseRoutes;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9803);
  RegisterBenchRoutes('Horse3.2.0+Poseidon');
  THorse.Listen(LPort,
    procedure begin
      Writeln(Format('[Horse 3.2.0 + Poseidon] port %d', [LPort]));
    end);
  while True do Sleep(1000);
end.
