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
  Poseidon.Tests.HPACK,
  Poseidon.Tests.Dispatcher,
  Poseidon.Tests.Connection,
  Poseidon.Tests.DeferredResponse,
  Poseidon.Tests.Workers,
  Poseidon.Tests.Problem,
  Poseidon.Tests.Validation,
  Poseidon.Tests.Fuzz,
  Poseidon.Mock.SSLProvider,
  Poseidon.Mock.Context,
  Poseidon.Tests.Middleware.CORS,
  Poseidon.Tests.Middleware.Security,
  Poseidon.Tests.Middleware.BodyLimit,
  Poseidon.Tests.Middleware.RequestID,
  Poseidon.Tests.Middleware.Timeout,
  Poseidon.Tests.Middleware.Guard,
  Poseidon.Tests.Middleware.Logger,
  Poseidon.Tests.Middleware.RateLimit,
  Poseidon.Tests.Middleware.CircuitBreaker,
  Poseidon.Tests.Middleware.Compression,
  Poseidon.Tests.Middleware.JWT,
  Poseidon.Tests.Middleware.Metrics,
  Poseidon.Tests.Middleware.Validation,
  Poseidon.Tests.Middleware.ProblemDetails,
  Poseidon.Tests.Middleware.HealthCheck,
  Poseidon.Tests.Middleware.Digest,
  Poseidon.Tests.Middleware.Static,
  Poseidon.Tests.Middleware.Proxy,
  Poseidon.Tests.Middleware.OpenAPI,
  Poseidon.Tests.Middleware.Cache;

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
