program BenchServer.Poseidon;

// Benchmark server: Poseidon native (no Horse framework).
// Endpoints: /ping, /json, /upload, /delay
// Port: 9801 (configurable via BENCH_PORT env var)

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Poseidon.Net.HttpServer,
  Poseidon.Net.Types,
  Bench.Handlers;

var
  LServer: TPoseidonNativeServer;
  LPort:   Integer;
  LReady:  TEvent;
begin
  LPort  := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9801);
  LReady := TEvent.Create(nil, True, False, '');

  LServer := TPoseidonNativeServer.Create;
  try
    // Listen blocks on IO event loop — launch in a thread
    TThread.CreateAnonymousThread(
      procedure
      begin
        LServer.Listen('0.0.0.0', LPort, PoseidonHandler,
          procedure
          begin
            Writeln(Format('[Poseidon Native] listening on port %d', [LPort]));
            LReady.SetEvent;
          end);
      end).Start;

    LReady.WaitFor(5000);
    Writeln('Running... kill process to stop.');
    // Block until killed (Ctrl+C or SIGTERM)
    while True do Sleep(1000);
  finally
    LServer.Stop;
    LServer.Free;
    LReady.Free;
  end;
end.
