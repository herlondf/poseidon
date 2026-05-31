unit Bench.Scenarios;

// Definição e execução dos cenários de benchmark.
// Cada cenário roda para todos os adaptadores (configurações) registrados.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Diagnostics,
  System.Generics.Collections,
  System.Threading,
  Bench.Types,
  Bench.Adapter;

type
  TProgressProc = reference to procedure(const AMsg: string);

  TBenchRunner = class
  private
    FAdapters:  TList<IBenchAdapter>;
    FScenarios: TList<TBenchScenarioDef>;
    FResults:   TObjectList<TBenchMetrics>;
    FBaseURL:   string;
    FProgress:  TProgressProc;

    procedure RunScenario(
      const ADef:     TBenchScenarioDef;
      const AAdapter: IBenchAdapter
    );
    procedure RunConcurrent(
      const ADef:     TBenchScenarioDef;
      const AAdapter: IBenchAdapter;
      const AMetrics: TBenchMetrics
    );
    procedure RunSequential(
      const ADef:     TBenchScenarioDef;
      const AAdapter: IBenchAdapter;
      const AMetrics: TBenchMetrics
    );
    procedure Log(const AMsg: string);
  public
    // ABaseURL é ignorado — cada adaptador Poseidon controla sua própria URL.
    constructor Create(const ABaseURL: string = ''; const AProgress: TProgressProc = nil);
    destructor  Destroy; override;

    procedure AddAdapter(const AAdapter: IBenchAdapter);
    procedure AddScenario(const ADef: TBenchScenarioDef);
    procedure LoadDefaultScenarios;
    procedure Run;
    function  Results: TObjectList<TBenchMetrics>;

    class function DefaultScenarios: TArray<TBenchScenarioDef>;
  end;

implementation

uses
  System.Math;

{ TBenchRunner }

constructor TBenchRunner.Create(const ABaseURL: string; const AProgress: TProgressProc);
begin
  inherited Create;
  FBaseURL   := ABaseURL;
  FProgress  := AProgress;
  FAdapters  := TList<IBenchAdapter>.Create;
  FScenarios := TList<TBenchScenarioDef>.Create;
  FResults   := TObjectList<TBenchMetrics>.Create(True);
end;

destructor TBenchRunner.Destroy;
begin
  FAdapters.Free;
  FScenarios.Free;
  FResults.Free;
  inherited;
end;

procedure TBenchRunner.Log(const AMsg: string);
begin
  if Assigned(FProgress) then FProgress(AMsg);
end;

procedure TBenchRunner.AddAdapter(const AAdapter: IBenchAdapter);
begin
  FAdapters.Add(AAdapter);
end;

procedure TBenchRunner.AddScenario(const ADef: TBenchScenarioDef);
begin
  FScenarios.Add(ADef);
end;

class function TBenchRunner.DefaultScenarios: TArray<TBenchScenarioDef>;
begin
  Result := [
    // ---- Payload size matrix ----
    TBenchScenarioDef.Make(
      'Payload: Tiny (28 B)',
      'GET /ping → {"ok":true} — 28 bytes. Latência mínima do servidor.',
      '/ping', 'GET', 500, 1, 10),

    TBenchScenarioDef.Make(
      'Payload: Small (256 B)',
      'POST /echo com 200 bytes de JSON. Overhead de parse + copy.',
      '/echo', 'POST', 300, 1, 5,
      '{"action":"bench","payload":"' + StringOfChar('x', 200) + '"}'),

    TBenchScenarioDef.Make(
      'Payload: Medium (~1 KB)',
      'GET /medium → ~1KB de JSON com 10 items.',
      '/medium', 'GET', 300, 1, 5),

    TBenchScenarioDef.Make(
      'Payload: Large (~50 KB)',
      'GET /large → ~50KB de JSON. Throughput de respostas grandes.',
      '/large', 'GET', 100, 1, 3),

    TBenchScenarioDef.Make(
      'Payload: XLarge (~512 KB)',
      'GET /xlarge → ~512KB de JSON. Estresse de buffers grandes.',
      '/xlarge', 'GET', 30, 1, 2),

    TBenchScenarioDef.Make(
      'Payload: Large Upload (256 KB)',
      'POST /echo com 256KB de body. Throughput de upload.',
      '/echo', 'POST', 50, 1, 2,
      StringOfChar('x', 256 * 1024)),

    // ---- Concurrency matrix ----
    TBenchScenarioDef.Make(
      'Concurrent 10 threads',
      '10 threads simultâneas × 50 requests = 500 total. Escalabilidade básica.',
      '/ping', 'GET', 500, 10, 10),

    TBenchScenarioDef.Make(
      'Concurrent 50 threads',
      '50 threads simultâneas × 20 requests = 1000 total. Alta concorrência.',
      '/ping', 'GET', 1000, 50, 0),

    TBenchScenarioDef.Make(
      'Concurrent Large (20 threads)',
      '20 threads × 5 requests de 50KB. Estresse de download paralelo.',
      '/large', 'GET', 100, 20, 0),

    // ---- FakeDAO (blocking I/O simulation) ----
    TBenchScenarioDef.Make(
      'FakeDAO: GET /users/1 (fast, 5ms)',
      'Simula SELECT por PK com 5ms de latência. Workers bloqueados.',
      '/users/1', 'GET', 50, 1, 3),

    TBenchScenarioDef.Make(
      'FakeDAO: GET /users (list, fast)',
      'Simula SELECT paginado com 10ms de latência (2×fast).',
      '/users?page=1&pageSize=20', 'GET', 30, 1, 2),

    // ---- Mixed / realistic workload ----
    TBenchScenarioDef.Make(
      'Mixed Load (10 threads)',
      '10 threads concorrentes em /ping. Workload realista multi-cliente.',
      '/ping', 'GET', 700, 10, 5)
  ];
end;

procedure TBenchRunner.LoadDefaultScenarios;
var
  LS: TBenchScenarioDef;
begin
  for LS in DefaultScenarios do
    FScenarios.Add(LS);
end;

procedure TBenchRunner.Run;
var
  LDef:     TBenchScenarioDef;
  LAdapter: IBenchAdapter;
begin
  for LDef in FScenarios do
  begin
    Log(Format('── Cenário: %s ──', [LDef.Name]));
    for LAdapter in FAdapters do
    begin
      Log(Format('   [%s] iniciando...', [LAdapter.Name]));
      RunScenario(LDef, LAdapter);
    end;
  end;
end;

procedure TBenchRunner.RunScenario(
  const ADef:     TBenchScenarioDef;
  const AAdapter: IBenchAdapter
);
var
  LLib:     TBenchLibrary;
  LMetrics: TBenchMetrics;
  LBaseURL: string;
  I:        Integer;
begin
  // Mapear nome do adapter para enum
  LLib := libPoseidonAuto;
  if AAdapter.Name = 'Workers=4' then LLib := libPoseidonW4
  else if AAdapter.Name = 'Gzip'      then LLib := libPoseidonGzip
  else if AAdapter.Name = 'SSL'       then LLib := libPoseidonSSL;

  LMetrics := TBenchMetrics.Create(LLib, ADef.Name);
  FResults.Add(LMetrics);

  if not AAdapter.IsAvailable then
  begin
    LMetrics.Skipped    := True;
    LMetrics.SkipReason := 'Configuração não disponível (ex: OpenSSL ausente)';
    Log(Format('   [%s] N/A — %s', [AAdapter.Name, LMetrics.SkipReason]));
    Exit;
  end;

  // A URL base vem do adapter (cada um tem sua própria porta)
  LBaseURL := AAdapter.BaseURL;
  if LBaseURL = '' then
    LBaseURL := FBaseURL;

  // Reset antes de cenários sequenciais
  if ADef.Threads <= 1 then
    AAdapter.Reset;

  // Warmup
  if ADef.WarmupCount > 0 then
  begin
    I := 0;
    while I < ADef.WarmupCount do
    begin
      try
        AAdapter.Execute(LBaseURL + ADef.Endpoint, ADef.Method, ADef.Body);
      except
      end;
      Inc(I);
    end;
  end;

  LMetrics.MemStart := GetWorkingSetBytes;

  if ADef.Threads <= 1 then
    RunSequential(ADef, AAdapter, LMetrics)
  else
    RunConcurrent(ADef, AAdapter, LMetrics);

  LMetrics.MemEnd := GetWorkingSetBytes;

  Log(Format('   [%s] %.1f rps | avg %.1fms | p99 %dms | erros: %d',
    [AAdapter.Name, LMetrics.RPS, LMetrics.AvgMs, LMetrics.P99, LMetrics.ErrorCount]));
end;

procedure TBenchRunner.RunSequential(
  const ADef:     TBenchScenarioDef;
  const AAdapter: IBenchAdapter;
  const AMetrics: TBenchMetrics
);
var
  LSW:     TStopwatch;
  I:       Integer;
  LMs:     Int64;
  LBaseURL: string;
begin
  LBaseURL := AAdapter.BaseURL;
  if LBaseURL = '' then LBaseURL := FBaseURL;

  LSW := TStopwatch.StartNew;
  for I := 1 to ADef.Count do
  begin
    try
      LMs := AAdapter.Execute(LBaseURL + ADef.Endpoint, ADef.Method, ADef.Body);
      AMetrics.AddLatency(LMs);
    except
      on E: Exception do
      begin
        if AMetrics.ErrorCount = 0 then
          Log(Format('   [%s] primeiro erro: %s', [AAdapter.Name, E.Message]));
        AMetrics.IncError;
        AMetrics.AddLatency(0);
      end;
    end;
  end;
  AMetrics.TotalMs := LSW.ElapsedMilliseconds;
end;

procedure TBenchRunner.RunConcurrent(
  const ADef:     TBenchScenarioDef;
  const AAdapter: IBenchAdapter;
  const AMetrics: TBenchMetrics
);
var
  LSW:        TStopwatch;
  LTasks:     TArray<ITask>;
  LGate:      TEvent;
  LPerThread: Integer;
  I:          Integer;
  LBaseURL:   string;
  LCount:     Integer;
  LURL:       string;
  LMeth:      string;
  LBody:      string;
  LAdap:      IBenchAdapter;
begin
  LBaseURL := AAdapter.BaseURL;
  if LBaseURL = '' then LBaseURL := FBaseURL;

  LGate      := TEvent.Create(nil, True, False, '');
  LPerThread := Max(1, ADef.Count div ADef.Threads);
  SetLength(LTasks, ADef.Threads);

  try
    for I := 0 to ADef.Threads - 1 do
    begin
      LCount := LPerThread;
      LURL   := LBaseURL + ADef.Endpoint;
      LMeth  := ADef.Method;
      LBody  := ADef.Body;
      LAdap  := AAdapter;

      LTasks[I] := TTask.Run(
        procedure
        var
          J:      Integer;
          LMs:    Int64;
          LClone: IBenchAdapter;
          K:      Integer;
        begin
          try
            try
              LClone := LAdap.Clone;
            except
              on E: Exception do
              begin
                K := 0;
                while K < LCount do
                begin
                  AMetrics.IncError;
                  AMetrics.AddLatency(0);
                  Inc(K);
                end;
                Exit;
              end;
            end;
            LGate.WaitFor(INFINITE);
            for J := 1 to LCount do
            begin
              try
                LMs := LClone.Execute(LURL, LMeth, LBody);
                AMetrics.AddLatency(LMs);
              except
                on E: Exception do
                begin
                  AMetrics.IncError;
                  AMetrics.AddLatency(0);
                end;
              end;
            end;
          except
            on E: Exception do
              AMetrics.IncError;
          end;
        end
      );
    end;

    LSW := TStopwatch.StartNew;
    LGate.SetEvent;

    // 10-second wall-clock timeout — prevents hanging when a backend AV or
    // network failure causes client threads to block indefinitely.
    if not TTask.WaitForAll(LTasks, 10000) then
    begin
      // Tasks that didn't complete contribute 0-ms error entries.
      // The tasks themselves are abandoned (Delphi TTask cannot be cancelled).
      AMetrics.AddLatency(0);
      AMetrics.IncError;
    end;
    AMetrics.TotalMs := LSW.ElapsedMilliseconds;
  finally
    LGate.Free;
  end;
end;

function TBenchRunner.Results: TObjectList<TBenchMetrics>;
begin
  Result := FResults;
end;

end.
