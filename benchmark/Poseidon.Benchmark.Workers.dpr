program Poseidon.Benchmark.Workers;

{$APPTYPE CONSOLE}

// Workers scaling matrix benchmark.
//
// Answers: "how many workers do I need for an API with ~Xms DB queries?"
//
// Matrix (30 combinations):
//   Workers: 4, auto (~8), 8, 16, 32
//   DAO Latency: 5ms (fast), 30ms (medium), 100ms (slow)
//   Concurrency: 10, 50 clients
//
// Theoretical max RPS = Workers * (1000 / LatencyMs).
// Report shows actual RPS as % of theoretical max.
//
// Generates: benchmark\bin\poseidon-bench-workers-dao<N>ms.html

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  Bench.Types,
  Bench.Adapter,
  Bench.Adapter.Poseidon,
  Bench.FakeDAO,
  Bench.Scenarios,
  Bench.Report;

const
  BASE_PORT = 19994;  // workers matrix uses ports 19994..19997

type
  TWorkerConfig = record
    Workers:    Integer;  // 0 = auto
    Label_:     string;
  end;

  TLatencyConfig = record
    Ms:    Integer;
    Label_: string;
  end;

procedure RunWorkerMatrix;
var
  LWorkerConfigs:  array[0..4] of TWorkerConfig;
  LLatencyConfigs: array[0..2] of TLatencyConfig;
  LConcurrencies:  array[0..1] of Integer;
  LWI, LLI, LCI:  Integer;
  LPort:           Integer;
  LAdapters:       array[0..4] of IBenchAdapter;  // one per worker config
  LRunner:         TBenchRunner;
  LReport:         TBenchReport;
  LScenarios:      TArray<TBenchScenarioDef>;
  LOutFile:        string;
  LMachine:        string;
begin
  LWorkerConfigs[0].Workers := 4;      LWorkerConfigs[0].Label_ := 'W=4';
  LWorkerConfigs[1].Workers := 0;      LWorkerConfigs[1].Label_ := 'W=auto';
  LWorkerConfigs[2].Workers := 8;      LWorkerConfigs[2].Label_ := 'W=8';
  LWorkerConfigs[3].Workers := 16;     LWorkerConfigs[3].Label_ := 'W=16';
  LWorkerConfigs[4].Workers := 32;     LWorkerConfigs[4].Label_ := 'W=32';

  LLatencyConfigs[0].Ms := DAO_LATENCY_FAST;   LLatencyConfigs[0].Label_ := 'DAO=5ms';
  LLatencyConfigs[1].Ms := DAO_LATENCY_MEDIUM; LLatencyConfigs[1].Label_ := 'DAO=30ms';
  LLatencyConfigs[2].Ms := DAO_LATENCY_SLOW;   LLatencyConfigs[2].Label_ := 'DAO=100ms';

  LConcurrencies[0] := 10;
  LConcurrencies[1] := 50;

  LMachine := GetEnvironmentVariable('COMPUTERNAME');
  if LMachine = '' then LMachine := 'localhost';

  LPort := BASE_PORT;
  WriteLn('=== Poseidon Workers Scaling Benchmark ===');
  WriteLn;

  // For each DAO latency, run all worker counts at all concurrency levels
  for LLI := 0 to 2 do
  begin
    WriteLn(Format('--- DAO latency: %dms ---', [LLatencyConfigs[LLI].Ms]));

    // Spin up one server per worker config
    for LWI := 0 to 4 do
    begin
      LAdapters[LWI] := TBenchAdapterConfigurable.Create(
        LWorkerConfigs[LWI].Label_ + ' / ' + LLatencyConfigs[LLI].Label_,
        LPort + LWI,
        LWorkerConfigs[LWI].Workers,
        LLatencyConfigs[LLI].Ms
      );
      if LWorkerConfigs[LWI].Workers = 0 then
        WriteLn(Format('  %s → port %d (auto)', [LWorkerConfigs[LWI].Label_, LPort + LWI]))
      else
        WriteLn(Format('  %s → port %d', [LWorkerConfigs[LWI].Label_, LPort + LWI]));
    end;
    WriteLn;

    // Build scenarios: GET /users/1 at each concurrency level
    SetLength(LScenarios, Length(LConcurrencies));
    for LCI := 0 to High(LConcurrencies) do
    begin
      LScenarios[LCI] := TBenchScenarioDef.Make(
        Format('GET /users/1 — %d clients', [LConcurrencies[LCI]]),
        Format('Simulates %d concurrent clients hitting FindByID (%dms DAO). ' +
          'Theoretical max: Workers×%drps',
          [LConcurrencies[LCI], LLatencyConfigs[LLI].Ms,
           1000 div Max(1, LLatencyConfigs[LLI].Ms)]),
        '/users/1', 'GET',
        LConcurrencies[LCI] * 20,  // total requests
        LConcurrencies[LCI],        // threads
        5,                          // warmup
        '',                         // body
        LLatencyConfigs[LLI].Ms     // DAOLatencyMs — must match adapter config
      );
    end;

    // Run
    LRunner := TBenchRunner.Create('',
      procedure(const AMsg: string) begin WriteLn(AMsg); end);
    try
      for LWI := 0 to 4 do
        LRunner.AddAdapter(LAdapters[LWI]);
      for LCI := 0 to High(LConcurrencies) do
        LRunner.AddScenario(LScenarios[LCI]);
      LRunner.Run;
      WriteLn;

      // Partial report per latency
      LOutFile := ExtractFilePath(ParamStr(0)) +
        Format('poseidon-bench-workers-dao%dms.html', [LLatencyConfigs[LLI].Ms]);
      LReport := TBenchReport.Create(
        LRunner.Results,
        LMachine,
        Now,
        Format('Poseidon Workers Scaling — DAO %dms', [LLatencyConfigs[LLI].Ms])
      );
      try
        LReport.SaveToFile(LOutFile);
        WriteLn('Report: ' + LOutFile);
      finally
        LReport.Free;
      end;
    finally
      LRunner.Free;
    end;

    // Clean up adapters (servers) for this latency batch
    for LWI := 0 to 4 do
      LAdapters[LWI] := nil;
    LPort := LPort + 5;
    WriteLn;
  end;

  WriteLn('Done.');
end;

begin
  try
    RunWorkerMatrix;
  except
    on E: Exception do
    begin
      WriteLn('ERROR: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
