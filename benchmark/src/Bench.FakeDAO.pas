unit Bench.FakeDAO;

// Simulated database access layer for benchmarking.
//
// All operations sleep for a configurable duration to reproduce the latency
// profile of real DB calls without requiring a running database.  Results are
// reproducible and independent of network or query-planner variance.
//
// Usage:
//   DAO := TFakeDAO.Create(DAO_LATENCY_MEDIUM);
//   DAO.FindByID(1, Rec);  // blocks for ~30 ms, then returns a fake record

interface

uses
  System.SysUtils;

const
  DAO_LATENCY_FAST   =     5;  // Simple SELECT by PK on SSD
  DAO_LATENCY_MEDIUM =    30;  // SELECT with joins, index OK
  DAO_LATENCY_SLOW   =   100;  // Complex query or row-lock contention
  DAO_LATENCY_SEFAZ  = 30000;  // External service timeout (NFCe-style)

type
  TFakeUserRecord = record
    ID:    Integer;
    Name:  string;
    Email: string;
  end;

  TFakeDAO = class
  private
    FLatencyMs:    Integer;
    FLatencyMaxMs: Integer;

    procedure DoSleep(AFactor: Integer = 1);
  public
    // ALatencyMs:    fixed sleep (ms) per operation.
    // ALatencyMaxMs: when > ALatencyMs, sleep is randomised in [ALatencyMs..ALatencyMaxMs].
    constructor Create(ALatencyMs: Integer; ALatencyMaxMs: Integer = 0);

    // Simulates SELECT by PK → Sleep(LatencyMs × 1)
    procedure FindByID(AID: Integer; out AResult: TFakeUserRecord);

    // Simulates INSERT → Sleep(LatencyMs × 1)
    procedure Create_(const ARecord: TFakeUserRecord);

    // Simulates UPDATE → Sleep(LatencyMs × 1)
    procedure Update(const ARecord: TFakeUserRecord);

    // Simulates DELETE → Sleep(LatencyMs × 1)
    procedure Delete(AID: Integer);

    // Simulates paginated SELECT → Sleep(LatencyMs × 2)
    function ListAll(APage, APageSize: Integer): TArray<TFakeUserRecord>;

    property LatencyMs:    Integer read FLatencyMs    write FLatencyMs;
    property LatencyMaxMs: Integer read FLatencyMaxMs write FLatencyMaxMs;
  end;

implementation

uses
  System.Math;

constructor TFakeDAO.Create(ALatencyMs: Integer; ALatencyMaxMs: Integer);
begin
  inherited Create;
  FLatencyMs    := ALatencyMs;
  FLatencyMaxMs := ALatencyMaxMs;
end;

procedure TFakeDAO.DoSleep(AFactor: Integer);
var
  LMs: Integer;
begin
  if FLatencyMs <= 0 then Exit;
  if (FLatencyMaxMs > FLatencyMs) then
    LMs := FLatencyMs + Random(FLatencyMaxMs - FLatencyMs)
  else
    LMs := FLatencyMs;
  Sleep(LMs * AFactor);
end;

procedure TFakeDAO.FindByID(AID: Integer; out AResult: TFakeUserRecord);
begin
  DoSleep(1);
  AResult.ID    := AID;
  AResult.Name  := Format('User_%d', [AID]);
  AResult.Email := Format('user%d@bench.test', [AID]);
end;

procedure TFakeDAO.Create_(const ARecord: TFakeUserRecord);
begin
  DoSleep(1);
end;

procedure TFakeDAO.Update(const ARecord: TFakeUserRecord);
begin
  DoSleep(1);
end;

procedure TFakeDAO.Delete(AID: Integer);
begin
  DoSleep(1);
end;

function TFakeDAO.ListAll(APage, APageSize: Integer): TArray<TFakeUserRecord>;
var
  I:     Integer;
  LBase: Integer;
begin
  DoSleep(2);  // paginated query is heavier
  SetLength(Result, APageSize);
  LBase := (APage - 1) * APageSize + 1;
  for I := 0 to APageSize - 1 do
  begin
    Result[I].ID    := LBase + I;
    Result[I].Name  := Format('User_%d', [LBase + I]);
    Result[I].Email := Format('user%d@bench.test', [LBase + I]);
  end;
end;

end.
