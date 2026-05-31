unit Poseidon.Net.Metrics;

// Prometheus-compatible metrics endpoint for TPoseidonNativeServer.
//
// Exposes counters, gauges and a latency histogram in Prometheus exposition
// format 0.0.4 (text/plain).  No external dependencies — the format is plain
// text and serialisation is done with a TStringBuilder.
//
// Thread-safety:
//   Counters / gauges   — TInterlocked (lock-free on all platforms)
//   Histogram buckets   — TCriticalSection (updated once per request)
//
// Usage:
//   Server.MetricsEnabled := True;
//   Server.MetricsPath    := '/metrics';          // default
//   Server.MetricsAllowedCIDR := '10.0.0.0/8';   // optional IP restriction
//
// Scrape:
//   GET /metrics  →  Content-Type: text/plain; version=0.0.4

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Math;

type
  TPoseidonMetrics = class
  private const
    // Latency histogram upper bounds in milliseconds (le= labels)
    BUCKET_COUNT = 11;
    BUCKETS: array[0..BUCKET_COUNT - 1] of Double = (
      0.5, 1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000
    );

  private
    // --- Counters (TInterlocked, monotonically increasing) ---
    FReqTotal:    array of Int64;  // indexed by status class (0=1xx,1=2xx,2=3xx,3=4xx,4=5xx)
    FBytesRx:     Int64;
    FBytesTx:     Int64;

    // --- Gauges ---
    FConnsActive: Int64;
    FInflight:    Int64;

    // --- Uptime ---
    FStartTick:   Int64;           // TThread.GetTickCount64 at Create

    // --- Histogram (protected by FHistLock) ---
    FHistLock:    TCriticalSection;
    FHistBuckets: array[0..BUCKET_COUNT - 1] of Int64;  // cumulative counts per bucket
    FHistInf:     Int64;           // +Inf bucket (= total request count)
    FHistSum:     Double;          // sum of durations in ms
    FHistCount:   Int64;           // total observations

    function StatusClass(AStatus: Integer): Integer; inline;
    function UptimeSeconds: Int64;
    function RenderHistogram(const ASB: TStringBuilder): TStringBuilder;
  public
    constructor Create;
    destructor  Destroy; override;

    // Called by the server after each completed request.
    // AStatus: HTTP status code. ADurationMs: handler wall-clock time in ms.
    // ARxBytes / ATxBytes: bytes received / sent for this request.
    procedure RecordRequest(AStatus: Integer; ADurationMs: Double;
      ARxBytes, ATxBytes: Int64);

    // Called when a connection is accepted (+1) or closed (-1).
    procedure AdjustConnections(ADelta: Integer);

    // Called when a request enters (+1) or leaves (-1) in-flight state.
    procedure AdjustInflight(ADelta: Integer);

    // Serialises all metrics to Prometheus exposition format 0.0.4.
    function Render: string;
  end;

implementation

uses
  System.Classes;

{ TPoseidonMetrics }

constructor TPoseidonMetrics.Create;
begin
  inherited Create;
  SetLength(FReqTotal, 5);
  FHistLock  := TCriticalSection.Create;
  FStartTick := TThread.GetTickCount64;
end;

destructor TPoseidonMetrics.Destroy;
begin
  FHistLock.Free;
  inherited Destroy;
end;

function TPoseidonMetrics.StatusClass(AStatus: Integer): Integer;
begin
  Result := EnsureRange((AStatus div 100) - 1, 0, 4);
end;

function TPoseidonMetrics.UptimeSeconds: Int64;
begin
  Result := (Int64(TThread.GetTickCount64) - FStartTick) div 1000;
end;

procedure TPoseidonMetrics.RecordRequest(AStatus: Integer; ADurationMs: Double;
  ARxBytes, ATxBytes: Int64);
var
  I: Integer;
begin
  TInterlocked.Increment(FReqTotal[StatusClass(AStatus)]);
  TInterlocked.Add(FBytesRx, ARxBytes);
  TInterlocked.Add(FBytesTx, ATxBytes);

  FHistLock.Enter;
  try
    for I := 0 to BUCKET_COUNT - 1 do
      if ADurationMs <= BUCKETS[I] then
        Inc(FHistBuckets[I]);
    Inc(FHistInf);
    FHistSum   := FHistSum + ADurationMs;
    Inc(FHistCount);
  finally
    FHistLock.Leave;
  end;
end;

procedure TPoseidonMetrics.AdjustConnections(ADelta: Integer);
begin
  TInterlocked.Add(FConnsActive, ADelta);
end;

procedure TPoseidonMetrics.AdjustInflight(ADelta: Integer);
begin
  TInterlocked.Add(FInflight, ADelta);
end;

function TPoseidonMetrics.RenderHistogram(const ASB: TStringBuilder): TStringBuilder;
var
  I:         Integer;
  LBuckets:  array[0..BUCKET_COUNT - 1] of Int64;
  LInf:      Int64;
  LSum:      Double;
  LCount:    Int64;
  LBoundStr: string;
begin
  // Snapshot under lock
  FHistLock.Enter;
  try
    for I := 0 to BUCKET_COUNT - 1 do
      LBuckets[I] := FHistBuckets[I];
    LInf   := FHistInf;
    LSum   := FHistSum;
    LCount := FHistCount;
  finally
    FHistLock.Leave;
  end;

  ASB.AppendLine('# HELP poseidon_request_duration_ms_bucket Request latency histogram (ms)');
  ASB.AppendLine('# TYPE poseidon_request_duration_ms_bucket histogram');

  for I := 0 to BUCKET_COUNT - 1 do
  begin
    // Format bucket bound: drop trailing zeros (0.5 → "0.5", 1 → "1", 100 → "100")
    if Frac(BUCKETS[I]) = 0 then
      LBoundStr := IntToStr(Trunc(BUCKETS[I]))
    else
      LBoundStr := FloatToStrF(BUCKETS[I], ffFixed, 15, 1);
    ASB.AppendFormat(
      'poseidon_request_duration_ms_bucket{le="%s"} %d', [LBoundStr, LBuckets[I]]);
    ASB.AppendLine;
  end;

  ASB.AppendFormat(
    'poseidon_request_duration_ms_bucket{le="+Inf"} %d', [LInf]);
  ASB.AppendLine;
  ASB.AppendFormat(
    'poseidon_request_duration_ms_sum %s',
    [FloatToStrF(LSum, ffFixed, 15, 3)]);
  ASB.AppendLine;
  ASB.AppendFormat(
    'poseidon_request_duration_ms_count %d', [LCount]);
  ASB.AppendLine;

  Result := ASB;
end;

function TPoseidonMetrics.Render: string;
const
  STATUS_LABELS: array[0..4] of string = ('1xx','2xx','3xx','4xx','5xx');
var
  LSB:    TStringBuilder;
  I:      Integer;
  LCount: Int64;
begin
  LSB := TStringBuilder.Create;
  try
    // --- poseidon_requests_total ---
    LSB.AppendLine('# HELP poseidon_requests_total Total HTTP requests by status class');
    LSB.AppendLine('# TYPE poseidon_requests_total counter');
    for I := 0 to 4 do
    begin
      LCount := TInterlocked.Read(FReqTotal[I]);
      LSB.AppendFormat(
        'poseidon_requests_total{status="%s"} %d', [STATUS_LABELS[I], LCount]);
      LSB.AppendLine;
    end;

    // --- poseidon_bytes_received_total ---
    LSB.AppendLine('# HELP poseidon_bytes_received_total Total bytes received from clients');
    LSB.AppendLine('# TYPE poseidon_bytes_received_total counter');
    LSB.AppendFormat(
      'poseidon_bytes_received_total %d', [TInterlocked.Read(FBytesRx)]);
    LSB.AppendLine;

    // --- poseidon_bytes_sent_total ---
    LSB.AppendLine('# HELP poseidon_bytes_sent_total Total bytes sent to clients');
    LSB.AppendLine('# TYPE poseidon_bytes_sent_total counter');
    LSB.AppendFormat(
      'poseidon_bytes_sent_total %d', [TInterlocked.Read(FBytesTx)]);
    LSB.AppendLine;

    // --- poseidon_connections_active ---
    LSB.AppendLine('# HELP poseidon_connections_active Currently open TCP connections');
    LSB.AppendLine('# TYPE poseidon_connections_active gauge');
    LSB.AppendFormat(
      'poseidon_connections_active %d', [TInterlocked.Read(FConnsActive)]);
    LSB.AppendLine;

    // --- poseidon_requests_inflight ---
    LSB.AppendLine('# HELP poseidon_requests_inflight Requests currently being processed');
    LSB.AppendLine('# TYPE poseidon_requests_inflight gauge');
    LSB.AppendFormat(
      'poseidon_requests_inflight %d', [TInterlocked.Read(FInflight)]);
    LSB.AppendLine;

    // --- poseidon_uptime_seconds ---
    LSB.AppendLine('# HELP poseidon_uptime_seconds Seconds since server started');
    LSB.AppendLine('# TYPE poseidon_uptime_seconds gauge');
    LSB.AppendFormat(
      'poseidon_uptime_seconds %d', [UptimeSeconds]);
    LSB.AppendLine;

    // --- latency histogram ---
    RenderHistogram(LSB);

    Result := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

end.
