unit Poseidon.Middleware.Metrics;

// Prometheus-compatible metrics middleware.
// Collects per-path request counts, error counts and latency histogram.
//
// Usage:
//   App.Use(MetricsMiddleware);
//   App.Use(MetricsMiddleware('/internal/metrics'));

interface

uses
  Poseidon.Native.Types;

function MetricsMiddleware(const APath: string = '/metrics'): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.Diagnostics;

const
  CHistBounds: array[0..7] of Int64 = (5, 10, 25, 50, 100, 250, 500, 1000);
  CHistBoundsStr: array[0..7] of string = ('5', '10', '25', '50', '100', '250', '500', '1000');

type
  TMetricBucket = record
    Requests: Int64;
    Errors: Int64;
    DurationSum: Int64;
    HistBuckets: array[0..8] of Int64;
  end;

  TMetricsStore = class
  private
    FLock: TCriticalSection;
    FBuckets: TDictionary<string, TMetricBucket>;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Record_(const AKey: string; ADurationMs: Int64; AIsError: Boolean);
    function Snapshot: TArray<TPair<string, TMetricBucket>>;
  end;

constructor TMetricsStore.Create;
begin
  FLock := TCriticalSection.Create;
  FBuckets := TDictionary<string, TMetricBucket>.Create;
end;

destructor TMetricsStore.Destroy;
begin
  FBuckets.Free;
  FLock.Free;
  inherited;
end;

procedure TMetricsStore.Record_(const AKey: string; ADurationMs: Int64; AIsError: Boolean);
var
  LBucket: TMetricBucket;
  I: Integer;
begin
  FLock.Enter;
  try
    if not FBuckets.TryGetValue(AKey, LBucket) then
      LBucket := Default(TMetricBucket);
    Inc(LBucket.Requests);
    Inc(LBucket.DurationSum, ADurationMs);
    if AIsError then
      Inc(LBucket.Errors);
    for I := 0 to 7 do
      if ADurationMs <= CHistBounds[I] then
        Inc(LBucket.HistBuckets[I]);
    Inc(LBucket.HistBuckets[8]);
    FBuckets.AddOrSetValue(AKey, LBucket);
  finally
    FLock.Leave;
  end;
end;

function TMetricsStore.Snapshot: TArray<TPair<string, TMetricBucket>>;
var
  LPair: TPair<string, TMetricBucket>;
  I: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, FBuckets.Count);
    I := 0;
    for LPair in FBuckets do
    begin
      Result[I] := LPair;
      Inc(I);
    end;
  finally
    FLock.Leave;
  end;
end;

function BuildPrometheusText(const AStore: TMetricsStore): string;
var
  LPairs: TArray<TPair<string, TMetricBucket>>;
  LPair: TPair<string, TMetricBucket>;
  LSB: TStringBuilder;
  I: Integer;
begin
  LPairs := AStore.Snapshot;
  LSB := TStringBuilder.Create;
  try
    LSB.AppendLine('# HELP poseidon_requests_total Total HTTP requests handled');
    LSB.AppendLine('# TYPE poseidon_requests_total counter');
    for LPair in LPairs do
      LSB.AppendLine(Format('poseidon_requests_total{path="%s"} %d',
        [LPair.Key, LPair.Value.Requests]));

    LSB.AppendLine('# HELP poseidon_errors_total HTTP requests with status >= 400');
    LSB.AppendLine('# TYPE poseidon_errors_total counter');
    for LPair in LPairs do
      if LPair.Value.Errors > 0 then
        LSB.AppendLine(Format('poseidon_errors_total{path="%s"} %d',
          [LPair.Key, LPair.Value.Errors]));

    LSB.AppendLine('# HELP poseidon_request_duration_ms Histogram of request durations in ms');
    LSB.AppendLine('# TYPE poseidon_request_duration_ms histogram');
    for LPair in LPairs do
    begin
      for I := 0 to 7 do
        LSB.AppendLine(Format('poseidon_request_duration_ms_bucket{path="%s",le="%s"} %d',
          [LPair.Key, CHistBoundsStr[I], LPair.Value.HistBuckets[I]]));
      LSB.AppendLine(Format('poseidon_request_duration_ms_bucket{path="%s",le="+Inf"} %d',
        [LPair.Key, LPair.Value.HistBuckets[8]]));
      LSB.AppendLine(Format('poseidon_request_duration_ms_sum{path="%s"} %d',
        [LPair.Key, LPair.Value.DurationSum]));
      LSB.AppendLine(Format('poseidon_request_duration_ms_count{path="%s"} %d',
        [LPair.Key, LPair.Value.Requests]));
    end;

    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

function MetricsMiddleware(const APath: string): TNativeMiddlewareFunc;
var
  LStore: TMetricsStore;
begin
  LStore := TMetricsStore.Create;
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LSW: TStopwatch;
      LIsError: Boolean;
    begin
      if ACtx.Path.TrimRight(['/']) = APath.TrimRight(['/']) then
      begin
        ACtx.Status := 200;
        ACtx.ContentType := 'text/plain; version=0.0.4; charset=utf-8';
        ACtx.Body := TEncoding.UTF8.GetBytes(BuildPrometheusText(LStore));
        ACtx.Handled := True;
        Exit;
      end;

      LSW := TStopwatch.StartNew;
      LIsError := False;
      try
        try
          ANext();
          LIsError := ACtx.Status >= 400;
        except
          LIsError := True;
          raise;
        end;
      finally
        LSW.Stop;
        LStore.Record_(ACtx.Path, LSW.ElapsedMilliseconds, LIsError);
      end;
    end;
end;

end.
