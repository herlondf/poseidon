program BenchServer.HorseIndy320;
// Horse 3.2.0 + Indy (Console provider, default)
{$APPTYPE CONSOLE}
uses
  System.SysUtils, Horse, Bench.HorseRoutes;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9802);
  RegisterBenchRoutes('Horse3.2.0+Indy');
  THorse.Listen(LPort,
    procedure begin
      Writeln(Format('[Horse 3.2.0 + Indy] port %d', [LPort]));
    end);
  while True do Sleep(1000);
end.
