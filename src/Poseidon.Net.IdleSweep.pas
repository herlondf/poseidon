unit Poseidon.Net.IdleSweep;

// TIdleSweepManager closes idle connections from a background thread, walking a
// TConnectionManager.Snapshot and calling IIOBackend.ShutdownConn.

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
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.IO;

// perf-loop (2026-09-17): TThread.GetTickCount64 was measured live (strace
// under real load, debian-bench) making a REAL syscall under FPC/Linux -
// NOT the vDSO fast path some other call sites' comments assume (true for
// Delphi's RTL, not confirmed for FPC's). ~1-2 calls/request through
// LConn.LastActivityTick (_ProcessRecv's hot path) showed up as ~160k
// gettimeofday+clock_gettime syscalls in a 10s/~200k-request window - a
// real, measurable per-request cost. IdleTimeoutMs/MaxHandlerRunMs/etc. all
// operate at multi-second granularity, so a tick cached at 1s resolution
// (this sweep thread's own interval - "rides this thread" like the
// heartbeat above) is accurate enough: callers that used to pay a syscall
// per request now do a single unsynchronized Int64 read instead. A stale
// read by up to one sweep interval is the accepted tradeoff, not a bug.
function PoseidonCoarseTickMs: Int64;

type
  TIdleSweepManager = class
  private
    FIdleTimeoutMs: Integer;
    // #233: watchdog for a handler stuck in normal operation. 0 = disabled.
    FMaxHandlerRunMs: Integer;
    // #254 (Slowloris): absolute deadline to complete the first request's
    // headers, unaffected by IdleTimeoutMs resetting on every partial byte.
    // 0 = disabled.
    FHeaderTimeoutMs: Integer;
    FSweepThread: TThread;
    FStopEvent: TEvent;
    FConnManager: TConnectionManager;
    FIOBackend: IIOBackend;
    FOnLog: TOnPoseidonLog;
    FOnForceClose: TProc<Pointer>;
    FOnHeartbeat: TProc;
    FHeartbeatMs: Integer;
    FActive: PBoolean;
    FShrinkAccumBufEnabled: Boolean;
    procedure SweepLoop;
  public
    constructor Create(AConnManager: TConnectionManager;
      AIOBackend: IIOBackend; AActive: PBoolean);
    destructor Destroy; override;

    procedure Start;
    procedure Stop;

    property IdleTimeoutMs: Integer read FIdleTimeoutMs write FIdleTimeoutMs;
    // #233: how long a handler may hold InFlightPool > 0 before the sweep calls
    // it stuck and force-closes the connection, leaving teardown to the worker's
    // own Release rather than killing the thread. 0 = disabled.
    property MaxHandlerRunMs: Integer read FMaxHandlerRunMs write FMaxHandlerRunMs;
    // #254: see FHeaderTimeoutMs. 0 = disabled (default - opt-in, like
    // MaxHandlerRunMs, so existing deployments keep today's behavior unless
    // set explicitly).
    property HeaderTimeoutMs: Integer read FHeaderTimeoutMs write FHeaderTimeoutMs;
    // #234 (2026-08-12): shrinks an idle, drained AccumBuf back to tier 0.
    // Defaults True, but HttpServer turns it off in production while the heap
    // corruption in #234 is unresolved: this is the newest code touching
    // AccumBuf's lifetime, so its Acquire/Release is an unproven suspect.
    // Re-enable once #234 closes or this is cleared.
    property ShrinkAccumBufEnabled: Boolean
      read FShrinkAccumBufEnabled write FShrinkAccumBufEnabled;
    property OnLog: TOnPoseidonLog read FOnLog write FOnLog;
    // #224: replaces ShutdownConn once a connection shut down on an earlier
    // sweep is still open past the grace period. Must route to the server's full
    // _CloseConn, not IIOBackend.SocketClose; it is idempotent, so the original
    // shutdown's completion arriving concurrently is safe.
    property OnForceClose: TProc<Pointer> read FOnForceClose write FOnForceClose;
    // Health tick. Rides this thread rather than spawning one, since it already
    // wakes every second, and a server silent between startup and a crash left
    // operators nothing to correlate. HeartbeatMs = 0 silences it.
    property OnHeartbeat: TProc read FOnHeartbeat write FOnHeartbeat;
    property HeartbeatMs: Integer read FHeartbeatMs write FHeartbeatMs;
  end;

implementation

const
  CDefaultIdleTimeoutMs = 10000;
  CSweepIntervalMs = 1000;
  // #224: how long to wait for the recv-error completion before forcing the
  // close. Generous on purpose: it only fires when the normal completion-driven
  // close already failed for a full sweep interval, which healthy operation
  // never reaches.
  CForceCloseGraceMs = 5000;

var
  // Backing store for PoseidonCoarseTickMs (see that function's comment).
  // Seeded in the initialization section so a reader before the first sweep
  // tick still gets a real tick, not a stale 0.
  GCoarseTickMs: Int64;

function PoseidonCoarseTickMs: Int64;
begin
  Result := TInterlocked.Read(GCoarseTickMs);
end;

constructor TIdleSweepManager.Create(AConnManager: TConnectionManager;
  AIOBackend: IIOBackend; AActive: PBoolean);
begin
  inherited Create;
  FConnManager := AConnManager;
  FIOBackend := AIOBackend;
  FActive := AActive;
  FShrinkAccumBufEnabled := True;
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
  LLastAct: UInt64;
  LDiff:    UInt64;
  LIdle:    Int64;
  LLastBeat: UInt64;
  LOldBuf:  TBytes;
  LHDiff:   UInt64;
  LHeaderAge: Int64;
begin
  LLastBeat := TThread.GetTickCount64;
  while FActive^ do
  begin
    FStopEvent.WaitFor(CSweepIntervalMs);
    if not FActive^ then Break;

    // One real tick read per sweep pass (~1/s), shared by the heartbeat check,
    // the connection walk below, and PoseidonCoarseTickMs's cache - see that
    // function's comment for why hot-path callers read this instead of
    // calling TThread.GetTickCount64 themselves.
    LNowTick := TThread.GetTickCount64;
    TInterlocked.Exchange(GCoarseTickMs, Int64(LNowTick));

    if (FHeartbeatMs > 0) and Assigned(FOnHeartbeat) and
       (LNowTick - LLastBeat >= UInt64(FHeartbeatMs)) then
    begin
      LLastBeat := LNowTick;
      // A logging failure must never kill the sweep; it is what stops fds from
      // leaking.
      try FOnHeartbeat(); except on E: Exception do; end;
    end;

    if (FIdleTimeoutMs <= 0) and (FMaxHandlerRunMs <= 0) and
       (FHeaderTimeoutMs <= 0) then Continue;

    LSnap := FConnManager.Snapshot;
    for I := 0 to High(LSnap) do
    begin
      LConn := TNativeConn(LSnap[I]);
      try
        // LNowTick is sampled once, before the sweep walks the snapshot. A
        // connection that sees traffic DURING the walk stamps LastActivityTick
        // ahead of it, so the UInt64 subtraction wraps to ~2^64 - which the
        // MaxInt clamp below then reads as "idle forever" and closes. That
        // inverted the whole check: the busier the connection, the likelier it
        // was to be swept. Measured at 1606 wrongful closes in 120s under
        // saturating load, surfacing on the client as socket read errors.
        // A tick at or past the sample means activity newer than this pass.
        LLastAct := LConn.LastActivityTick;
        if LLastAct >= LNowTick then
          LIdle := 0
        else
        begin
          LDiff := LNowTick - LLastAct;
          if LDiff > UInt64(MaxInt) then
            LIdle := MaxInt
          else
            LIdle := Integer(LDiff);
        end;

        // #254 (Slowloris): absolute deadline to complete the FIRST request's
        // headers, measured from HeaderDeadlineTick (stamped once at connect,
        // never reset by partial activity - unlike LIdle/LastActivityTick
        // above, which is exactly the loophole Slowloris exploits). Same
        // wrap-safety reasoning as LIdle: a tick at or past the sample means
        // the deadline has not started counting against this pass yet.
        if (FHeaderTimeoutMs > 0) and (not LConn.HeadersEverCompleted) then
        begin
          if LConn.HeaderDeadlineTick >= LNowTick then
            LHeaderAge := 0
          else
          begin
            LHDiff := LNowTick - LConn.HeaderDeadlineTick;
            if LHDiff > UInt64(MaxInt) then
              LHeaderAge := MaxInt
            else
              LHeaderAge := Integer(LHDiff);
          end;
          if LHeaderAge > FHeaderTimeoutMs then
          begin
            if Assigned(FOnLog) then
              FOnLog(llWarning, '[sweep] #254 header deadline: ' +
                LConn.RemoteAddr + ' incomplete headers after ' +
                IntToStr(LHeaderAge) + 'ms (limit ' +
                IntToStr(FHeaderTimeoutMs) + 'ms) - closing connection ' +
                '(Slowloris guard)');
            if Assigned(FOnForceClose) then
              FOnForceClose(LSnap[I]);
            Continue;
          end;
        end;

        if TInterlocked.Add(LConn.InFlightPool, 0) > 0 then
        begin
          // #233: a handler is running or queued, so the idle-close checks
          // below do not apply; LastActivityTick refreshes at dispatch time,
          // not only on recv. Without this, a handler stuck outside shutdown
          // (where FDrainTimeoutMs covers it) ran forever undefended.
          if (FMaxHandlerRunMs > 0) and (LIdle > FMaxHandlerRunMs) then
          begin
            if Assigned(FOnLog) then
              FOnLog(llWarning, '[sweep] #233 handler stuck: ' +
                LConn.RemoteAddr + ' running=' + IntToStr(LIdle) +
                'ms (limit ' + IntToStr(FMaxHandlerRunMs) + 'ms) - closing ' +
                'connection, NOT killing the worker thread');
            if Assigned(FOnForceClose) then
              FOnForceClose(LSnap[I]);
          end;
          Continue;
        end;

        // _CompactAccum resets AccumLen but never capacity, so a keep-alive
        // connection that once served one big request holds that peak for life.
        // LConn.Lock excludes a concurrent recv on this connection's IO thread
        // (#213). InFlightPool is re-checked under the lock because a dispatch
        // can be posted between the fast-path skip above and Lock.Enter.
        //
        // perf (compete-with-actix, 2026-09-18): TryEnter, not Enter. This is
        // the ONLY place a thread other than a connection's own IO/dispatch
        // thread ever wants LConn.Lock - i.e. the one cross-thread contention
        // point standing between Poseidon and being genuinely shared-nothing
        // per-core on this path (see README's architecture section). A
        // blocking Enter here forces the request path's own Lock.Enter
        // (_ProcessRecv/_DispatchAccumBuf, paid on every request) to
        // occasionally wait on the sweep thread. Shrinking is a pure,
        // optional memory-reclaim nicety - skipping it for one sweep pass
        // when the connection happens to be busy right now is free (it is
        // retried every ~1s, see CSweepIntervalMs), so losing the race is a
        // fine outcome, never a correctness problem.
        if FShrinkAccumBufEnabled and LConn.Lock.TryEnter then
        begin
          try
            if (TInterlocked.Add(LConn.InFlightPool, 0) = 0) and
               (LConn.AccumLen = 0) and
               (Length(LConn.AccumBuf) > POOL_TIER0_SIZE) then
            begin
              LOldBuf := LConn.AccumBuf;
              LConn.AccumBuf := TBufferPool.Acquire;
              TBufferPool.Release(LOldBuf);
            end;
          finally
            LConn.Lock.Leave;
          end;
        end;

        if FIdleTimeoutMs <= 0 then Continue;
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
            // #208: idle close is routine lifecycle, not an error - logging it
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
                ' - no completion ' + IntToStr(CForceCloseGraceMs) +
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

initialization
  GCoarseTickMs := TThread.GetTickCount64;

end.
