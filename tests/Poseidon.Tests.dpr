program Poseidon.Tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.TestRunner,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.XML.NUnit,
  Poseidon.Tests.WebSocket,
  Poseidon.Tests.HttpServer,
  Poseidon.Tests.HTTP2,
  Poseidon.Tests.Security,
  Poseidon.Tests.BufferPool,
  Poseidon.Tests.HTTP1Parser,
  Poseidon.Tests.ResponseBuilder,
  Poseidon.Tests.ProxyProtocol,
  Poseidon.Tests.SSL,
  Poseidon.Tests.Brotli,
  Poseidon.Tests.HPACK,
  Poseidon.Tests.Metrics,
  Poseidon.Tests.Dispatcher,
  Poseidon.Tests.WebAdapters,
  Poseidon.Tests.Connection,
  Poseidon.Tests.Workers,
  Poseidon.Tests.PoolNative,
  // Framework tests (ex-Pegasus)
  Poseidon.Tests.Router,
  Poseidon.Tests.Validation,
  Poseidon.Tests.Middleware,
  Poseidon.Tests.OpenAPI,
  Poseidon.Tests.Problem,
  Poseidon.Tests.SerializerCookies,
  Poseidon.Tests.StabilityMiddleware,
  Poseidon.Tests.StaticMetrics,
  // Horse compatibility tests
  Poseidon.Tests.HorseCompat,
  // Real middleware integration tests (execute actual Horse middlewares)
  Poseidon.Tests.MiddlewareIntegration in 'compat\Poseidon.Tests.MiddlewareIntegration.pas',
  // Mocks
  Poseidon.Mock.SSLProvider,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse;

var
  LRunner:  ITestRunner;
  LResults: IRunResults;
begin
  try
    TDUnitX.CheckCommandLine;
    LRunner := TDUnitX.CreateRunner;
    LRunner.UseRTTI          := True;
    LRunner.FailsOnNoAsserts := False;
    LRunner.AddLogger(TDUnitXConsoleLogger.Create(False));
    LRunner.AddLogger(TDUnitXXMLNUnitFileLogger.Create('.\bin\DUnitX-Results.xml'));
    LResults := LRunner.Execute;
    if not LResults.AllPassed then
      System.ExitCode := EXIT_ERRORS;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName + ': ' + E.Message);
      System.ExitCode := 1;
    end;
  end;
end.
