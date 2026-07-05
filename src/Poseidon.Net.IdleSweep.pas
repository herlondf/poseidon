unit Poseidon.Net.IdleSweep;

// TIdleSweepManager (#88) — background thread that closes idle connections.
//
// Extracted from TPoseidonNativeServer._IdleSweepLoop to follow SRP.
// Uses TConnectionManager.Snapshot for thread-safe enumeration and
// IIOBackend.ShutdownConn to initiate graceful close.

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.Connection.Manager,
  Poseidon.Net.IO;

type
  TIdleSweepManager = class
  private
    FIdleTimeoutMs:  Integer;
    FSweepThread:    TThread;
    FStopEvent:      TEvent;
    FConnManager:    TConnectionManager;
    FIOBackend:      IIOBackend;
    FOnLog:          TOnPoseidonLog;
    FActive:         PBoolean;  // points to server's FActive flag
    procedure SweepLoop;
  public
    constructor Create(AConnManager: TConnectionManager;
      AIOBackend: IIOBackend; AActive: PBoolean);
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    property IdleTimeoutMs: Integer read FIdleTimeoutMs write FIdleTimeoutMs;
    property OnLog: TOnPoseidonLog read FOnLog write FOnLog;
  end;

implementation

const
  CSweepIntervalMs = 1000;

constructor TIdleSweepManager.Create(AConnManager: TConnectionManager;
  AIOBackend: IIOBackend; AActive: PBoolean);
begin
  inherited Create;
  FConnManager   := AConnManager;
  FIOBackend     := AIOBackend;
  FActive        := AActive;
  FIdleTimeoutMs := 10000;  // default 10s
  FStopEvent     := TEvent.Create(nil, True, False, '');
  FSweepThread   := nil;
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
        LIdle := Integer(LNowTick - LConn.LastActivityTick);
        if LIdle > FIdleTimeoutMs then
        begin
          if Assigned(FOnLog) then
            FOnLog(llError, '[sweep] idle close: ' + LConn.RemoteAddr +
              ' idle=' + IntToStr(LIdle) + 'ms');
          FIOBackend.ShutdownConn(LSnap[I]);
        end;
      finally
        LConn.Release;
      end;
    end;
  end;
end;

end.
