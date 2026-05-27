program AsyncIO.Tests;

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  DUnitX.TestFramework,
  DUnitX.TestRunner,
  DUnitX.Loggers.Console,
  DUnitX.Loggers.XML.NUnit,
  AsyncIO.Tests.WebSocket;

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
