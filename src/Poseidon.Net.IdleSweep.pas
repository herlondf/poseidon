unit Poseidon.Net.IdleSweep;

// TIdleSweepManager — background thread that closes idle connections.
//
// Extracted from TPoseidonNativeServer._IdleSweepLoop to follow SRP.
// Uses TConnectionManager.Snapshot for thread-safe enumeration and
// IIOBackend.ShutdownConn to initiate graceful close.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  syncobjs,
  Classes,
  Poseidon.Compat,
  {$ELSE}
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  {$ENDIF}
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.Connection.Manager,
  Poseidon.Net.IO;

type
  TIdleSweepManager = class
  private
    FIdleTimeoutMs: Integer;
    FSweepThread: TThread;
    FStopEvent: TEvent;
    FConnManager: TConnectionManager;
    FIOBackend: IIOBackend;
    FOnLog: TOnPoseidonLog;
    FOnForceClose: TProc<Pointer>;
    FActive: PBoolean;
    procedure SweepLoop;
  public
    constructor Create(AConnManager: TConnectionManager;
      AIOBackend: IIOBackend; AActive: PBoolean);
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    property IdleTimeoutMs: Integer read FIdleTimeoutMs write FIdleTimeoutMs;
    property OnLog: TOnPoseidonLog read FOnLog write FOnLog;
    // #224 mitigation: called instead of ShutdownConn when a connection was
    // already shutdown-requested on an earlier sweep and is still open past
    // the grace period — must route to the server's full _CloseConn teardown
    // (idempotent: safe even if the original shutdown's completion arrives
    // concurrently), not just IIOBackend.SocketClose.
    property OnForceClose: TProc<Pointer> read FOnForceClose write FOnForceClose;
  end;

implementation

const
  CDefaultIdleTimeoutMs = 10000;
  CSweepIntervalMs = 1000;
  // #224: grace period after ShutdownConn before we stop waiting for the
  // recv-error completion and force the close ourselves. Generous on purpose
  // — this only fires when the normal completion-driven close has already
  // failed to happen for a full sweep interval past a routine idle-shutdown,
  // which is never expected in healthy operation.
  CForceCloseGraceMs = 5000;

constructor TIdleSweepManager.Create(AConnManager: TConnectionManager;
  AIOBackend: IIOBackend; AActive: PBoolean);
begin
  inherited Create;
  FConnManager := AConnManager;
  FIOBackend := AIOBackend;
  FActive := AActive;
  FIdleTimeoutMs := CDefaultIdleTimeoutMs;
  FStopEvent := TEvent.Create(nil, True, False, '');
  FSweepThread := nil;
end;

destructor TIdleSweepManager.Destroy;
begin
  Stop;
  FreeAndNil(FStopEvent);
  inherited Destroy;
end;

procedure TIdleSweepManager.Start;
begin
  if FSweepThread <> nil then Exit;
  FStopEvent.ResetEvent;
  FSweepThread := TThread.CreateAnonymousThread(SweepLoop);
  FSweepThread.FreeOnTerminate := False;
  FSweepThread.Start;
end;

procedure TIdleSweepManager.Stop;
begin
  if FSweepThread = nil then Exit;
  FStopEvent.SetEvent;
  FSweepThread.WaitFor;
  FreeAndNil(FSweepThread);
end;

procedure TIdleSweepManager.SweepLoop;
var
  LSnap:    TArray<Pointer>;
  I:        Integer;
  LConn:    TNativeConn;
  LNowTick: UInt64;
  LDiff:    UInt64;
  LIdle:    Int64;
begin
  while FActive^ do
  begin
    FStopEvent.WaitFor(CSweepIntervalMs);
    if not FActive^ then Break;
    if FIdleTimeoutMs <= 0 then Continue;

    LSnap := FConnManager.Snapshot;
    LNowTick := TThread.GetTickCount64;
    for I := 0 to High(LSnap) do
    begin
      LConn := TNativeConn(LSnap[I]);
      try
        // Skip connections currently being handled by the elastic pool
        if TInterlocked.Add(LConn.InFlightPool, 0) > 0 then Continue;
        LDiff := LNowTick - LConn.LastActivityTick;
        if LDiff > UInt64(MaxInt) then
          LIdle := MaxInt
        else
          LIdle := Integer(LDiff);
        if LIdle > FIdleTimeoutMs then
        begin
          // #224 mitigation: ShutdownConn only sends shutdown(); the fd is
          // actually closed later, when the resulting recv-error completion
          // reaches _CloseConn. If that completion never arrives (the open
          // issue tracked in #224), the socket leaks forever in FIN_WAIT2
          // with no kernel timeout. Detect that on a LATER sweep pass (same
          // connection, still open, past the grace period since we first
          // shut it down) and force the close ourselves instead of leaking.
          if LConn.ShutdownRequestedTick = 0 then
          begin
            // #208: idle close is routine lifecycle, not an error — logging it
            // at llError floods production error logs. Demote to llDebug.
            if Assigned(FOnLog) then
              FOnLog(llDebug, '[sweep] idle close: ' + LConn.RemoteAddr +
                ' idle=' + IntToStr(LIdle) + 'ms');
            LConn.ShutdownRequestedTick := LNowTick;
            FIOBackend.ShutdownConn(LSnap[I]);
          end
          else if LNowTick - LConn.ShutdownRequestedTick > UInt64(CForceCloseGraceMs) then
          begin
            if Assigned(FOnLog) then
              FOnLog(llWarning, '[sweep] #224 force-close: ' + LConn.RemoteAddr +
                ' — no completion ' + IntToStr(CForceCloseGraceMs) +
                'ms after shutdown, fd would have leaked');
            if Assigned(FOnForceClose) then
              FOnForceClose(LSnap[I]);
          end;
        end;
      finally
        LConn.Release;
      end;
    end;
  end;
end;

end.
