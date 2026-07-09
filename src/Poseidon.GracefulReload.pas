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
// Install a SIGTERM/SIGINT handler. The signal handler only sets an atomic
// flag — call CheckShutdownSignal periodically to invoke the callback safely.
procedure InstallSignalHandler(AOnShutdown: TProc);

// Poll the shutdown flag. If a signal was received, invokes the callback
// registered via InstallSignalHandler. Safe to call from any thread context.
procedure CheckShutdownSignal;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  Winapi.Windows;
{$ELSE}
uses
  System.SyncObjs,
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
    {$IFDEF MSWINDOWS}
    WriteLn(LFile, GetCurrentProcessId);
    {$ELSE}
    WriteLn(LFile, getpid);
    {$ENDIF}
    CloseFile(LFile);
  except
    on E: Exception do; // Best-effort — don't crash if /run is read-only
  end;
end;

procedure RemovePIDFile(const APath: string);
begin
  if (APath <> '') and FileExists(APath) then
    try
      // Qualify to the RTL string overload: on Windows the bare DeleteFile
      // resolves to the Winapi.Windows PWideChar version.
      System.SysUtils.DeleteFile(APath);
    except
      on E: Exception do;
    end;
end;

{$IFNDEF MSWINDOWS}
var
  // Atomic flag set by signal handler — async-signal-safe (no heap, no locks).
  // The main thread polls this via CheckShutdownSignal.
  GShutdownFlag: Integer = 0;
  GShutdownProc: TProc;

procedure _SigTermHandler(ASigNum: Integer); cdecl;
begin
  // Only set an atomic flag — async-signal-safe.
  // TProc invocation moved to CheckShutdownSignal (called from main loop).
  GShutdownFlag := 1;
end;

procedure CheckShutdownSignal;
begin
  if TInterlocked.CompareExchange(GShutdownFlag, 0, 1) = 1 then
  begin
    if Assigned(GShutdownProc) then
      GShutdownProc();
  end;
end;

procedure InstallSignalHandler(AOnShutdown: TProc);
var
  LSA: sigaction_t;
begin
  GShutdownProc := AOnShutdown;
  GShutdownFlag := 0;
  FillChar(LSA, SizeOf(LSA), 0);
  LSA._u.sa_handler := @_SigTermHandler;
  LSA.sa_flags := 0;
  sigemptyset(LSA.sa_mask);
  sigaction(SIGTERM, @LSA, nil);
  sigaction(SIGINT, @LSA, nil);
end;
{$ENDIF}

end.
