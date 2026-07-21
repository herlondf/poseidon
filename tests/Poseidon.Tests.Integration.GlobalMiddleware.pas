unit Poseidon.Tests.Integration.GlobalMiddleware;

// Integration test for the global-middleware dispatch fix: a global middleware
// (App.Use) that serves its own path must run EVEN WHEN no route matches — the
// pattern behind MetricsMiddleware / StaticMiddleware / CORS. Before the fix the
// router returned 404 before the global chain ran, so those middlewares were
// silently dead on their own paths. A truly-unhandled path must still 404.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TGlobalMiddlewareTests = class
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    [Test]
    procedure GlobalMiddleware_ServesUnmatchedPath_Returns200;
    [Test]
    procedure GlobalMiddleware_UnmatchedAndUnhandled_Returns404;
    [Test]
    procedure NormalRoute_StillWorks_Returns200;
    [Test]
    procedure GlobalMiddleware_RunsBeforeMatchedRoute;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Winapi.Winsock2,
  Poseidon.Native.Types,
  Poseidon.Native.Server;

const
  GM_PORT = 19020;

// --- Raw blocking Winsock2 client (request + complete-response read) ---------

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

function DRecvHTTP(ASock: TSocket; out AResp: string; ATimeoutMs: Integer): Integer;
var
  LBuf:      TBytes;
  LTotal, LRecvd, LHdrEnd, LBodyLen, LP, LE, I: Integer;
  LChunk:    array[0..4095] of Byte;
  LDeadline: UInt64;
  LTmo:      Integer;
  LHdrs:     string;
begin
  Result := 0; AResp := ''; LTotal := 0; LHdrEnd := -1; LBodyLen := -1;
  SetLength(LBuf, 0);
  LTmo := 400;
  setsockopt(ASock, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@LTmo), SizeOf(LTmo));
  LDeadline := TThread.GetTickCount64 + UInt64(ATimeoutMs);

  while TThread.GetTickCount64 < LDeadline do
  begin
    LRecvd := recv(ASock, LChunk[0], SizeOf(LChunk), 0);
    if LRecvd = 0 then Break;      // FIN
    if LRecvd < 0 then Continue;   // timeout tick

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

  if LTotal = 0 then Exit;
  AResp := TEncoding.ASCII.GetString(LBuf, 0, LTotal);
  LP := Pos('HTTP/1.', AResp);
  if LP > 0 then
    Result := StrToIntDef(Copy(AResp, LP + 9, 3), 0);
end;

function DGet(APort: Word; const APath: string; out AResp: string;
  ATimeoutMs: Integer = 4000): Integer;
var
  LSock: TSocket;
  LReq:  TBytes;
begin
  Result := 0; AResp := '';
  LSock := DConnect(APort);
  if LSock = INVALID_SOCKET then begin Result := -2; Exit; end;
  try
    LReq := TEncoding.ASCII.GetBytes(
      'GET ' + APath + ' HTTP/1.1'#13#10 +
      'Host: 127.0.0.1'#13#10 +
      'Connection: close'#13#10#13#10);
    if not DSendAll(LSock, LReq) then begin Result := -3; Exit; end;
    Result := DRecvHTTP(LSock, AResp, ATimeoutMs);
  finally
    closesocket(LSock);
  end;
end;

// --- Server ------------------------------------------------------------------

var
  GSrv:   TPoseidonServer;
  GReady: TEvent;

procedure RegisterRoutes(AServer: TPoseidonServer);
begin
  // Global middleware that serves its own path '/gm' with no registered route,
  // and tags every request with a marker header so we can prove it ran even for
  // a matched route.
  AServer.Use(
    procedure(var Ctx: TNativeRequestContext; Next: TProc)
    begin
      Ctx.ExtraHeaders := Ctx.ExtraHeaders +
        [TPair<string,string>.Create('X-Global-Mw', 'seen')];
      if Ctx.Path.TrimRight(['/']) = '/gm' then
      begin
        Ctx.Status := 200;
        Ctx.ContentType := 'text/plain';
        Ctx.Body := TEncoding.UTF8.GetBytes('gm-ok');
        Ctx.Handled := True;
        Exit;
      end;
      Next();
    end);

  AServer.Get('/hello',
    procedure(var Ctx: TNativeRequestContext)
    begin
      Ctx.Status := 200;
      Ctx.ContentType := 'text/plain';
      Ctx.Body := TEncoding.UTF8.GetBytes('hello-ok');
    end);
end;

procedure ListenThread;
begin
  GSrv.Listen(GM_PORT, '127.0.0.1',
    procedure begin GReady.SetEvent; end);
end;

procedure WaitUntilServing(APort: Word);
var
  LResp:     string;
  LDeadline: UInt64;
begin
  LDeadline := TThread.GetTickCount64 + 3000;
  while TThread.GetTickCount64 < LDeadline do
    if DGet(APort, '/hello', LResp, 800) = 200 then Exit
    else Sleep(25);
end;

{ TGlobalMiddlewareTests }

procedure TGlobalMiddlewareTests.SetupFixture;
begin
  GReady := TEvent.Create(nil, True, False, '');
  GSrv := TPoseidonServer.Create;
  RegisterRoutes(GSrv);
  TThread.CreateAnonymousThread(ListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled, GReady.WaitFor(5000),
    'global-middleware server did not start within 5 s');
  WaitUntilServing(GM_PORT);
end;

procedure TGlobalMiddlewareTests.TeardownFixture;
begin
  GSrv.Stop;
  FreeAndNil(GSrv);
  FreeAndNil(GReady);
end;

procedure TGlobalMiddlewareTests.GlobalMiddleware_ServesUnmatchedPath_Returns200;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGet(GM_PORT, '/gm', LResp);
  Assert.AreEqual(200, LStatus,
    'a global middleware must serve its own path even with no matched route');
  Assert.IsTrue(LResp.Contains('gm-ok'), 'global-middleware body must reach the client');
end;

procedure TGlobalMiddlewareTests.GlobalMiddleware_UnmatchedAndUnhandled_Returns404;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGet(GM_PORT, '/does-not-exist', LResp);
  Assert.AreEqual(404, LStatus,
    'a path no route and no global middleware handles must still 404');
end;

procedure TGlobalMiddlewareTests.NormalRoute_StillWorks_Returns200;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGet(GM_PORT, '/hello', LResp);
  Assert.AreEqual(200, LStatus, 'a normal matched route must still work');
  Assert.IsTrue(LResp.Contains('hello-ok'), 'route body must reach the client');
end;

procedure TGlobalMiddlewareTests.GlobalMiddleware_RunsBeforeMatchedRoute;
var
  LResp:   string;
  LStatus: Integer;
begin
  LStatus := DGet(GM_PORT, '/hello', LResp);
  Assert.AreEqual(200, LStatus, 'matched route must return 200');
  Assert.IsTrue(LowerCase(LResp).Contains('x-global-mw: seen'),
    'global middleware must also run (and tag) matched-route requests');
end;

initialization
  TDUnitX.RegisterTestFixture(TGlobalMiddlewareTests);

end.
