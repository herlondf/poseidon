program Poseidon.Tests.DeferOnly;

// Focused runner: deferred-response fixtures only (fast; no SSL/H2/fuzz).

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.Loggers.Console,
  Poseidon.Tests.DeferredResponse;

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
