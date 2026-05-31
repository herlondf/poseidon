program Poseidon.Sample.Benchmark;

// Sample 08 — HTTP/1.1 Throughput Benchmark
//
// Runs two scenarios against a local Poseidon server and prints a results table.
//
//   Scenario A — keep-alive (persistent connections)
//     WORKERS workers, each making REPS_KEEPALIVE sequential GET requests on
//     a single persistent connection (Connection: keep-alive).
//
//   Scenario B — new connection per request
//     WORKERS workers, each making REPS_NEWCONN requests with a fresh TCP
//     connection per request (Connection: close).
//
// Measurements per request: wall-clock latency via TStopwatch.
// Aggregates: throughput (req/s), P50 / P99 latency (ms).
//
// io_uring vs epoll note
// ─────────────────────
// On Linux, Poseidon auto-selects io_uring (kernel ≥ 5.1) or epoll as fallback.
// To compare both back-ends, run this benchmark on:
//   • A host with kernel ≥ 5.1  → io_uring path
//   • A host with kernel < 5.1  → epoll path
// The benchmark itself is back-end agnostic; the server chooses at startup.
//
// HTTP/2 note
// ───────────
// HTTP/2 benefit is visible when many streams share a single TLS connection.
// See samples/04-http2 for the HTTP/2 server setup; benchmark it by replacing
// the server in this program with HTTP2Enabled := True and using an HTTP/2
// client library (e.g. libcurl with ALPN, or nghttp2).
//
// Usage: Poseidon.Sample.Benchmark.exe

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.Classes,
  System.Diagnostics,
  System.Threading,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.Math,
  Winapi.Winsock2,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer;

const
  BENCH_PORT      = 9090;
  BENCH_HOST      = '127.0.0.1';
  WORKERS         = 50;
  REPS_KEEPALIVE  = 1000;  // requests per worker — keep-alive scenario
  REPS_NEWCONN    = 200;   // requests per worker — new-connection scenario

// ─── HTTP handler ─────────────────────────────────────────────────────────────

procedure BenchHandler(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
begin
  AStatus       := 200;
  AContentType  := 'application/json';
  ABody         := TEncoding.UTF8.GetBytes('{"ok":true}');
  AExtraHeaders := [];
end;

// ─── Raw TCP helpers ──────────────────────────────────────────────────────────

function OpenSocket: TSocket;
var
  LAddr: TSockAddrIn;
begin
  Result := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if Result = INVALID_SOCKET then Exit;
  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family      := AF_INET;
  LAddr.sin_port        := htons(BENCH_PORT);
  LAddr.sin_addr.S_addr := inet_addr(BENCH_HOST);
  if connect(Result, TSockAddr(LAddr), SizeOf(LAddr)) <> 0 then
  begin
    closesocket(Result);
    Result := INVALID_SOCKET;
  end;
end;

function SendAll(ASocket: TSocket; const ABuf: TBytes): Boolean;
var
  LTotal, LSent, LRem: Integer;
begin
  LTotal := 0;
  LRem   := Length(ABuf);
  while LRem > 0 do
  begin
    LSent := send(ASocket, ABuf[LTotal], LRem, 0);
    if LSent <= 0 then Exit(False);
    Inc(LTotal, LSent);
    Dec(LRem, LSent);
  end;
  Result := True;
end;

// Read until we find the end of HTTP/1.1 headers (double CRLF).
// Returns True when found; fills AOut with everything received so far.
function RecvResponse(ASocket: TSocket; out AOut: TBytes): Boolean;
var
  LBuf: array[0..8191] of Byte;
  LRcv: Integer;
  LStr: string;
begin
  Result := False;
  SetLength(AOut, 0);
  repeat
    LRcv := recv(ASocket, LBuf[0], SizeOf(LBuf), 0);
    if LRcv <= 0 then Exit;
    LStr := TEncoding.ASCII.GetString(LBuf, 0, LRcv);
    SetLength(AOut, Length(AOut) + LRcv);
    Move(LBuf[0], AOut[Length(AOut) - LRcv], LRcv);
    if Pos(#13#10#13#10, LStr) > 0 then
      Exit(True);
  until False;
end;

// ─── Scenario A — keep-alive ──────────────────────────────────────────────────

// Each worker opens one connection and fires REPS_KEEPALIVE sequential requests.
// Returns array of per-request latencies in milliseconds.
function RunWorkerKeepAlive: TArray<Double>;
var
  LSock:   TSocket;
  LReq:    TBytes;
  LResp:   TBytes;
  LSW:     TStopwatch;
  I:       Integer;
begin
  SetLength(Result, REPS_KEEPALIVE);
  LSock := OpenSocket;
  if LSock = INVALID_SOCKET then Exit;
  try
    LReq := TEncoding.ASCII.GetBytes(
      'GET /ping HTTP/1.1'#13#10 +
      'Host: ' + BENCH_HOST + #13#10 +
      'Connection: keep-alive'#13#10#13#10);
    for I := 0 to REPS_KEEPALIVE - 1 do
    begin
      LSW := TStopwatch.StartNew;
      if not SendAll(LSock, LReq) then Break;
      if not RecvResponse(LSock, LResp) then Break;
      LSW.Stop;
      Result[I] := LSW.Elapsed.TotalMilliseconds;
    end;
  finally
    closesocket(LSock);
  end;
end;

// ─── Scenario B — new connection per request ─────────────────────────────────

function RunWorkerNewConn: TArray<Double>;
var
  LSock:   TSocket;
  LReq:    TBytes;
  LResp:   TBytes;
  LSW:     TStopwatch;
  I:       Integer;
begin
  SetLength(Result, REPS_NEWCONN);
  LReq := TEncoding.ASCII.GetBytes(
    'GET /ping HTTP/1.1'#13#10 +
    'Host: ' + BENCH_HOST + #13#10 +
    'Connection: close'#13#10#13#10);
  for I := 0 to REPS_NEWCONN - 1 do
  begin
    LSock := OpenSocket;
    if LSock = INVALID_SOCKET then Continue;
    LSW := TStopwatch.StartNew;
    SendAll(LSock, LReq);
    RecvResponse(LSock, LResp);
    LSW.Stop;
    closesocket(LSock);
    Result[I] := LSW.Elapsed.TotalMilliseconds;
  end;
end;

// ─── Statistics ───────────────────────────────────────────────────────────────

procedure PrintStats(const AScenarioName: string; const AAllLatencies: TArray<Double>;
  AWallMs: Double);
var
  LSorted: TArray<Double>;
  P50, P99: Double;
  I:        Integer;
  LTotal:   Integer;
begin
  LTotal := Length(AAllLatencies);
  if LTotal = 0 then
  begin
    Writeln(AScenarioName, ': no data');
    Exit;
  end;

  LSorted := Copy(AAllLatencies, 0, LTotal);
  TArray.Sort<Double>(LSorted);

  P50 := LSorted[Trunc(LTotal * 0.50)];
  P99 := LSorted[Trunc(LTotal * 0.99)];

  Writeln(Format('%-30s  %6d req   %7.0f req/s   P50=%5.2f ms   P99=%6.2f ms',
    [AScenarioName,
     LTotal,
     LTotal / (AWallMs / 1000.0),
     P50, P99]));
end;

// ─── Run one scenario ─────────────────────────────────────────────────────────

procedure RunScenario(const AName: string; AWorkerCount: Integer;
  AWorkerFn: TFunc<TArray<Double>>);
var
  LTasks:    TArray<ITask>;
  LResults:  TArray<TArray<Double>>;
  LAll:      TArray<Double>;
  LPos:      Integer;
  I, J:      Integer;
  LWall:     TStopwatch;
  LTotal:    Integer;
begin
  Write(Format('Running %-30s ... ', [AName]));
  Flush(Output);

  SetLength(LTasks,   AWorkerCount);
  SetLength(LResults, AWorkerCount);

  LWall := TStopwatch.StartNew;

  for I := 0 to AWorkerCount - 1 do
  begin
    var LIdx := I;
    LTasks[I] := TTask.Run(
      procedure
      begin
        LResults[LIdx] := AWorkerFn();
      end);
  end;

  TTask.WaitForAll(LTasks, 120000);
  LWall.Stop;

  // Flatten
  LTotal := 0;
  for I := 0 to AWorkerCount - 1 do
    Inc(LTotal, Length(LResults[I]));

  SetLength(LAll, LTotal);
  LPos := 0;
  for I := 0 to AWorkerCount - 1 do
    for J := 0 to Length(LResults[I]) - 1 do
    begin
      LAll[LPos] := LResults[I][J];
      Inc(LPos);
    end;

  Writeln('done');
  PrintStats(AName, LAll, LWall.Elapsed.TotalMilliseconds);
end;

// ─── Main ─────────────────────────────────────────────────────────────────────

var
  GServer:  TPoseidonNativeServer;
  GReady:   TEvent;

procedure OnListenReady;
begin
  GReady.SetEvent;
end;

procedure ServerThread;
begin
  GServer.Listen(BENCH_HOST, BENCH_PORT, BenchHandler, OnListenReady);
end;

var
  LWSAData: TWSAData;
begin
  WSAStartup($0202, LWSAData);
  try
    GReady  := TEvent.Create(nil, True, False, '');
    GServer := TPoseidonNativeServer.Create;
    try
      GServer.WorkerCount := 200;

      TThread.CreateAnonymousThread(ServerThread).Start;

      if GReady.WaitFor(5000) <> TWaitResult.wrSignaled then
      begin
        Writeln('ERROR: server did not start within 5 s');
        Exit;
      end;

      Writeln('Poseidon Sample 08 — HTTP/1.1 Throughput Benchmark');
      Writeln(Format('Server: %s:%d   Workers: %d', [BENCH_HOST, BENCH_PORT, GServer.WorkerCount]));
      Writeln(StringOfChar('-', 78));
      Writeln(Format('%-30s  %9s   %12s   %14s   %14s',
        ['Scenario', 'Requests', 'Throughput', 'P50 Latency', 'P99 Latency']));
      Writeln(StringOfChar('-', 78));

      RunScenario(
        Format('A: keep-alive (%dx%d)', [WORKERS, REPS_KEEPALIVE]),
        WORKERS,
        function: TArray<Double>
        begin
          Result := RunWorkerKeepAlive;
        end);

      RunScenario(
        Format('B: new-conn (%dx%d)', [WORKERS, REPS_NEWCONN]),
        WORKERS,
        function: TArray<Double>
        begin
          Result := RunWorkerNewConn;
        end);

      Writeln(StringOfChar('-', 78));
      Writeln;
      Writeln('Notes:');
      Writeln('  - Linux: io_uring used automatically on kernel >= 5.1; epoll on older kernels.');
      Writeln('    Run on both kernel versions and compare to measure io_uring benefit.');
      Writeln('  - HTTP/2 requires TLS+ALPN. See samples/04-http2 and use an HTTP/2 client');
      Writeln('    (e.g. nghttp2) to benchmark HTTP/2 throughput.');

      GServer.Stop;
    finally
      GServer.Free;
      GReady.Free;
    end;
  finally
    WSACleanup;
  end;
end.
