unit Poseidon.GracefulReload;

// Graceful reload (zero-downtime restart) support.
//
// Provides:
//   - PID file management: write on startup, remove on shutdown
//   - SIGTERM handler: catches the signal and calls a shutdown callback
//
// Usage (Linux):
//   App := TPoseidonServer.Create;
//   App.PerCoreAccept := True;  // enables SO_REUSEPORT
//   App.PIDFile := '/run/poseidon.pid';
//   InstallSignalHandler(procedure begin App.Stop; end);
//   App.Listen(8080);
//
// Deploy script:
//   OLD_PID=$(cat /run/poseidon.pid)
//   ./poseidon-new &
//   sleep 2
//   kill -TERM $OLD_PID
//
// Windows:
//   PID file works on Windows too (for process management).
//   SIGTERM handler is Linux-only (Windows uses service control).

interface

uses
  System.SysUtils;

// Write the current process PID to the specified file.
procedure WritePIDFile(const APath: string);

// Remove a previously created PID file.
procedure RemovePIDFile(const APath: string);

{$IFNDEF MSWINDOWS}
// Install a SIGTERM handler that calls AOnShutdown.
// The callback is invoked from the signal handler context —
// it should only set a flag or call TEvent.SetEvent.
procedure InstallSignalHandler(AOnShutdown: TProc);
{$ENDIF}

implementation

{$IFNDEF MSWINDOWS}
uses
  Posix.Signal,
  Posix.Unistd;
{$ENDIF}

procedure WritePIDFile(const APath: string);
var
  LFile: TextFile;
begin
  if APath = '' then Exit;
  AssignFile(LFile, APath);
  try
    Rewrite(LFile);
    WriteLn(LFile, GetProcessID);
    CloseFile(LFile);
  except
    on E: Exception do; // Best-effort — don't crash if /run is read-only
  end;
end;

procedure RemovePIDFile(const APath: string);
begin
  if (APath <> '') and FileExists(APath) then
    try
      DeleteFile(APath);
    except
      on E: Exception do;
    end;
end;

{$IFNDEF MSWINDOWS}
var
  GShutdownProc: TProc;

procedure _SigTermHandler(ASigNum: Integer); cdecl;
begin
  if Assigned(GShutdownProc) then
    GShutdownProc();
end;

procedure InstallSignalHandler(AOnShutdown: TProc);
var
  LSA: sigaction_t;
begin
  GShutdownProc := AOnShutdown;
  FillChar(LSA, SizeOf(LSA), 0);
  LSA.__sigaction_handler := @_SigTermHandler;
  LSA.sa_flags := 0;
  sigemptyset(LSA.sa_mask);
  sigaction(SIGTERM, @LSA, nil);
  sigaction(SIGINT, @LSA, nil);
end;
{$ENDIF}

end.
