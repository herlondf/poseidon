unit Poseidon.Middleware.CircuitBreaker;

// Sliding-window circuit breaker middleware.
// States: Closed -> Open -> HalfOpen -> Closed
// Open state returns 503 without calling the handler.
//
// Usage:
//   App.Use(CircuitBreakerMiddleware);
//   App.Use(CircuitBreakerMiddleware(50, 60, 30));

interface

uses
  Poseidon.Native.Types;

function CircuitBreakerMiddleware(AErrorThresholdPct: Integer = 50;
  AWindowSec: Integer = 60; AOpenDurationSec: Integer = 30): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.DateUtils;

type
  TCircuitState = (csClosed, csOpen, csHalfOpen);

  TBucket = record
    Timestamp: TDateTime;
    Requests: Integer;
    Errors: Integer;
  end;

  TCircuitBreaker = class
  private
    FLock: TCriticalSection;
    FState: TCircuitState;
    FOpenedAt: TDateTime;
    FBuckets: array[0..59] of TBucket;
    FErrorThresholdPct: Integer;
    FWindowSec: Integer;
    FOpenDurationSec: Integer;
    FHalfOpenProbes: Integer;
    procedure EvictStale(ANow: TDateTime);
    procedure RecordResult(AError: Boolean);
    procedure ResetBuckets;
    function ErrorRate: Double;
  public
    constructor Create(AErrorThresholdPct, AWindowSec, AOpenDurationSec: Integer);
    destructor Destroy; override;
    function TryAcquire: Boolean;
    procedure RecordSuccess;
    procedure RecordFailure;
  end;

constructor TCircuitBreaker.Create(AErrorThresholdPct, AWindowSec, AOpenDurationSec: Integer);
begin
  FLock := TCriticalSection.Create;
  FState := csClosed;
  FErrorThresholdPct := AErrorThresholdPct;
  FWindowSec := AWindowSec;
  FOpenDurationSec := AOpenDurationSec;
end;

destructor TCircuitBreaker.Destroy;
begin
  FLock.Free;
  inherited;
end;

procedure TCircuitBreaker.EvictStale(ANow: TDateTime);
var
  I: Integer;
  LCutoff: TDateTime;
begin
  LCutoff := IncSecond(ANow, -FWindowSec);
  for I := 0 to High(FBuckets) do
    if (FBuckets[I].Requests > 0) and (FBuckets[I].Timestamp < LCutoff) then
      FBuckets[I] := Default(TBucket);
end;

procedure TCircuitBreaker.ResetBuckets;
var
  I: Integer;
begin
  for I := 0 to High(FBuckets) do
    FBuckets[I] := Default(TBucket);
end;

function TCircuitBreaker.ErrorRate: Double;
var
  I, LTotalReqs, LTotalErrs: Integer;
begin
  LTotalReqs := 0;
  LTotalErrs := 0;
  for I := 0 to High(FBuckets) do
  begin
    Inc(LTotalReqs, FBuckets[I].Requests);
    Inc(LTotalErrs, FBuckets[I].Errors);
  end;
  if LTotalReqs = 0 then
    Result := 0
  else
    Result := (LTotalErrs / LTotalReqs) * 100;
end;

procedure TCircuitBreaker.RecordResult(AError: Boolean);
var
  LNow: TDateTime;
  LSlot: Integer;
begin
  LNow := Now;
  EvictStale(LNow);
  LSlot := SecondOf(LNow) mod Length(FBuckets);
  if FBuckets[LSlot].Timestamp < IncSecond(LNow, -1) then
    FBuckets[LSlot] := Default(TBucket);
  FBuckets[LSlot].Timestamp := LNow;
  Inc(FBuckets[LSlot].Requests);
  if AError then
    Inc(FBuckets[LSlot].Errors);
end;

function TCircuitBreaker.TryAcquire: Boolean;
var
  LNow: TDateTime;
begin
  FLock.Enter;
  try
    LNow := Now;
    case FState of
      csClosed:
        Result := True;
      csOpen:
      begin
        if SecondsBetween(LNow, FOpenedAt) >= FOpenDurationSec then
        begin
          // Transition to half-open and let THIS caller be the single probe.
          FState := csHalfOpen;
          FHalfOpenProbes := 1;
          Result := True;
        end
        else
          Result := False;
      end;
      csHalfOpen:
        // #184: admit only one probe at a time; the rest get 503 until the
        // probe resolves (success -> closed, failure -> open). Prevents the
        // thundering herd that hammered a degraded backend.
        if FHalfOpenProbes >= 1 then
          Result := False
        else
        begin
          FHalfOpenProbes := 1;
          Result := True;
        end;
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
    begin
      // #184: a successful probe closes the breaker. Clear the error window so
      // stale failures don't immediately reopen it on the next request.
      FState := csClosed;
      FHalfOpenProbes := 0;
      ResetBuckets;
    end;
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
      FState := csOpen;
      FOpenedAt := Now;
      FHalfOpenProbes := 0;
    end
    else if (FState = csClosed) and (ErrorRate >= FErrorThresholdPct) then
    begin
      FState := csOpen;
      FOpenedAt := Now;
    end;
  finally
    FLock.Leave;
  end;
end;

function CircuitBreakerMiddleware(AErrorThresholdPct, AWindowSec,
  AOpenDurationSec: Integer): TNativeMiddlewareFunc;
var
  LBreaker: TCircuitBreaker;
begin
  LBreaker := TCircuitBreaker.Create(AErrorThresholdPct, AWindowSec, AOpenDurationSec);
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      if not LBreaker.TryAcquire then
      begin
        ACtx.Status := 503;
        ACtx.ContentType := 'application/problem+json';
        ACtx.Body := TEncoding.UTF8.GetBytes(
          '{"type":"about:blank","title":"Service Unavailable",' +
          '"status":503,"detail":"Circuit breaker is open"}');
        ACtx.Handled := True;
        Exit;
      end;
      try
        ANext();
        LBreaker.RecordSuccess;
      except
        LBreaker.RecordFailure;
        raise;
      end;
    end;
end;

end.
