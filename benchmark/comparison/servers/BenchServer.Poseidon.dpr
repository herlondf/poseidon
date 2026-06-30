program BenchServer.Poseidon;

// Benchmark server: Poseidon native (no Horse framework).
// Endpoints: /ping, /json, /upload, /delay
// Port: 9801 (configurable via BENCH_PORT env var)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Net.HttpServer,
  Poseidon.Net.Types,
  Bench.Handlers;

var
  LServer: TPoseidonNativeServer;
  LPort:   Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9801);

  LServer := TPoseidonNativeServer.Create;
  try
    LServer.Listen('0.0.0.0', LPort, PoseidonHandler,
      procedure
      begin
        Writeln(Format('[Poseidon Native] listening on port %d', [LPort]));
        Writeln('Press Enter to stop...');
      end);
    Readln;
    LServer.Stop;
  finally
    LServer.Free;
  end;
end.
