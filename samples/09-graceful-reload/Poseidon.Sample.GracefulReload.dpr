program Poseidon.Sample.GracefulReload;

// Sample 09 — Graceful Reload (zero-downtime restart)
// Demonstrates PID file management and signal handling for zero-downtime deploys.
//
// How it works:
//   1. Server starts, writes its PID to a file
//   2. PerCoreAccept enables SO_REUSEPORT (Linux) — multiple processes can bind the same port
//   3. Deploy script starts a new instance, waits, then sends SIGTERM to the old one
//   4. Old instance drains in-flight requests (DrainTimeoutMs) and shuts down cleanly
//
// Linux deploy script:
//   OLD_PID=$(cat /tmp/poseidon.pid)
//   ./poseidon-new &
//   sleep 2
//   kill -TERM $OLD_PID
//
// Windows:
//   PID file works for process management (taskkill /PID).
//   Signal handler is Linux-only; Windows uses service control or manual stop.

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.GracefulReload;

const
  CServerPort = 9009;
  CPIDPath = {$IFDEF MSWINDOWS}'poseidon.pid'{$ELSE}'/tmp/poseidon.pid'{$ENDIF};

var
  App: TPoseidonServer;
begin
  App := TPoseidonServer.Create;
  try
    App.PIDFile := CPIDPath;
    App.PerCoreAccept := True;
    App.DrainTimeoutMs := 5000;

    App.Get('/ping',
      procedure(var Ctx: TNativeRequestContext)
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'application/json';
        Ctx.Body := TEncoding.UTF8.GetBytes('{"message":"pong","pid":' + IntToStr(GetProcessID) + '}');
      end);

    {$IFNDEF MSWINDOWS}
    InstallSignalHandler(
      procedure
      begin
        App.Stop;
      end);
    {$ENDIF}

    Writeln('Poseidon Sample 09 — Graceful Reload');
    Writeln('PID: ', GetProcessID);
    Writeln('PID file: ', CPIDPath);
    Writeln('Listening on http://0.0.0.0:', CServerPort);
    Writeln('  GET /ping -> {"message":"pong","pid":...}');
    {$IFDEF MSWINDOWS}
    Writeln('Press Enter to stop (Windows mode).');
    {$ELSE}
    Writeln('Send SIGTERM to gracefully shut down.');
    {$ENDIF}
    Writeln;

    App.Listen(CServerPort, '0.0.0.0',
      procedure
      begin
        Writeln('Server ready.');
        {$IFDEF MSWINDOWS}
        Readln;
        App.Stop;
        {$ENDIF}
      end);
  finally
    App.Free;
  end;
end.
