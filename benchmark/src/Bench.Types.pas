unit Bench.Types;

// Tipos base: métricas, cenários, coleta thread-safe de resultados.

interface

uses
  System.SysUtils,
  System.Math,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.SyncObjs
  {$IFDEF MSWINDOWS}
  , Winapi.Windows
  , Winapi.PsAPI
  {$ENDIF}
  ;

type
  // Cada valor representa uma configuração de servidor Poseidon.
  TBenchLibrary = (libPoseidonW4, libPoseidonAuto, libPoseidonGzip, libPoseidonSSL);

const
  LIB_NAME: array[TBenchLibrary] of string = (
    'Workers=4', 'Workers=auto', 'Gzip', 'SSL'
  );
  LIB_COLOR: array[TBenchLibrary] of string = (
    '#7C3AED', '#14B8A6', '#F59E0B', '#3B82F6'
  );
  LIB_BG: array[TBenchLibrary] of string = (
    'rgba(124,58,237,0.18)', 'rgba(20,184,166,0.18)',
    'rgba(245,158,11,0.18)', 'rgba(59,130,246,0.18)'
  );

type
  TBenchScenarioDef = record
    Name:        string;
    Description: string;
    Endpoint:    string;
    Method:      string;
    Body:        string;
    Count:       Integer;   // total de requests
    Threads:     Integer;   // 1 = sequencial
    WarmupCount: Integer;
    class function Make(
      const AName, ADesc, AEndpoint, AMethod: string;
      const ACount, AThreads, AWarmup: Integer;
      const ABody: string = ''
    ): TBenchScenarioDef; static;
  end;

  // Resultado de uma configuraçãoxcenário — coleta thread-safe
  TBenchMetrics = class
  private
    FLock:      TCriticalSection;
    FLatencies: TList<Int64>;
    FSorted:    TArray<Int64>;
    FSortDirty: Boolean;
    procedure EnsureSorted;
    function  Percentile(const AP: Double): Int64;
  public
    Lib:        TBenchLibrary;
    Scenario:   string;
    TotalMs:    Int64;
    ErrorCount: Integer;
    MemStart:   Int64;  // bytes
    MemEnd:     Int64;
    Skipped:    Boolean;
    SkipReason: string;

    constructor Create(const ALib: TBenchLibrary; const AScenario: string);
    destructor  Destroy; override;

    procedure AddLatency(const AMs: Int64);
    procedure IncError;
    function  Count:        Integer;
    function  SuccessCount: Integer;
    function  RPS:          Double;
    function  AvgMs:        Double;
    function  P50:          Int64;
    function  P95:          Int64;
    function  P99:          Int64;
    function  MinMs:        Int64;
    function  MaxMs:        Int64;
    function  MemDeltaMB:   Double;
  end;

function GetWorkingSetBytes: Int64;

implementation

{ TBenchScenarioDef }

class function TBenchScenarioDef.Make(
  const AName, ADesc, AEndpoint, AMethod: string;
  const ACount, AThreads, AWarmup: Integer;
  const ABody: string
): TBenchScenarioDef;
begin
  Result.Name        := AName;
  Result.Description := ADesc;
  Result.Endpoint    := AEndpoint;
  Result.Method      := AMethod;
  Result.Body        := ABody;
  Result.Count       := ACount;
  Result.Threads     := AThreads;
  Result.WarmupCount := AWarmup;
end;

{ TBenchMetrics }

constructor TBenchMetrics.Create(const ALib: TBenchLibrary; const AScenario: string);
begin
  inherited Create;
  FLock      := TCriticalSection.Create;
  FLatencies := TList<Int64>.Create;
  FSortDirty := True;
  Lib        := ALib;
  Scenario   := AScenario;
end;

destructor TBenchMetrics.Destroy;
begin
  FLatencies.Free;
  FLock.Free;
  inherited;
end;

procedure TBenchMetrics.AddLatency(const AMs: Int64);
begin
  FLock.Acquire;
  try
    FLatencies.Add(AMs);
    FSortDirty := True;
  finally
    FLock.Release;
  end;
end;

procedure TBenchMetrics.IncError;
begin
  FLock.Acquire;
  try
    Inc(ErrorCount);
  finally
    FLock.Release;
  end;
end;

procedure TBenchMetrics.EnsureSorted;
begin
  if FSortDirty then
  begin
    FSorted    := FLatencies.ToArray;
    TArray.Sort<Int64>(FSorted);
    FSortDirty := False;
  end;
end;

function TBenchMetrics.Percentile(const AP: Double): Int64;
var
  LIdx: Integer;
begin
  EnsureSorted;
  if Length(FSorted) = 0 then Exit(0);
  LIdx := Max(0, Min(
    Round(AP / 100.0 * Length(FSorted)) - 1,
    High(FSorted)
  ));
  Result := FSorted[LIdx];
end;

function TBenchMetrics.Count: Integer;
begin
  Result := FLatencies.Count;
end;

function TBenchMetrics.SuccessCount: Integer;
begin
  Result := Max(0, Count - ErrorCount);
end;

function TBenchMetrics.RPS: Double;
begin
  if TotalMs = 0 then Exit(0);
  Result := Count / (TotalMs / 1000.0);
end;

function TBenchMetrics.AvgMs: Double;
var
  LSum: Int64;
  LV:   Int64;
begin
  if Count = 0 then Exit(0);
  LSum := 0;
  for LV in FLatencies do Inc(LSum, LV);
  Result := LSum / Count;
end;

function TBenchMetrics.P50: Int64;  begin Result := Percentile(50);  end;
function TBenchMetrics.P95: Int64;  begin Result := Percentile(95);  end;
function TBenchMetrics.P99: Int64;  begin Result := Percentile(99);  end;

function TBenchMetrics.MinMs: Int64;
begin
  EnsureSorted;
  if Length(FSorted) = 0 then Exit(0);
  Result := FSorted[0];
end;

function TBenchMetrics.MaxMs: Int64;
begin
  EnsureSorted;
  if Length(FSorted) = 0 then Exit(0);
  Result := FSorted[High(FSorted)];
end;

function TBenchMetrics.MemDeltaMB: Double;
begin
  Result := (MemEnd - MemStart) / (1024 * 1024);
end;

{ helpers }

function GetWorkingSetBytes: Int64;
{$IFDEF MSWINDOWS}
var
  PMC: PROCESS_MEMORY_COUNTERS;
begin
  if GetProcessMemoryInfo(GetCurrentProcess, @PMC, SizeOf(PMC)) then
    Result := PMC.WorkingSetSize
  else
    Result := 0;
end;
{$ELSE}
// Linux: lê VmRSS de /proc/self/status (em kB)
var
  LFile: TextFile;
  LLine: string;
  LVal:  Int64;
begin
  Result := 0;
  AssignFile(LFile, '/proc/self/status');
  try
    Reset(LFile);
    try
      while not Eof(LFile) do
      begin
        ReadLn(LFile, LLine);
        if LLine.StartsWith('VmRSS:') then
        begin
          LVal   := StrToInt64Def(Trim(LLine.Substring(6).Replace('kB','').Trim), 0);
          Result := LVal * 1024;
          Break;
        end;
      end;
    finally
      CloseFile(LFile);
    end;
  except
    Result := 0;
  end;
end;
{$ENDIF}

end.
