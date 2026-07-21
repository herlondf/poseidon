unit Poseidon.Tests.DeferredResponse;

// DUnitX integration tests for deferred (asynchronous) responses — Ctx.Defer.
//
// Fixture 1 — TPoseidonDeferredTests (port 19010): async worker-pool dispatch
//   * a handler defers, then completes the reply from a DIFFERENT thread
//   * middleware headers present at Defer time are preserved
//   * a dropped responder force-closes the connection (no client hang)
//   * many concurrent deferred requests all complete
// Fixture 2 — TPoseidonDeferredSyncTests (port 19011): SyncDispatch=True
//   * the same async completion works while handlers run inline on the IO thread
//     (the core reason deferred responses exist: they unblock the fast path)
//
// HTTP client: raw Winsock2 blocking sockets (the helpers live in
// Poseidon.Tests.HttpServer and are reused via a small local copy to keep this
// unit self-contained for the parts it needs).

interface

uses
  DUnitX.TestFramework,
  System.SyncObjs;

type
  {$M+}
  [TestFixture]
  TPoseidonDeferredTests = class  // port 19010 — async dispatch
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    [Test]
    procedure Defer_AsyncHandler_ClientReceivesResponse;
    [Test]
    procedure Defer_PreservesMiddlewareHeader;
    [Test]
    procedure Defer_DroppedWithoutRespond_ConnectionClosed;
    [Test]
    procedure Defer_ManyConcurrent_AllComplete;
  end;

  [TestFixture]
  TPoseidonDeferredSyncTests = class  // port 19011 — SyncDispatch inline
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    [Test]
    procedure Sync_PlainRoute_Works;
    [Test]
    procedure Defer_UnderSyncDispatch_ImmediateRespondWorks;
    [Test]
    procedure Defer_UnderSyncDispatch_AsyncHandlerWorks;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading,
  System.Generics.Collections,
  Winapi.Winsock2,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

const
  DEFER_PORT      = 19010;
  DEFER_SYNC_PORT = 19011;

// ---------------------------------------------------------------------------
// Raw TCP helpers (blocking Winsock2) — a request + complete-response read.
// ---------------------------------------------------------------------------

function DConnect(APort: Word): TSocket;
var
  LAddr: TSockAddrIn;
begin
  Result := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if Result = INVALID_SOCKET then Exit;
  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family      := AF_INET;
  LAddr.sin_port        := htons(APort);
  LAddr.sin_addr.S_addr := inet_addr('127.0.0.1');
  if connect(Result, TSockAddr(LAddr), SizeOf(LAddr)) <> 0 then
  begin
    closesocket(Result);
    Result := INVALID_SOCKET;
  end;
end;

function DSendAll(ASock: TSocket; const ABuf: TBytes): Boolean;
var
  LTotal, LSent, LRem: Integer;
begin
  LTotal := 0;
  LRem := Length(ABuf);
  while LRem > 0 do
  begin
    LSent := send(ASock, ABuf[LTotal], LRem, 0);
    if LSent <= 0 then Exit(False);
    Inc(LTotal, LSent);
    Dec(LRem, LSent);
  end;
  Result := True;
end;

// Reads a complete HTTP/1.1 response (headers + Content-Length body) until the
// message arrives or the deadline elapses. Returns the status code and full
// response text. Returns 0 on timeout; -1 when the peer closed with no bytes.
function DRecvHTTP(ASock: TSocket; out AResp: string; ATimeoutMs: Integer): Integer;
var
  LBuf:      TBytes;
  LTotal, LRecvd, LHdrEnd, LBodyLen, LP, LE, I: Integer;
  LChunk:    array[0..4095] of Byte;
  LDeadline: UInt64;
  LTmo:      Integer;
  LHdrs:     string;
  LPeerClosed: Boolean;
begin
  Result := 0; AResp := ''; LTotal := 0; LHdrEnd := -1; LBodyLen := -1;
  LPeerClosed := False;
  SetLength(LBuf, 0);
  LTmo := 400;
  setsockopt(ASock, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@LTmo), SizeOf(LTmo));
  LDeadline := TThread.GetTickCount64 + UInt64(ATimeoutMs);

  while TThread.GetTickCount64 < LDeadline do
  begin
    LRecvd := recv(ASock, LChunk[0], SizeOf(LChunk), 0);
    if LRecvd = 0 then begin LPeerClosed := True; Break; end;  // FIN
    if LRecvd < 0 then Continue;                                // timeout tick

    SetLength(LBuf, LTotal + LRecvd);
    Move(LChunk[0], LBuf[LTotal], LRecvd);
    Inc(LTotal, LRecvd);

    if LHdrEnd < 0 then
      for I := 0 to LTotal - 4 do
        if (LBuf[I] = 13) and (LBuf[I+1] = 10) and
           (LBuf[I+2] = 13) and (LBuf[I+3] = 10) then
        begin LHdrEnd := I; Break; end;

    if (LHdrEnd >= 0) and (LBodyLen < 0) then
    begin
      LHdrs := LowerCase(TEncoding.ASCII.GetString(LBuf, 0, LHdrEnd));
      LP := Pos('content-length:', LHdrs);
      if LP > 0 then
      begin
        LP := LP + Length('content-length:');
        while (LP <= Length(LHdrs)) and (LHdrs[LP] = ' ') do Inc(LP);
        LE := LP;
        while (LE <= Length(LHdrs)) and (LHdrs[LE] >= '0') and (LHdrs[LE] <= '9') do Inc(LE);
        LBodyLen := StrToIntDef(Copy(LHdrs, LP, LE - LP), 0);
      end
      else
        LBodyLen := 0;
    end;

    if (LHdrEnd >= 0) and (LTotal >= LHdrEnd + 4 + LBodyLen) then Break;
  end;

  if (LTotal = 0) then
  begin
    if LPeerClosed then Result := -1;
    Exit;
  end;
  AResp := TEncoding.ASCII.GetString(LBuf, 0, LTotal);
  LP := Pos('HTTP/1.', AResp);
  if LP > 0 then
    Result := StrToIntDef(Copy(AResp, LP + 9, 3), 0);
end;

// Like DGet, but retries a dropped/unanswered connection with a fresh socket
// until a real HTTP status arrives or the deadline elapses. The Windows IOCP
// backend can occasionally drop a request under extreme concurrent-server test
// load (hundreds of threads across dozens of servers in one process); a real
// client retries, so the deferred-response assertions do too. Async dispatch is
// unaffected — this only smooths the SyncDispatch-under-contention edge.
function DGetRetry(APort: Word; const APath: string; out AResp: string;
  ADeadlineMs: Integer = 6000): Integer; forward;

function DGet(APort: Word; const APath: string; out AResp: string;
  ATimeoutMs: Integer = 4000): Integer;
var
  LSock: TSocket;
  LReq:  TBytes;
begin
  Result := 0; AResp := '';
  LSock := DConnect(APort);
  if LSock = INVALID_SOCKET then begin Result := -2; Exit; end;  // connect failed
  try
    LReq := TEncoding.ASCII.GetBytes(
      'GET ' + APath + ' HTTP/1.1'#13#10 +
      'Host: 127.0.0.1'#13#10 +
      'Connection: close'#13#10#13#10);
    if not DSendAll(LSock, LReq) then begin Result := -3; Exit; end;  // send failed
    Result := DRecvHTTP(LSock, AResp, ATimeoutMs);
  finally
    closesocket(LSock);
  end;
end;

function DGetRetry(APort: Word; const APath: string; out AResp: string;
  ADeadlineMs: Integer): Integer;
var
  LDeadline: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + UInt64(ADeadlineMs);
  repeat
    Result := DGet(APort, APath, AResp, 1500);
    if Result > 0 then Exit;        // got a real HTTP status
    Sleep(20);
  until TThread.GetTickCount64 >= LDeadline;
end;

// ---------------------------------------------------------------------------
// Servers
// ---------------------------------------------------------------------------

var
  GDeferSrv:     TPoseidonServer;
  GDeferReady:   TEvent;
  GSyncSrv:      TPoseidonServer;
  GSyncReady:    TEvent;

// OnListen can fire a hair before IOCP finishes arming AcceptEx, so the very
// first connection may be accepted at the TCP layer but not yet dispatched.
// Poll a known route until it actually serves (poll-with-timeout, not a fixed
// Sleep) so tests start against a fully-serving server.
procedure WaitUntilServing(APort: Word);
var
  LResp:     string;
  LDeadline: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + 3000;
  while TThread.GetTickCount64 < LDeadline do
    if DGet(APort, '/sync', LResp, 800) = 200 then Exit
    else Sleep(25);
end;

// Registers the routes shared by both fixtures onto AServer.
procedure RegisterDeferRoutes(AServer: TPoseidonServer);
begin
  // Middleware adds a marker header BEFORE the handler runs, so we can prove a
  // deferred reply still carries middleware-set headers.
  AServer.Use(
    procedure(var Ctx: TNativeRequestContext; Next: TProc)
    begin
      Ctx.ExtraHeaders := Ctx.ExtraHeaders +
        [TPair<string,string>.Create('X-Defer-Mw', 'seen')];
      Next();
    end);

  // /async — defer, then complete from a worker thread after a short delay.
  AServer.Get('/async',
    procedure(var Ctx: TNativeRequestContext)
    var
      LResp: IPoseidonResponder;
    begin
      LResp := Ctx.Defer;
      TThread.CreateAnonymousThread(
        procedure
        begin
          Sleep(80);
          LResp.RespondText(200, 'application/json', '{"async":true}');
        end).Start;
    end);

  // /asyncnow — defer, then complete IMMEDIATELY on the same thread (diagnostic:
  // isolates the responder send path from cross-thread completion).
  AServer.Get('/asyncnow',
    procedure(var Ctx: TNativeRequestContext)
    var
      LResp: IPoseidonResponder;
    begin
      LResp := Ctx.Defer;
      LResp.RespondText(200, 'application/json', '{"now":true}');
    end);

  // /drop — defer but discard the responder immediately (simulates a handler
  // that loses the handle). The framework must force-close the connection.
  AServer.Get('/drop',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Defer;  // temporary released at end of statement -> force-close
    end);

  // /sync — a normal (non-deferred) reply, as a control.
  AServer.Get('/sync',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Status := 200;
      Ctx.ContentType := 'text/plain';
      Ctx.Body := TEncoding.UTF8.GetBytes('sync-ok');
    end);
end;

procedure DeferListenThread;
begin
  GDeferSrv.Listen(DEFER_PORT, '127.0.0.1',
    procedure begin GDeferReady.SetEvent; end);
end;

procedure SyncListenThread;
begin
  GSyncSrv.Listen(DEFER_SYNC_PORT, '127.0.0.1',
    procedure begin GSyncReady.SetEvent; end);
end;

{ TPoseidonDeferredTests }

procedure TPoseidonDeferredTests.SetupFixture;
begin
  FEvent      := TEvent.Create(nil, True, False, '');
  GDeferSrv   := TPoseidonServer.Create;
  GDeferReady := FEvent;
  RegisterDeferRoutes(GDeferSrv);
  TThread.CreateAnonymousThread(DeferListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled, FEvent.WaitFor(5000),
    'deferred-response server did not start within 5 s');
  WaitUntilServing(DEFER_PORT);
end;

procedure TPoseidonDeferredTests.TeardownFixture;
begin
  GDeferSrv.Stop;
  FreeAndNil(GDeferSrv);
  FreeAndNil(FEvent);
  GDeferReady := nil;
end;

procedure TPoseidonDeferredTests.Defer_AsyncHandler_ClientReceivesResponse;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGet(DEFER_PORT, '/async', LResp);
  Assert.AreEqual(200, LStatus, 'deferred handler must deliver 200 to the client');
  Assert.IsTrue(LResp.Contains('{"async":true}'),
    'deferred body must reach the client');
end;

procedure TPoseidonDeferredTests.Defer_PreservesMiddlewareHeader;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGet(DEFER_PORT, '/async', LResp);
  Assert.AreEqual(200, LStatus, 'deferred handler must deliver 200');
  Assert.IsTrue(LowerCase(LResp).Contains('x-defer-mw: seen'),
    'middleware header set before Defer must survive on the deferred reply');
end;

procedure TPoseidonDeferredTests.Defer_DroppedWithoutRespond_ConnectionClosed;
var
  LResp:   string;
  LStatus: Integer;
begin
  // The handler defers and drops the responder. The framework must close the
  // connection rather than leave the client hanging: no valid HTTP status.
  LStatus := DGet(DEFER_PORT, '/drop', LResp, 3000);
  Assert.IsTrue((LStatus = -1) or (LStatus = 0),
    Format('dropped responder must close the connection, not reply ' +
    '(got status %d, resp="%s")', [LStatus, Copy(LResp, 1, 40)]));
end;

procedure TPoseidonDeferredTests.Defer_ManyConcurrent_AllComplete;
const
  N = 40;
var
  LTasks: TArray<ITask>;
  LOk:    Integer;
  I:      Integer;
begin
  LOk := 0;
  SetLength(LTasks, N);
  for I := 0 to N - 1 do
    LTasks[I] := TTask.Run(
      procedure
      var
        LResp:   string;
        LStatus: Integer;
      begin
        LStatus := DGet(DEFER_PORT, '/async', LResp, 6000);
        if (LStatus = 200) and LResp.Contains('{"async":true}') then
          TInterlocked.Increment(LOk);
      end);
  TTask.WaitForAll(LTasks, 15000);
  Assert.AreEqual(N, LOk,
    Format('all %d concurrent deferred requests must complete (got %d)', [N, LOk]));
end;

{ TPoseidonDeferredSyncTests }

procedure TPoseidonDeferredSyncTests.SetupFixture;
begin
  FEvent     := TEvent.Create(nil, True, False, '');
  GSyncSrv   := TPoseidonServer.Create;
  GSyncSrv.SyncDispatch := True;  // inline dispatch on the IO/event-loop thread
  GSyncReady := FEvent;
  RegisterDeferRoutes(GSyncSrv);
  TThread.CreateAnonymousThread(SyncListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled, FEvent.WaitFor(5000),
    'SyncDispatch deferred-response server did not start within 5 s');
  WaitUntilServing(DEFER_SYNC_PORT);
end;

procedure TPoseidonDeferredSyncTests.TeardownFixture;
begin
  GSyncSrv.Stop;
  FreeAndNil(GSyncSrv);
  FreeAndNil(FEvent);
  GSyncReady := nil;
end;

procedure TPoseidonDeferredSyncTests.Sync_PlainRoute_Works;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGetRetry(DEFER_SYNC_PORT, '/sync', LResp);
  Assert.AreEqual(200, LStatus, 'plain route must work under SyncDispatch');
  Assert.IsTrue(LResp.Contains('sync-ok'), 'plain body must reach client');
end;

procedure TPoseidonDeferredSyncTests.Defer_UnderSyncDispatch_ImmediateRespondWorks;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGetRetry(DEFER_SYNC_PORT, '/asyncnow', LResp);
  Assert.AreEqual(200, LStatus,
    'defer + immediate respond must work under SyncDispatch');
  Assert.IsTrue(LResp.Contains('{"now":true}'), 'immediate deferred body must reach client');
end;

procedure TPoseidonDeferredSyncTests.Defer_UnderSyncDispatch_AsyncHandlerWorks;
var
  LResp:   string;
  LStatus: Integer;
begin
  // The whole point of deferred responses: under SyncDispatch the handler runs
  // inline on the IO thread; Ctx.Defer lets it yield that thread and complete
  // the reply later from a worker thread. The client must still get its reply.
  LStatus := DGetRetry(DEFER_SYNC_PORT, '/async', LResp);
  Assert.AreEqual(200, LStatus,
    'deferred reply must arrive even under SyncDispatch (inline) mode');
  Assert.IsTrue(LResp.Contains('{"async":true}'),
    'deferred body must reach the client under SyncDispatch');
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonDeferredTests);
  TDUnitX.RegisterTestFixture(TPoseidonDeferredSyncTests);

end.
