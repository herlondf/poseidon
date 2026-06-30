unit Poseidon.Middleware.CircuitBreaker;

// Sliding-window circuit breaker middleware.
// States: Closed → Open → HalfOpen → Closed
// Open state returns 503 without calling the handler.

interface

uses
  Poseidon.Callback,
  Poseidon.Proc;

type
  TPoseidonMiddlewareCircuitBreaker = class
  public
    // AErrorThresholdPct: open circuit when error% >= this value (0-100)
    // AWindowSec:         sliding window size in seconds
    // AOpenDurationSec:   how long to stay Open before trying HalfOpen
    class function New(AErrorThresholdPct: Integer = 50;
      AWindowSec: Integer = 60; AOpenDurationSec: Integer = 30): TPoseidonCallback; static;
  end;

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.DateUtils,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Commons;

type
  TCircuitState = (csClosed, csOpen, csHalfOpen);

  TBucket = record
    Timestamp: TDateTime;
    Requests:  Integer;
    Errors:    Integer;
  end;

  TCircuitBreaker = class
  private
    FLock:              TCriticalSection;
    FState:             TCircuitState;
    FOpenedAt:          TDateTime;
    FBuckets:           array[0..59] of TBucket;
    FErrorThresholdPct: Integer;
    FWindowSec:         Integer;
    FOpenDurationSec:   Integer;
    procedure EvictStale(ANow: TDateTime);
    procedure RecordResult(AError: Boolean);
    function ErrorRate: Double;
  public
    constructor Create(AErrorThresholdPct, AWindowSec, AOpenDurationSec: Integer);
    destructor Destroy; override;
    // Returns True if the request should be allowed through
    function TryAcquire: Boolean;
    procedure RecordSuccess;
    procedure RecordFailure;
  end;

constructor TCircuitBreaker.Create(AErrorThresholdPct, AWindowSec, AOpenDurationSec: Integer);
begin
  FLock              := TCriticalSection.Create;
  FState             := csClosed;
  FErrorThresholdPct := AErrorThresholdPct;
  FWindowSec         := AWindowSec;
  FOpenDurationSec   := AOpenDurationSec;
end;

destructor TCircuitBreaker.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TCircuitBreaker.EvictStale(ANow: TDateTime);
var
  I:     Integer;
  Cutoff: TDateTime;
begin
  Cutoff := IncSecond(ANow, -FWindowSec);
  for I := 0 to High(FBuckets) do
    if (FBuckets[I].Requests > 0) and (FBuckets[I].Timestamp < Cutoff) then
      FBuckets[I] := Default(TBucket);
end;

function TCircuitBreaker.ErrorRate: Double;
var
  I, TotalReqs, TotalErrs: Integer;
begin
  TotalReqs := 0;
  TotalErrs := 0;
  for I := 0 to High(FBuckets) do
  begin
    Inc(TotalReqs, FBuckets[I].Requests);
    Inc(TotalErrs, FBuckets[I].Errors);
  end;
  if TotalReqs = 0 then
    Result := 0
  else
    Result := (TotalErrs / TotalReqs) * 100;
end;

procedure TCircuitBreaker.RecordResult(AError: Boolean);
var
  ANow:  TDateTime;
  Slot:  Integer;
begin
  ANow := Now;
  EvictStale(ANow);
  // Use second-of-minute as bucket slot
  Slot := SecondOf(ANow) mod Length(FBuckets);
  if FBuckets[Slot].Timestamp < IncSecond(ANow, -1) then
    FBuckets[Slot] := Default(TBucket);
  FBuckets[Slot].Timestamp := ANow;
  Inc(FBuckets[Slot].Requests);
  if AError then
    Inc(FBuckets[Slot].Errors);
end;

function TCircuitBreaker.TryAcquire: Boolean;
var
  ANow: TDateTime;
begin
  FLock.Enter;
  try
    ANow := Now;
    case FState of
      csClosed:
        Result := True;
      csOpen:
      begin
        if SecondsBetween(ANow, FOpenedAt) >= FOpenDurationSec then
        begin
          FState := csHalfOpen;
          Result := True;
        end
        else
          Result := False;
      end;
      csHalfOpen:
        Result := True;
    else
      Result := False;
    end;
  finally
    FLock.Leave;
  end;
end;

procedure TCircuitBreaker.RecordSuccess;
begin
  FLock.Enter;
  try
    RecordResult(False);
    if FState = csHalfOpen then
      FState := csClosed;
  finally
    FLock.Leave;
  end;
end;

procedure TCircuitBreaker.RecordFailure;
begin
  FLock.Enter;
  try
    RecordResult(True);
    if FState = csHalfOpen then
    begin
      FState    := csOpen;
      FOpenedAt := Now;
    end
    else if (FState = csClosed) and (ErrorRate >= FErrorThresholdPct) then
    begin
      FState    := csOpen;
      FOpenedAt := Now;
    end;
  finally
    FLock.Leave;
  end;
end;

{ TPoseidonMiddlewareCircuitBreaker }

class function TPoseidonMiddlewareCircuitBreaker.New(AErrorThresholdPct,
  AWindowSec, AOpenDurationSec: Integer): TPoseidonCallback;
var
  LBreaker: TCircuitBreaker;
begin
  LBreaker := TCircuitBreaker.Create(AErrorThresholdPct, AWindowSec, AOpenDurationSec);
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      if not LBreaker.TryAcquire then
      begin
        Res.Status(THTTPStatus.ServiceUnavailable)
           .Header('Content-Type', 'application/problem+json')
           .Send(
             '{"type":"about:blank","title":"Service Unavailable",' +
             '"status":503,"detail":"Circuit breaker is open"}');
        Exit;
      end;
      try
        Next();
        LBreaker.RecordSuccess;
      except
        LBreaker.RecordFailure;
        raise;
      end;
    end;
end;

end.
