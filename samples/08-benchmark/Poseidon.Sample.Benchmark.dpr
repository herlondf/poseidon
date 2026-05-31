program Poseidon.Sample.Benchmark;

// Sample 08 — HTTP/1.1 Throughput Benchmark
//
// Roda dois cenários contra um servidor Poseidon local e imprime uma tabela de
// resultados no console, além de gerar um relatório HTML no diretório do executável.
//
//   Cenário A — keep-alive (conexões persistentes)
//     WORKERS workers, cada um fazendo REPS_KEEPALIVE requests sequenciais numa
//     única conexão persistente (Connection: keep-alive).
//
//   Cenário B — nova conexão por request
//     WORKERS workers, cada um fazendo REPS_NEWCONN requests com um novo socket
//     TCP por request (Connection: close).
//
// Métricas por request: latência wall-clock via TStopwatch.
// Agregados: throughput (req/s), Avg / P50 / P95 / P99 / Min / Max (ms).
// Relatório: HTML com tema escuro e gráficos Chart.js — poseidon-sample-bench.html
//
// io_uring vs epoll
// ─────────────────
// No Linux, o Poseidon seleciona io_uring (kernel ≥ 5.1) ou epoll como fallback.
// Para comparar os dois backends, execute este benchmark em hosts com kernels
// diferentes. O benchmark em si é agnóstico ao backend.
//
// Uso: Poseidon.Sample.Benchmark.exe

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
  Poseidon.Net.HttpServer,
  Poseidon.Sample.BenchReport;

const
  BENCH_PORT      = 9090;
  BENCH_HOST      = '127.0.0.1';
  WORKERS         = 50;
  REPS_KEEPALIVE  = 1000;  // requests por worker — cenário keep-alive
  REPS_NEWCONN    = 200;   // requests por worker — cenário nova conexão
  REPORT_FILE     = 'poseidon-sample-bench.html';

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

// Lê até encontrar o fim dos headers HTTP/1.1 (duplo CRLF).
function RecvResponse(ASocket: TSocket; out AOut: TBytes): Boolean;
var
  LBuf: TBytes;  // TBytes required by TEncoding.GetString overload
  LRcv: Integer;
  LStr: string;
begin
  Result := False;
  SetLength(AOut, 0);
  SetLength(LBuf, 8192);
  repeat
    LRcv := recv(ASocket, LBuf[0], Length(LBuf), 0);
    if LRcv <= 0 then Exit;
    LStr := TEncoding.ASCII.GetString(LBuf, 0, LRcv);
    SetLength(AOut, Length(AOut) + LRcv);
    Move(LBuf[0], AOut[Length(AOut) - LRcv], LRcv);
    if Pos(#13#10#13#10, LStr) > 0 then
      Exit(True);
  until False;
end;

// ─── Cenário A — keep-alive ──────────────────────────────────────────────────

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

// ─── Cenário B — nova conexão por request ────────────────────────────────────

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

// ─── Estatísticas ─────────────────────────────────────────────────────────────

// Computa todas as métricas a partir dos array de latências brutas.
function BuildResult(
  const AName:    string;
  const AAll:     TArray<Double>;
  AWallMs:        Double;
  AWorkers:       Integer): TSampleScenarioResult;
var
  LSorted: TArray<Double>;
  LTotal:  Integer;
  LSum:    Double;
  LV:      Double;
begin
  Result := Default(TSampleScenarioResult);
  LTotal := Length(AAll);

  Result.Name    := AName;
  Result.Workers := AWorkers;
  Result.WallMs  := AWallMs;
  Result.TotalRequests := LTotal;

  if LTotal = 0 then Exit;

  Result.RepsPerWorker := LTotal div Max(1, AWorkers);
  Result.RPS           := LTotal / (AWallMs / 1000.0);

  LSum := 0;
  for LV in AAll do LSum := LSum + LV;
  Result.AvgMs := LSum / LTotal;

  LSorted := Copy(AAll, 0, LTotal);
  TArray.Sort<Double>(LSorted);

  Result.MinMs := LSorted[0];
  Result.MaxMs := LSorted[High(LSorted)];
  Result.P50   := LSorted[Max(0, Trunc(LTotal * 0.50))];
  Result.P95   := LSorted[Max(0, Min(Trunc(LTotal * 0.95), LTotal - 1))];
  Result.P99   := LSorted[Max(0, Min(Trunc(LTotal * 0.99), LTotal - 1))];
end;

procedure PrintResult(const R: TSampleScenarioResult);
begin
  if R.TotalRequests = 0 then
  begin
    Writeln(R.Name + ': sem dados');
    Exit;
  end;
  Writeln(Format('%-40s  %6d req   %7.0f req/s   P50=%5.2f ms   P99=%6.2f ms',
    [R.Name, R.TotalRequests, R.RPS, R.P50, R.P99]));
end;

// ─── Executor de cenário ──────────────────────────────────────────────────────

// Helper: captura o índice do worker por valor num frame separado.
// 'var LIdx := I' dentro de um loop não garante lifting por-iteração em todas
// as versões do Delphi — uma função auxiliar resolve isso.
function SpawnTask(
  AIdx:            Integer;
  AResults:        TArray<TArray<Double>>;
  const AWorkerFn: TFunc<TArray<Double>>): ITask;
begin
  Result := TTask.Run(
    procedure
    begin
      AResults[AIdx] := AWorkerFn();
    end);
end;

function RunScenario(
  const AName:      string;
  AWorkerCount:     Integer;
  AWorkerFn:        TFunc<TArray<Double>>): TSampleScenarioResult;
var
  LTasks:   TArray<ITask>;
  LResults: TArray<TArray<Double>>;
  LAll:     TArray<Double>;
  LPos:     Integer;
  I, J:     Integer;
  LWall:    TStopwatch;
  LTotal:   Integer;
begin
  Write(Format('Executando %-40s ... ', [AName]));
  Flush(Output);

  SetLength(LTasks,   AWorkerCount);
  SetLength(LResults, AWorkerCount);

  LWall := TStopwatch.StartNew;
  for I := 0 to AWorkerCount - 1 do
    LTasks[I] := SpawnTask(I, LResults, AWorkerFn);
  TTask.WaitForAll(LTasks, 120000);
  LWall.Stop;

  // Achata os arrays por worker
  LTotal := 0;
  for I := 0 to AWorkerCount - 1 do Inc(LTotal, Length(LResults[I]));
  SetLength(LAll, LTotal);
  LPos := 0;
  for I := 0 to AWorkerCount - 1 do
    for J := 0 to Length(LResults[I]) - 1 do
    begin
      LAll[LPos] := LResults[I][J];
      Inc(LPos);
    end;

  Writeln('concluído');
  Result := BuildResult(AName, LAll, LWall.Elapsed.TotalMilliseconds, AWorkerCount);
  PrintResult(Result);
end;

// ─── Main ─────────────────────────────────────────────────────────────────────

var
  GServer: TPoseidonNativeServer;
  GReady:  TEvent;

procedure OnListenReady;
begin
  GReady.SetEvent;
end;

procedure ServerThread;
begin
  GServer.Listen(BENCH_HOST, BENCH_PORT, BenchHandler, OnListenReady);
end;

var
  LWSAData:    TWSAData;
  LResultA:    TSampleScenarioResult;
  LResultB:    TSampleScenarioResult;
  LReport:     TSampleBenchReport;
  LMachine:    string;
  LReportPath: string;
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
        Writeln('ERRO: servidor não iniciou em 5 s');
        Exit;
      end;

      Writeln('Poseidon Sample 08 — Benchmark de Throughput HTTP/1.1');
      Writeln(Format('Servidor: %s:%d   Workers: %d',
        [BENCH_HOST, BENCH_PORT, GServer.WorkerCount]));
      Writeln(StringOfChar('-', 78));
      Writeln(Format('%-40s  %9s   %12s   %14s   %14s',
        ['Cenário', 'Requests', 'Throughput', 'P50 Latência', 'P99 Latência']));
      Writeln(StringOfChar('-', 78));

      LResultA := RunScenario(
        Format('A: keep-alive (%dx%d)', [WORKERS, REPS_KEEPALIVE]),
        WORKERS,
        function: TArray<Double>
        begin
          Result := RunWorkerKeepAlive;
        end);

      LResultB := RunScenario(
        Format('B: nova-conn (%dx%d)', [WORKERS, REPS_NEWCONN]),
        WORKERS,
        function: TArray<Double>
        begin
          Result := RunWorkerNewConn;
        end);

      Writeln(StringOfChar('-', 78));
      Writeln;

      // ── Gerar relatório HTML ───────────────────────────────────────────────

      LMachine := GetEnvironmentVariable('COMPUTERNAME');   // Windows
      if LMachine = '' then LMachine := GetEnvironmentVariable('HOSTNAME'); // Linux
      if LMachine = '' then LMachine := 'localhost';

      LReportPath := ExtractFilePath(ParamStr(0)) + REPORT_FILE;

      LReport := TSampleBenchReport.Create(
        [LResultA, LResultB],
        LMachine, Now,
        'Poseidon HTTP/1.1 &mdash; Keep-Alive vs Nova Conex&atilde;o');
      try
        LReport.SaveToFile(LReportPath);
        Writeln(Format('Relatório HTML gerado: %s', [LReportPath]));
      finally
        LReport.Free;
      end;

      Writeln;
      Writeln('Notas:');
      Writeln('  - Linux: io_uring selecionado automaticamente em kernel >= 5.1;');
      Writeln('    epoll em kernels mais antigos. Execute nos dois para comparar.');
      Writeln('  - HTTP/2 requer TLS+ALPN. Veja samples/04-http2 e use nghttp2.');

      GServer.Stop;
    finally
      GServer.Free;
      GReady.Free;
    end;
  finally
    WSACleanup;
  end;
end.
