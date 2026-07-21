program Poseidon.Sample.MetricsDashboard;

// Sample 10 — Real-time Metrics Dashboard (issue #47)
// Wires the Prometheus MetricsMiddleware and serves the Chart.js dashboard
// (public/dashboard.html) from the server itself — no external service.
//
// Covers: MetricsMiddleware (/metrics), StaticMiddleware (dashboard), demo
// routes with varied latency and occasional errors so the charts move.
//
// Run:
//   Poseidon.Sample.MetricsDashboard.exe
//   Open http://localhost:9001/dashboard/dashboard.html
//   Generate traffic (another shell):
//     for /L %i in (1,1,100000) do curl -s http://localhost:9001/api/report >nul

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.IOUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Middleware.Metrics,
  Poseidon.Middleware.Static;

const
  CDefaultPort = 9001;

function ServerPort: Integer;
var
  LEnv: string;
begin
  // Port resolution: arg 1, else POSEIDON_PORT env, else default (9001).
  Result := CDefaultPort;
  if ParamCount >= 1 then
  begin
    if TryStrToInt(ParamStr(1), Result) then
      Exit;
    Result := CDefaultPort;
  end;
  LEnv := GetEnvironmentVariable('POSEIDON_PORT');
  if (LEnv <> '') and TryStrToInt(LEnv, Result) then
    Exit;
  Result := CDefaultPort;
end;

function PublicDir: string;
begin
  // Resolve public/ relative to the executable (bin\<Config>\ -> up two).
  Result := TPath.GetFullPath(
    TPath.Combine(ExtractFilePath(ParamStr(0)), '..' + PathDelim + '..' + PathDelim + 'public'));
  if not TDirectory.Exists(Result) then
    Result := TPath.Combine(TDirectory.GetCurrentDirectory, 'public');
end;

var
  App: TPoseidonServer;
  LPublic: string;
  LPort: Integer;
begin
  Randomize;
  LPublic := PublicDir;
  LPort := ServerPort;

  App := TPoseidonServer.Create;
  try
    // 1. Expose Prometheus metrics at /metrics (the dashboard polls this).
    App.Use(MetricsMiddleware('/metrics'));
    // 2. Serve the dashboard page from public/ at /dashboard/*.
    App.Use(StaticMiddleware('/dashboard', LPublic));

    // Demo routes — varied cost so RPS / latency / error-rate charts are alive.
    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"message":"pong"}');
      end);

    App.Get('/api/users/:id',
      procedure(var Ctx: TNativeRequestContext)
      var
        LId: string;
      begin
        LId := Ctx.Param('id');
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"id":"' + LId + '","name":"user-' + LId + '"}');
      end);

    App.Get('/api/report',
      procedure(var Ctx: TNativeRequestContext)
      begin
        // Simulated variable work: a slower endpoint feeds the p95/p99 tail.
        Sleep(5 + Random(60));
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"report":"ok","rows":' + IntToStr(100 + Random(900)) + '}');
      end);

    App.Get('/api/flaky',
      procedure(var Ctx: TNativeRequestContext)
      begin
        // ~1 in 12 requests errors — drives the error-rate chart.
        if Random(12) = 0 then
        begin
          Ctx.Status := 500;
          Ctx.ContentType := 'application/json';
          Ctx.Body := TEncoding.UTF8.GetBytes('{"error":"simulated failure"}');
        end
        else
        begin
          Ctx.Status := 200;
          Ctx.ContentType := 'application/json';
          Ctx.Body := TEncoding.UTF8.GetBytes('{"ok":true}');
        end;
      end);

    Writeln('Poseidon Sample 10 — Real-time Metrics Dashboard');
    Writeln('Serving dashboard from: ', LPublic);
    Writeln('Listening on http://0.0.0.0:', LPort);
    Writeln;
    Writeln('  Dashboard : http://localhost:', LPort, '/dashboard/dashboard.html');
    Writeln('  Metrics   : http://localhost:', LPort, '/metrics');
    Writeln('  Routes    : GET /ping  /api/users/:id  /api/report (slow)  /api/flaky (errors)');
    Writeln;

    App.Listen(LPort, '0.0.0.0',
      procedure
      begin
        Writeln('Server ready. Press Enter to stop...');
        Readln;
        App.Stop;
      end);
  finally
    App.Free;
  end;
end.
