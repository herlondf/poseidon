unit Poseidon.Tests.Metrics;

// Unit tests for TPoseidonMetrics (Poseidon.Net.Metrics).
//
// Covers:
//   - Counter increment via RecordRequest (all 5 status classes)
//   - Byte counters (Rx / Tx)
//   - Connection / in-flight gauges
//   - Uptime gauge presence in Render output
//   - Histogram: bucket counting, cumulative semantics, +Inf, sum, count
//   - Prometheus text format: HELP/TYPE headers, label syntax
//   - Thread-safety smoke test (10 threads x 100 requests each)

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TMetricsCounterTests = class
  private
    FMetrics: TObject; // TPoseidonMetrics — declared as TObject to avoid unit dep in header
    function Render: string;
    procedure Record1(AStatus: Integer; ADurationMs: Double;
      ARxBytes, ATxBytes: Int64);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure RecordRequest_200_Increments2xxCounter;
    [Test] procedure RecordRequest_404_Increments4xxCounter;
    [Test] procedure RecordRequest_500_Increments5xxCounter;
    [Test] procedure RecordRequest_301_Increments3xxCounter;
    [Test] procedure RecordRequest_101_Increments1xxCounter;
    [Test] procedure RecordRequest_AccumulatesMultipleCalls;
    [Test] procedure RecordRequest_UpdatesBytesRx;
    [Test] procedure RecordRequest_UpdatesBytesTx;
  end;

  [TestFixture]
  TMetricsGaugeTests = class
  private
    FMetrics: TObject;
    function Render: string;
    procedure AdjConn(ADelta: Integer);
    procedure AdjInflight(ADelta: Integer);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure AdjustConnections_PlusOne_RendersOne;
    [Test] procedure AdjustConnections_PlusThenMinus_RendersZero;
    [Test] procedure AdjustInflight_PlusTwo_RendersTwo;
    [Test] procedure UptimeSeconds_PresentInRender;
  end;

  [TestFixture]
  TMetricsHistogramTests = class
  private
    FMetrics: TObject;
    function Render: string;
    procedure Rec(ADurationMs: Double);
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Histogram_BucketCountsAreCumulative;
    [Test] procedure Histogram_InfBucketEqualsTotal;
    [Test] procedure Histogram_SumAccumulates;
    [Test] procedure Histogram_CountEqualsRequests;
    [Test] procedure Histogram_ZeroMs_FallsInSmallestBucket;
    [Test] procedure Histogram_OverLargestBound_OnlyInInf;
  end;

  [TestFixture]
  TMetricsFormatTests = class
  private
    FMetrics: TObject;
    function Render: string;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure Render_ContainsHelpAndTypeForRequestsTotal;
    [Test] procedure Render_ContainsHelpAndTypeForBytesReceived;
    [Test] procedure Render_ContainsHelpAndTypeForBytesSent;
    [Test] procedure Render_ContainsHelpAndTypeForConnectionsActive;
    [Test] procedure Render_ContainsHelpAndTypeForInflight;
    [Test] procedure Render_ContainsHelpAndTypeForHistogram;
    [Test] procedure Render_AllStatusLabelsPresent;
    [Test] procedure Render_HistogramLeLabels;
    [Test] procedure Render_HistogramPlusInfPresent;
  end;

  [TestFixture]
  TMetricsThreadSafetyTests = class
  private
    FMetrics: TObject;
    function Render: string;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure ConcurrentRecordRequest_NoDataRace;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Poseidon.Net.Metrics;

{ ── helpers shared by all fixtures ──────────────────────────────────────── }

// Each fixture keeps FMetrics as TObject and casts internally so the
// interface section stays free of Poseidon.Net.Metrics in the uses clause.

{ TMetricsCounterTests }

function TMetricsCounterTests.Render: string;
begin
  Result := TPoseidonMetrics(FMetrics).Render;
end;

procedure TMetricsCounterTests.Record1(AStatus: Integer; ADurationMs: Double;
  ARxBytes, ATxBytes: Int64);
begin
  TPoseidonMetrics(FMetrics).RecordRequest(AStatus, ADurationMs, ARxBytes, ATxBytes);
end;

procedure TMetricsCounterTests.Setup;
begin
  FMetrics := TPoseidonMetrics.Create;
end;

procedure TMetricsCounterTests.TearDown;
begin
  FMetrics.Free;
end;

procedure TMetricsCounterTests.RecordRequest_200_Increments2xxCounter;
var
  LOut: string;
begin
  Record1(200, 1.0, 100, 200);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_requests_total{status="2xx"} 1', LOut) > 0,
    'Expected 2xx counter = 1 in: ' + LOut);
end;

procedure TMetricsCounterTests.RecordRequest_404_Increments4xxCounter;
var
  LOut: string;
begin
  Record1(404, 2.0, 50, 300);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_requests_total{status="4xx"} 1', LOut) > 0,
    'Expected 4xx counter = 1 in: ' + LOut);
end;

procedure TMetricsCounterTests.RecordRequest_500_Increments5xxCounter;
var
  LOut: string;
begin
  Record1(500, 10.0, 80, 120);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_requests_total{status="5xx"} 1', LOut) > 0,
    'Expected 5xx counter = 1 in: ' + LOut);
end;

procedure TMetricsCounterTests.RecordRequest_301_Increments3xxCounter;
var
  LOut: string;
begin
  Record1(301, 0.5, 40, 80);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_requests_total{status="3xx"} 1', LOut) > 0,
    'Expected 3xx counter = 1 in: ' + LOut);
end;

procedure TMetricsCounterTests.RecordRequest_101_Increments1xxCounter;
var
  LOut: string;
begin
  Record1(101, 0.2, 20, 40);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_requests_total{status="1xx"} 1', LOut) > 0,
    'Expected 1xx counter = 1 in: ' + LOut);
end;

procedure TMetricsCounterTests.RecordRequest_AccumulatesMultipleCalls;
var
  LOut: string;
  I:    Integer;
begin
  for I := 1 to 5 do
    Record1(200, 1.0, 10, 20);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_requests_total{status="2xx"} 5', LOut) > 0,
    'Expected 2xx counter = 5 in: ' + LOut);
end;

procedure TMetricsCounterTests.RecordRequest_UpdatesBytesRx;
var
  LOut: string;
begin
  Record1(200, 1.0, 1024, 0);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_bytes_received_total 1024', LOut) > 0,
    'Expected bytes_received_total 1024 in: ' + LOut);
end;

procedure TMetricsCounterTests.RecordRequest_UpdatesBytesTx;
var
  LOut: string;
begin
  Record1(200, 1.0, 0, 2048);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_bytes_sent_total 2048', LOut) > 0,
    'Expected bytes_sent_total 2048 in: ' + LOut);
end;

{ TMetricsGaugeTests }

function TMetricsGaugeTests.Render: string;
begin
  Result := TPoseidonMetrics(FMetrics).Render;
end;

procedure TMetricsGaugeTests.AdjConn(ADelta: Integer);
begin
  TPoseidonMetrics(FMetrics).AdjustConnections(ADelta);
end;

procedure TMetricsGaugeTests.AdjInflight(ADelta: Integer);
begin
  TPoseidonMetrics(FMetrics).AdjustInflight(ADelta);
end;

procedure TMetricsGaugeTests.Setup;
begin
  FMetrics := TPoseidonMetrics.Create;
end;

procedure TMetricsGaugeTests.TearDown;
begin
  FMetrics.Free;
end;

procedure TMetricsGaugeTests.AdjustConnections_PlusOne_RendersOne;
var
  LOut: string;
begin
  AdjConn(1);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_connections_active 1', LOut) > 0,
    'Expected connections_active 1 in: ' + LOut);
end;

procedure TMetricsGaugeTests.AdjustConnections_PlusThenMinus_RendersZero;
var
  LOut: string;
begin
  AdjConn(1);
  AdjConn(-1);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_connections_active 0', LOut) > 0,
    'Expected connections_active 0 in: ' + LOut);
end;

procedure TMetricsGaugeTests.AdjustInflight_PlusTwo_RendersTwo;
var
  LOut: string;
begin
  AdjInflight(1);
  AdjInflight(1);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_requests_inflight 2', LOut) > 0,
    'Expected requests_inflight 2 in: ' + LOut);
end;

procedure TMetricsGaugeTests.UptimeSeconds_PresentInRender;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_uptime_seconds', LOut) > 0,
    'Expected poseidon_uptime_seconds in output');
end;

{ TMetricsHistogramTests }

function TMetricsHistogramTests.Render: string;
begin
  Result := TPoseidonMetrics(FMetrics).Render;
end;

procedure TMetricsHistogramTests.Rec(ADurationMs: Double);
begin
  TPoseidonMetrics(FMetrics).RecordRequest(200, ADurationMs, 0, 0);
end;

procedure TMetricsHistogramTests.Setup;
begin
  FMetrics := TPoseidonMetrics.Create;
end;

procedure TMetricsHistogramTests.TearDown;
begin
  FMetrics.Free;
end;

procedure TMetricsHistogramTests.Histogram_BucketCountsAreCumulative;
var
  LOut: string;
begin
  // 1 ms falls in le=1 and all higher buckets
  Rec(1.0);
  LOut := Render;
  // le="0.5" must be 0 (1ms > 0.5)
  Assert.IsTrue(Pos('le="0.5"} 0', LOut) > 0,
    'Expected le=0.5 bucket = 0');
  // le="1" must be 1 (1ms ≤ 1)
  Assert.IsTrue(Pos('le="1"} 1', LOut) > 0,
    'Expected le=1 bucket = 1');
  // le="5" must be 1 (cumulative)
  Assert.IsTrue(Pos('le="5"} 1', LOut) > 0,
    'Expected le=5 bucket = 1 (cumulative)');
end;

procedure TMetricsHistogramTests.Histogram_InfBucketEqualsTotal;
var
  LOut: string;
begin
  Rec(0.1);
  Rec(1.0);
  Rec(999.0);
  LOut := Render;
  Assert.IsTrue(Pos('le="+Inf"} 3', LOut) > 0,
    'Expected +Inf bucket = 3 in: ' + LOut);
end;

procedure TMetricsHistogramTests.Histogram_SumAccumulates;
var
  LOut: string;
begin
  Rec(10.0);
  Rec(20.0);
  // Sum should be 30.000
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_request_duration_ms_sum 30.', LOut) > 0,
    'Expected sum starting with 30. in: ' + LOut);
end;

procedure TMetricsHistogramTests.Histogram_CountEqualsRequests;
var
  LOut: string;
begin
  Rec(5.0);
  Rec(5.0);
  LOut := Render;
  Assert.IsTrue(Pos('poseidon_request_duration_ms_count 2', LOut) > 0,
    'Expected histogram count = 2 in: ' + LOut);
end;

procedure TMetricsHistogramTests.Histogram_ZeroMs_FallsInSmallestBucket;
var
  LOut: string;
begin
  Rec(0.0);
  LOut := Render;
  // 0 ms ≤ 0.5 ms → smallest bucket must be 1
  Assert.IsTrue(Pos('le="0.5"} 1', LOut) > 0,
    'Expected le=0.5 bucket = 1 for 0ms request');
end;

procedure TMetricsHistogramTests.Histogram_OverLargestBound_OnlyInInf;
var
  LOut: string;
begin
  // 6000ms > 5000ms (largest bound)
  Rec(6000.0);
  LOut := Render;
  // le="5000" must be 0
  Assert.IsTrue(Pos('le="5000"} 0', LOut) > 0,
    'Expected le=5000 bucket = 0 for 6000ms request');
  // +Inf must be 1
  Assert.IsTrue(Pos('le="+Inf"} 1', LOut) > 0,
    'Expected +Inf bucket = 1 for 6000ms request');
end;

{ TMetricsFormatTests }

function TMetricsFormatTests.Render: string;
begin
  Result := TPoseidonMetrics(FMetrics).Render;
end;

procedure TMetricsFormatTests.Setup;
begin
  FMetrics := TPoseidonMetrics.Create;
end;

procedure TMetricsFormatTests.TearDown;
begin
  FMetrics.Free;
end;

procedure TMetricsFormatTests.Render_ContainsHelpAndTypeForRequestsTotal;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('# HELP poseidon_requests_total', LOut) > 0);
  Assert.IsTrue(Pos('# TYPE poseidon_requests_total counter', LOut) > 0);
end;

procedure TMetricsFormatTests.Render_ContainsHelpAndTypeForBytesReceived;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('# HELP poseidon_bytes_received_total', LOut) > 0);
  Assert.IsTrue(Pos('# TYPE poseidon_bytes_received_total counter', LOut) > 0);
end;

procedure TMetricsFormatTests.Render_ContainsHelpAndTypeForBytesSent;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('# HELP poseidon_bytes_sent_total', LOut) > 0);
  Assert.IsTrue(Pos('# TYPE poseidon_bytes_sent_total counter', LOut) > 0);
end;

procedure TMetricsFormatTests.Render_ContainsHelpAndTypeForConnectionsActive;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('# HELP poseidon_connections_active', LOut) > 0);
  Assert.IsTrue(Pos('# TYPE poseidon_connections_active gauge', LOut) > 0);
end;

procedure TMetricsFormatTests.Render_ContainsHelpAndTypeForInflight;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('# HELP poseidon_requests_inflight', LOut) > 0);
  Assert.IsTrue(Pos('# TYPE poseidon_requests_inflight gauge', LOut) > 0);
end;

procedure TMetricsFormatTests.Render_ContainsHelpAndTypeForHistogram;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('# HELP poseidon_request_duration_ms_bucket', LOut) > 0);
  Assert.IsTrue(Pos('# TYPE poseidon_request_duration_ms_bucket histogram', LOut) > 0);
end;

procedure TMetricsFormatTests.Render_AllStatusLabelsPresent;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('status="1xx"', LOut) > 0, 'Missing 1xx label');
  Assert.IsTrue(Pos('status="2xx"', LOut) > 0, 'Missing 2xx label');
  Assert.IsTrue(Pos('status="3xx"', LOut) > 0, 'Missing 3xx label');
  Assert.IsTrue(Pos('status="4xx"', LOut) > 0, 'Missing 4xx label');
  Assert.IsTrue(Pos('status="5xx"', LOut) > 0, 'Missing 5xx label');
end;

procedure TMetricsFormatTests.Render_HistogramLeLabels;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('le="0.5"',  LOut) > 0, 'Missing le=0.5');
  Assert.IsTrue(Pos('le="1"',    LOut) > 0, 'Missing le=1');
  Assert.IsTrue(Pos('le="5"',    LOut) > 0, 'Missing le=5');
  Assert.IsTrue(Pos('le="1000"', LOut) > 0, 'Missing le=1000');
  Assert.IsTrue(Pos('le="5000"', LOut) > 0, 'Missing le=5000');
end;

procedure TMetricsFormatTests.Render_HistogramPlusInfPresent;
var
  LOut: string;
begin
  LOut := Render;
  Assert.IsTrue(Pos('le="+Inf"', LOut) > 0, 'Missing le=+Inf');
end;

{ TMetricsThreadSafetyTests }

function TMetricsThreadSafetyTests.Render: string;
begin
  Result := TPoseidonMetrics(FMetrics).Render;
end;

procedure TMetricsThreadSafetyTests.Setup;
begin
  FMetrics := TPoseidonMetrics.Create;
end;

procedure TMetricsThreadSafetyTests.TearDown;
begin
  FMetrics.Free;
end;

procedure TMetricsThreadSafetyTests.ConcurrentRecordRequest_NoDataRace;
const
  THREADS = 10;
  REQUESTS_PER_THREAD = 100;
var
  LMetrics:  TPoseidonMetrics;
  LThreads:  array[0..THREADS - 1] of TThread;
  I:         Integer;
  LOut:      string;
begin
  LMetrics := TPoseidonMetrics(FMetrics);

  for I := 0 to THREADS - 1 do
  begin
    LThreads[I] := TThread.CreateAnonymousThread(
      procedure
      var
        J: Integer;
      begin
        for J := 1 to REQUESTS_PER_THREAD do
          LMetrics.RecordRequest(200, J * 0.5, J * 10, J * 20);
      end);
    LThreads[I].FreeOnTerminate := False;
    LThreads[I].Start;
  end;

  for I := 0 to THREADS - 1 do
  begin
    LThreads[I].WaitFor;
    LThreads[I].Free;
  end;

  LOut := Render;
  // Total 2xx = THREADS * REQUESTS_PER_THREAD = 1000
  Assert.IsTrue(
    Pos('poseidon_requests_total{status="2xx"} 1000', LOut) > 0,
    'Expected 2xx = 1000 after concurrent writes; got: ' + LOut);

  // +Inf bucket = THREADS * REQUESTS_PER_THREAD = 1000
  Assert.IsTrue(
    Pos('le="+Inf"} 1000', LOut) > 0,
    'Expected +Inf = 1000 after concurrent writes');
end;

initialization
  TDUnitX.RegisterTestFixture(TMetricsCounterTests);
  TDUnitX.RegisterTestFixture(TMetricsGaugeTests);
  TDUnitX.RegisterTestFixture(TMetricsHistogramTests);
  TDUnitX.RegisterTestFixture(TMetricsFormatTests);
  TDUnitX.RegisterTestFixture(TMetricsThreadSafetyTests);

end.
