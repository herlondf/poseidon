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
  Poseidon.Mock.SSLProvider;

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
