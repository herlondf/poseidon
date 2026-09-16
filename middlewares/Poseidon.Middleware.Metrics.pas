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
  System.Diagnostics,
  Poseidon.Diagnostics;

const
  CHistBounds: array[0..7] of Int64 = (5, 10, 25, 50, 100, 250, 500, 1000);
  CHistBoundsStr: array[0..7] of string = ('5', '10', '25', '50', '100', '250', '500', '1000');
  // Bound label cardinality: a hostile client hitting unique paths (/x1, /x2,
  // ...) would otherwise grow FBuckets until OOM. Overflow collapses to 'other'.
  CMaxUniquePaths = 10000;

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
  LKey: string;
  LBucket: TMetricBucket;
  I: Integer;
begin
  FLock.Enter;
  try
    LKey := AKey;
    if not FBuckets.ContainsKey(LKey) and (FBuckets.Count >= CMaxUniquePaths) then
      LKey := 'other';
    if not FBuckets.TryGetValue(LKey, LBucket) then
      LBucket := Default(TMetricBucket);
    Inc(LBucket.Requests);
    Inc(LBucket.DurationSum, ADurationMs);
    if AIsError then
      Inc(LBucket.Errors);
    for I := 0 to 7 do
      if ADurationMs <= CHistBounds[I] then
        Inc(LBucket.HistBuckets[I]);
    Inc(LBucket.HistBuckets[8]);
    FBuckets.AddOrSetValue(LKey, LBucket);
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

// Escapes a Prometheus label value (backslash, double-quote, newline) so a path
// containing '"' cannot break the exposition line and fail the scrape.
function EscapePromLabel(const S: string): string;
begin
  Result := StringReplace(S, '\', '\\', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '\"', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '\n', [rfReplaceAll]);
end;

// Process-level gauges (memory/fd) - one value per process, no path label,
// unlike everything else this middleware exposes. Sourced from
// TPoseidonDiagnostics so this never re-implements /proc parsing or duplicates
// a number the [health] log line already computes the same way. -1 (Windows,
// or unavailable) is intentionally still emitted as a real gauge value rather
// than omitted: a scraped "-1" is an unambiguous, queryable "not available on
// this platform", where a missing metric silently looks like "still zero" to
// anyone graphing it.
procedure AppendProcessGauges(ALSB: TStringBuilder);
var
  LMallocInUseKB, LMallocArenaKB, LMallocMmapKB: Int64;
begin
  ALSB.AppendLine('# HELP poseidon_rss_kb Process resident set size (KB)');
  ALSB.AppendLine('# TYPE poseidon_rss_kb gauge');
  ALSB.AppendLine(Format('poseidon_rss_kb %d', [TPoseidonDiagnostics.RSSKB]));

  TPoseidonDiagnostics.MallocInfo(LMallocInUseKB, LMallocArenaKB, LMallocMmapKB);
  ALSB.AppendLine('# HELP poseidon_malloc_inuse_kb glibc mallinfo2 uordblks - bytes the app still holds live (Linux only, -1 on Windows)');
  ALSB.AppendLine('# TYPE poseidon_malloc_inuse_kb gauge');
  ALSB.AppendLine(Format('poseidon_malloc_inuse_kb %d', [LMallocInUseKB]));
  ALSB.AppendLine('# HELP poseidon_malloc_arena_kb glibc mallinfo2 arena - non-mmap heap footprint sbrk''d from the OS (Linux only, -1 on Windows)');
  ALSB.AppendLine('# TYPE poseidon_malloc_arena_kb gauge');
  ALSB.AppendLine(Format('poseidon_malloc_arena_kb %d', [LMallocArenaKB]));
  ALSB.AppendLine('# HELP poseidon_malloc_mmap_kb glibc mallinfo2 hblkhd - large allocations backed by mmap (Linux only, -1 on Windows)');
  ALSB.AppendLine('# TYPE poseidon_malloc_mmap_kb gauge');
  ALSB.AppendLine(Format('poseidon_malloc_mmap_kb %d', [LMallocMmapKB]));

  ALSB.AppendLine('# HELP poseidon_delphi_heap_kb Delphi memory manager bytes in use (Windows/OSX only, -1 on Linux - see Poseidon.Diagnostics)');
  ALSB.AppendLine('# TYPE poseidon_delphi_heap_kb gauge');
  ALSB.AppendLine(Format('poseidon_delphi_heap_kb %d', [TPoseidonDiagnostics.DelphiHeapInUseKB]));

  ALSB.AppendLine('# HELP poseidon_fd_count Open file descriptors (Linux only, -1 on Windows)');
  ALSB.AppendLine('# TYPE poseidon_fd_count gauge');
  ALSB.AppendLine(Format('poseidon_fd_count %d', [TPoseidonDiagnostics.OpenFDCount]));

  ALSB.AppendLine('# HELP poseidon_private_dirty_kb /proc/self/smaps_rollup Private_Dirty - memory only this process holds, shared library pages excluded (Linux only, -1 on Windows)');
  ALSB.AppendLine('# TYPE poseidon_private_dirty_kb gauge');
  ALSB.AppendLine(Format('poseidon_private_dirty_kb %d', [TPoseidonDiagnostics.PrivateDirtyKB]));
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
    AppendProcessGauges(LSB);

    LSB.AppendLine('# HELP poseidon_requests_total Total HTTP requests handled');
    LSB.AppendLine('# TYPE poseidon_requests_total counter');
    for LPair in LPairs do
      LSB.AppendLine(Format('poseidon_requests_total{path="%s"} %d',
        [EscapePromLabel(LPair.Key),LPair.Value.Requests]));

    LSB.AppendLine('# HELP poseidon_errors_total HTTP requests with status >= 400');
    LSB.AppendLine('# TYPE poseidon_errors_total counter');
    for LPair in LPairs do
      if LPair.Value.Errors > 0 then
        LSB.AppendLine(Format('poseidon_errors_total{path="%s"} %d',
          [EscapePromLabel(LPair.Key),LPair.Value.Errors]));

    LSB.AppendLine('# HELP poseidon_request_duration_ms Histogram of request durations in ms');
    LSB.AppendLine('# TYPE poseidon_request_duration_ms histogram');
    for LPair in LPairs do
    begin
      for I := 0 to 7 do
        LSB.AppendLine(Format('poseidon_request_duration_ms_bucket{path="%s",le="%s"} %d',
          [EscapePromLabel(LPair.Key),CHistBoundsStr[I], LPair.Value.HistBuckets[I]]));
      LSB.AppendLine(Format('poseidon_request_duration_ms_bucket{path="%s",le="+Inf"} %d',
        [EscapePromLabel(LPair.Key),LPair.Value.HistBuckets[8]]));
      LSB.AppendLine(Format('poseidon_request_duration_ms_sum{path="%s"} %d',
        [EscapePromLabel(LPair.Key),LPair.Value.DurationSum]));
      LSB.AppendLine(Format('poseidon_request_duration_ms_count{path="%s"} %d',
        [EscapePromLabel(LPair.Key),LPair.Value.Requests]));
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
