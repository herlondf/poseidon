program Poseidon.Tests.GlobalMiddlewareOnly;

// Focused runner: global-middleware dispatch fixture only.
//
// Ships as a dedicated runner (like Poseidon.Tests.DeferOnly) rather than in the
// main suite: it stands up its own in-process HTTP server, and the main suite's
// H2C/idle-timeout integration tests are load-sensitive — adding another live
// server to that single process nudges them over their flakiness edge. Isolated
// here, this regression stays deterministic. It locks the fix that lets global
// middlewares (metrics/static/CORS) serve their own paths with no matched route.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  Poseidon.Tests.Integration.GlobalMiddleware;

var
  LRunner:  ITestRunner;
  LResults: IRunResults;
begin
  try
    LRunner := TDUnitX.CreateRunner;
    LRunner.UseRTTI := True;
    LRunner.FailsOnNoAsserts := False;
    LRunner.AddLogger(TDUnitXConsoleLogger.Create(True));
    LResults := LRunner.Execute;
    WriteLn(Format('PASS=%d FAIL=%d ERROR=%d',
      [LResults.PassCount, LResults.FailureCount, LResults.ErrorCount]));
    if not LResults.AllPassed then
      System.ExitCode := 1;
  except
    on E: Exception do
    begin
      WriteLn(E.ClassName + ': ' + E.Message);
      System.ExitCode := 2;
    end;
  end;
end.
