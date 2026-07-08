unit Poseidon.Tests.HttpServer;

// DUnitX integration tests for TPoseidonNativeServer (HTTP/1.1).
//
// Fixture 1 — TPoseidonHttpServerTests  (port 19001): basic HTTP paths
// Fixture 2 — TPoseidonHttpServerAdvTests (port 19003): security / reliability
//   properties: AllowedMethods, MaxRequestSize, MaxQueueDepth,
//   SecureHeaders, ServerBanner, RateLimit, path traversal, request smuggling.
// Fixture 3 — TPoseidonHttpServerDrainTests (port 19005): R-1 graceful drain
// Fixture 4 — TPoseidonHttpServerWSTests    (port 19006): R-3 MaxWSFrameSize
// Fixture 5 — TPoseidonHttpServerH2CTests   (port 19007): A-5 h2c upgrade
//
// HTTP client: System.Net.HttpClient (Delphi RTL — no external deps).
// Raw TCP: Winapi.Winsock2 blocking sockets for WS and h2c tests.

interface

uses
  DUnitX.TestFramework,
  System.SyncObjs;

type
  {$M+}
  [TestFixture]
  TPoseidonHttpServerTests = class  // port 19001
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    [Test]
    procedure Get_RootPath_Returns200;
    [Test]
    procedure Get_RouteWithParam_ReturnsParamValue;
    [Test]
    procedure Post_WithJsonBody_Returns201;
    [Test]
    procedure Get_UnknownRoute_Returns404;
    [Test]
    procedure Get_HandlerSetsStatus_ReturnsOverriddenStatus;
    [Test]
    procedure Post_Echo_ReflectsBody;
    [Test]
    procedure KeepAlive_MultipleRequests_ReuseConnection;
  end;

  // ── Fixture 2: security / reliability properties ────────────────────────────
  [TestFixture]
  TPoseidonHttpServerAdvTests = class  // port 19003
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    // AllowedMethods (S-1) — moved to middleware; tests removed

    // Path traversal (S-2) — moved to middleware; tests removed
    // Request smuggling (S-4) — moved to middleware; tests removed

    // MaxRequestSize (R-4)
    [Test]
    procedure MaxRequestSize_OversizedBody_Returns413;

    // MaxQueueDepth / backpressure (R-5)
    [Test]
    procedure MaxQueueDepth_QueueFull_Returns503;

    // Secure response headers (A-1)
    [Test]
    procedure SecureHeaders_Enabled_ResponseContainsXContentTypeOptions;
    [Test]
    procedure SecureHeaders_Disabled_ResponseLacksXContentTypeOptions;

    // ServerBanner (A-2)
    [Test]
    procedure ServerBanner_Custom_AppearsInResponseHeader;
    [Test]
    procedure ServerBanner_Empty_ServerHeaderAbsent;

    // Rate limit — moved to middleware; tests removed
  end;

  // ── Fixture 6: idle timeout ─────────────────────────────────────────────────
  [TestFixture]
  TPoseidonHttpServerIdleTests = class  // port 19008
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    // Idle timeout: an open keep-alive TCP connection that sends no data
    // must be closed by the server after IdleTimeoutMs.
    [Test]
    procedure IdleTimeout_InactiveConnection_ClosedByServer;

    // A connection that keeps sending requests must NOT be closed by idle sweep.
    [Test]
    procedure IdleTimeout_ActiveConnection_NotClosed;
  end;

  // ── Fixture 3: graceful drain (R-1) ────────────────────────────────────────
  [TestFixture]
  TPoseidonHttpServerDrainTests = class  // port 19005
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    // R-1: Stop() with no in-flight connections returns without blocking
    [Test]
    procedure Stop_NoInFlight_ReturnsQuickly;

    // R-1: Stop() waits for an in-flight handler to complete before returning
    [Test]
    procedure Stop_WithInFlightHandler_WaitsForCompletion;
  end;

  // ── Fixture 4: MaxWSFrameSize (R-3) ────────────────────────────────────────
  [TestFixture]
  TPoseidonHttpServerWSTests = class  // port 19006
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    // R-3: Server closes connection when frame exceeds MaxWSFrameSize
    [Test]
    procedure MaxWSFrameSize_OversizedFrame_ConnectionClosed;

    // R-3: Frame within limit is processed normally
    [Test]
    procedure MaxWSFrameSize_FrameWithinLimit_Accepted;
  end;

  // ── Fixture 5: h2c cleartext upgrade (A-5) ─────────────────────────────────
  [TestFixture]
  TPoseidonHttpServerH2CTests = class  // port 19007
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    // A-5: Upgrade: h2c request receives 101 Switching Protocols response
    [Test]
    procedure H2CUpgrade_ValidRequest_Returns101;

    // A-5: Request without Upgrade header is served as plain HTTP/1.1
    [Test]
    procedure H2CUpgrade_NoUpgradeHeader_ReturnsNormal200;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading,
  System.DateUtils,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.URLClient,
  Winapi.Windows,
  Winapi.Winsock2,
  Poseidon.Net.Types,
  Poseidon.Net.WebSocket,
  Poseidon.Net.HttpServer;

// Forward declarations — implementations are in the WS fixture section below,
// but these helpers are also used by the Adv fixture (raw socket tests).
function OpenTCPSocket(APort: Word): TSocket; forward;
function SendAll(ASocket: TSocket; const ABuf: TBytes): Boolean; forward;
function RecvSome(ASocket: TSocket; out AOut: TBytes; AMax: Integer = 4096): Integer; forward;

const
  INTEST_PORT = 19001;
  BASE_URL    = 'http://127.0.0.1:19001';

type
  // Alias avoids Delphi parser issue with nested generics (TArray<TPair<X,Y>>)
  // in anonymous-method parameter declarations.
  TExtraHeaders = TArray<TPair<string,string>>;

var
  GServer:      TPoseidonNativeServer;
  GListenReady: TEvent;  // points to FEvent during SetupFixture

// Named procedures for Listen callbacks — avoids parser confusion from
// complex generic types inside anonymous method parameter lists.

procedure TestHttpHandler(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TExtraHeaders);
begin
  AContentType  := 'application/json';
  AExtraHeaders := [];
  if (AReq.Method = 'GET') and (AReq.Path = '/') then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes('{"ok":true}');
  end
  else if (AReq.Method = 'GET') and AReq.Path.StartsWith('/echo/') then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes(
      '{"param":"' + Copy(AReq.Path, 7, MaxInt) + '"}');
  end
  else if AReq.Method = 'POST' then
  begin
    AStatus := 201;
    ABody   := AReq.RawBody;
  end
  else if (AReq.Method = 'GET') and (AReq.Path = '/teapot') then
  begin
    AStatus      := 418;
    AContentType := 'text/plain';
    ABody        := TEncoding.UTF8.GetBytes('I am a teapot');
  end
  else
  begin
    AStatus := 404;
    ABody   := TEncoding.UTF8.GetBytes('not found');
  end;
end;

procedure TestOnListenReady;
begin
  GListenReady.SetEvent;
end;

procedure ListenThread;
begin
  GServer.Listen('127.0.0.1', INTEST_PORT, TestHttpHandler, TestOnListenReady);
end;

{ TPoseidonHttpServerTests }

procedure TPoseidonHttpServerTests.SetupFixture;
begin
  FEvent       := TEvent.Create(nil, True, False, '');
  GServer      := TPoseidonNativeServer.Create;
  GListenReady := FEvent;

  TThread.CreateAnonymousThread(ListenThread).Start;

  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'HTTP/1.1 server did not start within 5 s');
end;

procedure TPoseidonHttpServerTests.TeardownFixture;
begin
  GServer.Stop;
  FreeAndNil(GServer);
  FreeAndNil(FEvent);
  GListenReady := nil;
end;

procedure TPoseidonHttpServerTests.Get_RootPath_Returns200;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get(BASE_URL + '/');
    Assert.AreEqual(200, LResponse.StatusCode);
    Assert.IsTrue(LResponse.ContentAsString.Contains('"ok":true'));
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonHttpServerTests.Get_RouteWithParam_ReturnsParamValue;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get(BASE_URL + '/echo/Poseidon',
      [TNameValuePair.Create('Connection', 'close')]);
    Assert.AreEqual(200, LResponse.StatusCode);
    Assert.IsTrue(LResponse.ContentAsString.Contains('"param":"Poseidon"'));
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonHttpServerTests.Post_WithJsonBody_Returns201;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
  LBody:     TStringStream;
begin
  LClient := THTTPClient.Create;
  LBody   := TStringStream.Create('{"data":1}', TEncoding.UTF8);
  try
    LResponse := LClient.Post(BASE_URL + '/data', LBody, nil,
      [TNameValuePair.Create('Content-Type', 'application/json')]);
    Assert.AreEqual(201, LResponse.StatusCode);
  finally
    LBody.Free;
    LClient.Free;
  end;
end;

procedure TPoseidonHttpServerTests.Get_UnknownRoute_Returns404;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LClient.HandleRedirects := False;
    LResponse := LClient.Get(BASE_URL + '/nao-existe',
      [TNameValuePair.Create('Connection', 'close')]);
    Assert.AreEqual(404, LResponse.StatusCode);
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonHttpServerTests.Get_HandlerSetsStatus_ReturnsOverriddenStatus;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LClient.HandleRedirects := False;
    LResponse := LClient.Get(BASE_URL + '/teapot');
    Assert.AreEqual(418, LResponse.StatusCode);
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonHttpServerTests.Post_Echo_ReflectsBody;
// Verifies that the handler receives RawBody and can echo it verbatim back to
// the caller — covers the POST branch of TestHttpHandler and body parsing.
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
  LBody:     TStringStream;
const
  PAYLOAD = '{"reflected":true}';
begin
  LClient := THTTPClient.Create;
  LBody   := TStringStream.Create(PAYLOAD, TEncoding.UTF8);
  try
    LResponse := LClient.Post(BASE_URL + '/anything', LBody, nil,
      [TNameValuePair.Create('Content-Type', 'application/json'),
       TNameValuePair.Create('Connection', 'close')]);
    Assert.AreEqual(201, LResponse.StatusCode,
      'POST must return 201');
    Assert.AreEqual(PAYLOAD, LResponse.ContentAsString,
      'POST response body must reflect request body verbatim');
  finally
    LBody.Free;
    LClient.Free;
  end;
end;

procedure TPoseidonHttpServerTests.KeepAlive_MultipleRequests_ReuseConnection;
// HTTP/1.1 keep-alive: a single raw TCP socket sends 3 sequential requests
// on the same connection.  Raw sockets avoid WinHTTP connection-pool races
// that cause flaky Error 12030 failures with THTTPClient.
var
  LSock:    TSocket;
  LReq:     TBytes;
  LResp:    TBytes;
  LRespStr: string;
  LRecv:    Integer;
  LTimeout: Integer;
  I:        Integer;
begin
  LSock := OpenTCPSocket(INTEST_PORT);
  try
    Assert.IsTrue(LSock <> INVALID_SOCKET, 'Could not connect to server');
    LTimeout := 2000;
    setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO,
      PAnsiChar(@LTimeout), SizeOf(LTimeout));

    LReq := TEncoding.ASCII.GetBytes(
      'GET / HTTP/1.1'#13#10 +
      'Host: 127.0.0.1'#13#10 +
      'Connection: keep-alive'#13#10#13#10);

    for I := 1 to 3 do
    begin
      Assert.IsTrue(SendAll(LSock, LReq),
        Format('Request %d: send failed on keep-alive connection', [I]));
      LRecv := RecvSome(LSock, LResp, 4096);
      Assert.IsTrue(LRecv > 0,
        Format('Request %d: no response on keep-alive connection', [I]));
      LRespStr := TEncoding.ASCII.GetString(LResp);
      Assert.IsTrue(Pos('200 OK', LRespStr) > 0,
        Format('Request %d on keep-alive must return 200', [I]));
    end;
  finally
    closesocket(LSock);
  end;
end;

// =============================================================================
// Fixture 2 — TPoseidonHttpServerAdvTests (port 19002)
// =============================================================================

const
  ADV_PORT = 19003;
  ADV_BASE = 'http://127.0.0.1:19003';

type
  TAdvExtraHeaders = TArray<TPair<string,string>>;

var
  GAdvServer:      TPoseidonNativeServer;
  GAdvListenReady: TEvent;
  GAdvSlowGate:    TEvent = nil;  // nil = fast; signaled event = blocking handler

procedure AdvHandler(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TAdvExtraHeaders);
begin
  // R-5 test: when a gate is installed, block until released so that
  // concurrent requests accumulate and trigger MaxQueueDepth 503s.
  if Assigned(GAdvSlowGate) then
    GAdvSlowGate.WaitFor(5000);
  AStatus       := 200;
  AContentType  := 'text/plain';
  ABody         := TEncoding.UTF8.GetBytes('ok');
  AExtraHeaders := [];
end;

procedure AdvOnReady;
begin
  GAdvListenReady.SetEvent;
end;

procedure AdvListenThread;
begin
  GAdvServer.Listen('127.0.0.1', ADV_PORT, AdvHandler, AdvOnReady);
end;

{ TPoseidonHttpServerAdvTests }

procedure TPoseidonHttpServerAdvTests.SetupFixture;
begin
  FEvent          := TEvent.Create(nil, True, False, '');
  GAdvServer      := TPoseidonNativeServer.Create;
  GAdvListenReady := FEvent;
  TThread.CreateAnonymousThread(AdvListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'Adv server did not start within 5 s');
end;

procedure TPoseidonHttpServerAdvTests.TeardownFixture;
begin
  GAdvServer.Stop;
  FreeAndNil(GAdvServer);
  FreeAndNil(FEvent);
  GAdvListenReady := nil;
end;

// ── AllowedMethods ────────────────────────────────────────────────────────────

// ── MaxRequestSize ────────────────────────────────────────────────────────────

procedure TPoseidonHttpServerAdvTests.MaxRequestSize_OversizedBody_Returns413;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
  LBody:     TStringStream;
const
  LIMIT = 512;   // very small limit for test
begin
  GAdvServer.MaxRequestSize := LIMIT;
  LClient := THTTPClient.Create;
  LBody   := TStringStream.Create(StringOfChar('x', LIMIT + 100));
  try
    LClient.HandleRedirects := False;
    LResponse := LClient.Post(ADV_BASE + '/', LBody);
    Assert.AreEqual(413, LResponse.StatusCode,
      'Body exceeding MaxRequestSize should return 413');
  finally
    LBody.Free;
    LClient.Free;
    GAdvServer.MaxRequestSize := 8388608;  // restore default (8 MB)
  end;
end;

// ── MaxQueueDepth / backpressure ──────────────────────────────────────────────

procedure TPoseidonHttpServerAdvTests.MaxQueueDepth_QueueFull_Returns503;
// R-5: backpressure test.
// Strategy: install a gate in AdvHandler so the first request blocks inside the
// handler (holding InFlightCount = 1). All subsequent concurrent requests arrive
// while InFlightCount >= MaxQueueDepth and receive 503.
var
  LTasks:  TArray<ITask>;
  LWork:   TProc;
  I:       Integer;
  LGot503: Integer;  // 0 = false, 1 = true (atomic via TInterlocked)
const
  QUEUE_LIMIT = 1;
  FLOOD_COUNT = 20;
begin
  // Create a manual-reset event that starts unsignaled — handler will block.
  GAdvSlowGate := TEvent.Create(nil, True, False, '');
  GAdvServer.MaxQueueDepth := QUEUE_LIMIT;
  LGot503 := 0;
  SetLength(LTasks, FLOOD_COUNT);
  LWork := procedure
    var
      LC: THTTPClient;
      LR: IHTTPResponse;
    begin
      LC := THTTPClient.Create;
      try
        LC.HandleRedirects := False;
        try
          LR := LC.Get(ADV_BASE + '/');
          if LR.StatusCode = 503 then
            TInterlocked.Exchange(LGot503, 1);
        except
        end;
      finally
        LC.Free;
      end;
    end;
  try
    for I := 0 to FLOOD_COUNT - 1 do
      LTasks[I] := TTask.Run(LWork);
    // Allow time for all FLOOD_COUNT tasks to have sent their requests and for
    // the server to have accepted them. The first gets past the 503 check and
    // blocks; the rest should receive 503 while InFlightCount >= QUEUE_LIMIT.
    Sleep(400);
    // Release the gate so the blocked handler can finish and tasks can complete.
    GAdvSlowGate.SetEvent;
    TTask.WaitForAll(LTasks, 8000);
    Assert.IsTrue(LGot503 = 1,
      'At least one request should receive 503 when MaxQueueDepth is exceeded');
  finally
    GAdvServer.MaxQueueDepth := 0;
    FreeAndNil(GAdvSlowGate);
  end;
end;

// ── Secure headers ────────────────────────────────────────────────────────────

procedure TPoseidonHttpServerAdvTests.SecureHeaders_Enabled_ResponseContainsXContentTypeOptions;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  GAdvServer.SecureHeadersEnabled := True;
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get(ADV_BASE + '/');
    Assert.IsTrue(
      LResponse.HeaderValue['X-Content-Type-Options'] = 'nosniff',
      'X-Content-Type-Options: nosniff should be present when SecureHeadersEnabled');
  finally
    LClient.Free;
    GAdvServer.SecureHeadersEnabled := False;
  end;
end;

procedure TPoseidonHttpServerAdvTests.SecureHeaders_Disabled_ResponseLacksXContentTypeOptions;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  GAdvServer.SecureHeadersEnabled := False;
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get(ADV_BASE + '/');
    Assert.IsTrue(
      LResponse.HeaderValue['X-Content-Type-Options'] = '',
      'X-Content-Type-Options should be absent when SecureHeadersEnabled=False');
  finally
    LClient.Free;
  end;
end;

// ── ServerBanner ──────────────────────────────────────────────────────────────

procedure TPoseidonHttpServerAdvTests.ServerBanner_Custom_AppearsInResponseHeader;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  GAdvServer.ServerBanner := 'TestSuite/1.0';
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get(ADV_BASE + '/');
    Assert.AreEqual('TestSuite/1.0', LResponse.HeaderValue['Server'],
      'Server header should match ServerBanner property');
  finally
    LClient.Free;
    GAdvServer.ServerBanner := 'Poseidon/1.0';
  end;
end;

procedure TPoseidonHttpServerAdvTests.ServerBanner_Empty_ServerHeaderAbsent;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  GAdvServer.ServerBanner := '';
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get(ADV_BASE + '/');
    Assert.AreEqual('', LResponse.HeaderValue['Server'],
      'Server header should be absent when ServerBanner is empty');
  finally
    LClient.Free;
    GAdvServer.ServerBanner := 'Poseidon/1.0';
  end;
end;

// ── Request smuggling (S-4) ─── moved to middleware ──────────────────────────

// Smuggling_CLAndChunked test removed — enforcement moved to middleware.

// =============================================================================
// Fixture 3 — TPoseidonHttpServerDrainTests (port 19005)
// R-1: event-based graceful drain
// =============================================================================

const
  DRAIN_PORT = 19005;
  DRAIN_BASE = 'http://127.0.0.1:19005';

type
  TDrainExtraHeaders = TArray<TPair<string,string>>;

var
  GDrainServer:      TPoseidonNativeServer;
  GDrainListenReady: TEvent;
  GDrainGate:        TEvent;  // handler blocks until gate is set

procedure DrainHandler(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TDrainExtraHeaders);
begin
  AStatus       := 200;
  AContentType  := 'text/plain';
  AExtraHeaders := [];
  // If /slow — block until gate is signaled (used by drain tests)
  if (AReq.Path = '/slow') and Assigned(GDrainGate) then
    GDrainGate.WaitFor(5000);
  ABody := TEncoding.UTF8.GetBytes('ok');
end;

procedure DrainOnReady;
begin
  GDrainListenReady.SetEvent;
end;

procedure DrainListenThread;
begin
  GDrainServer.Listen('127.0.0.1', DRAIN_PORT, DrainHandler, DrainOnReady);
end;

{ TPoseidonHttpServerDrainTests }

procedure TPoseidonHttpServerDrainTests.SetupFixture;
begin
  FEvent            := TEvent.Create(nil, True, False, '');
  GDrainServer      := TPoseidonNativeServer.Create;
  GDrainListenReady := FEvent;
  GDrainGate        := nil;
  TThread.CreateAnonymousThread(DrainListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'Drain server did not start within 5 s');
end;

procedure TPoseidonHttpServerDrainTests.TeardownFixture;
begin
  GDrainServer.Stop;
  FreeAndNil(GDrainServer);
  FreeAndNil(FEvent);
  GDrainListenReady := nil;
end;

procedure TPoseidonHttpServerDrainTests.Stop_NoInFlight_ReturnsQuickly;
// R-1: Stop() on a server with no in-flight connections must return in well
// under DrainTimeoutMs.  We create a dedicated one-shot server to measure this.
var
  LServer:  TPoseidonNativeServer;
  LReady:   TEvent;
  LStart:   TDateTime;
  LElapsed: Integer;
begin
  LReady  := TEvent.Create(nil, True, False, '');
  LServer := TPoseidonNativeServer.Create;
  LServer.DrainTimeoutMs := 2000;  // keep test fast
  try
    TThread.CreateAnonymousThread(
      procedure
      begin
        LServer.Listen('127.0.0.1', 19055,
          procedure(const AReq: TPoseidonNativeRequest;
            out AStatus: Integer; out AContentType: string;
            out ABody: TBytes; out AExtraHeaders: TDrainExtraHeaders)
          begin
            AStatus := 200; AContentType := 'text/plain';
            ABody := TEncoding.UTF8.GetBytes('ok'); AExtraHeaders := [];
          end,
          procedure begin LReady.SetEvent; end);
      end).Start;
    Assert.AreEqual(TWaitResult.wrSignaled, LReady.WaitFor(5000),
      'One-shot server did not start');
    LStart := Now;
    LServer.Stop;
    LElapsed := MilliSecondsBetween(Now, LStart);
    Assert.IsTrue(LElapsed < 1500,
      Format('Stop() with no in-flight connections took %d ms (expected < 1500)', [LElapsed]));
  finally
    LReady.Free;
    LServer.Free;
  end;
end;

procedure TPoseidonHttpServerDrainTests.Stop_WithInFlightHandler_WaitsForCompletion;
// R-1: Stop() must block while a handler is executing and return only after
// the handler completes (not before, not with a hard timeout when drain is short).
var
  LGate:        TEvent;
  LHandlerDone: TEvent;
  LStopDone:    TEvent;
  LStopTask:    ITask;
  LReqTask:     ITask;
  LGateRelease: TDateTime;
  LElapsed:     Integer;
begin
  LGate        := TEvent.Create(nil, True, False, '');
  LHandlerDone := TEvent.Create(nil, True, False, '');
  LStopDone    := TEvent.Create(nil, True, False, '');
  GDrainGate   := LGate;
  try
    // Send an async request that will block the handler on LGate
    LReqTask := TTask.Run(
      procedure
      var
        LC: THTTPClient;
      begin
        LC := THTTPClient.Create;
        try
          try LC.Get(DRAIN_BASE + '/slow'); except end;
        finally
          LC.Free;
        end;
        LHandlerDone.SetEvent;
      end);

    Sleep(200);  // give the request time to reach the handler

    // Start Stop() asynchronously
    LStopTask := TTask.Run(
      procedure
      begin
        GDrainServer.Stop;
        LStopDone.SetEvent;
      end);

    Sleep(200);  // give Stop() time to begin waiting

    // Verify Stop() has not returned yet (handler still blocked)
    Assert.AreNotEqual(TWaitResult.wrSignaled, LStopDone.WaitFor(0),
      'Stop() must not complete while handler is still running');

    // Release the handler gate
    LGateRelease := Now;
    LGate.SetEvent;

    // Stop() must complete within 3 s after gate release
    Assert.AreEqual(TWaitResult.wrSignaled, LStopDone.WaitFor(3000),
      'Stop() must complete after handler finishes');

    LElapsed := MilliSecondsBetween(Now, LGateRelease);
    Assert.IsTrue(LElapsed < 2000,
      Format('Stop() took %d ms after gate release (expected < 2000)', [LElapsed]));

    LReqTask.Wait(3000);

    // Re-create server for TeardownFixture (which calls Stop again)
    FEvent.ResetEvent;
    GDrainServer := TPoseidonNativeServer.Create;
    GDrainListenReady := FEvent;
    TThread.CreateAnonymousThread(DrainListenThread).Start;
    FEvent.WaitFor(5000);
  finally
    GDrainGate := nil;
    LGate.Free;
    LHandlerDone.Free;
    LStopDone.Free;
  end;
end;

// =============================================================================
// Fixture 4 — TPoseidonHttpServerWSTests (port 19006)
// R-3: MaxWSFrameSize — oversized WS frame causes server to close connection
// =============================================================================
// These tests use a raw Winsock2 blocking socket to perform the WebSocket
// handshake and then send frames directly, so that frame-size enforcement
// can be observed at the TCP level.

const
  WS_PORT = 19006;

type
  // Alias avoids Delphi parser issue with nested generics in anonymous methods.
  TWSExtraHeaders = TArray<TPair<string,string>>;

var
  GWSServer:      TPoseidonNativeServer;
  GWSListenReady: TEvent;

procedure WSOnReady;
begin
  GWSListenReady.SetEvent;
end;

procedure WSListenThread;
begin
  // Register WebSocket handler BEFORE Listen (Listen is blocking)
  GWSServer.RegisterWSHandler('/ws',
    procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame)
    begin
      if AFrame.Opcode = $01 then  // $01 = text opcode (RFC 6455)
        AConn.Send(TEncoding.UTF8.GetString(AFrame.Payload));
    end);
  GWSServer.Listen('127.0.0.1', WS_PORT,
    procedure(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes;
      out AExtraHeaders: TWSExtraHeaders)
    begin
      AStatus := 200; AContentType := 'text/plain';
      ABody := TEncoding.UTF8.GetBytes('ok'); AExtraHeaders := [];
    end,
    WSOnReady);
end;

// Open a blocking Winsock2 socket connected to 127.0.0.1:APort.
// Returns INVALID_SOCKET on failure.
function OpenTCPSocket(APort: Word): TSocket;
var
  LAddr: TSockAddrIn;
begin
  Result := socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if Result = INVALID_SOCKET then
    Exit;
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

// Send all bytes in ABuf over ASocket (blocking).
function SendAll(ASocket: TSocket; const ABuf: TBytes): Boolean;
var
  LTotal, LSent, LRem: Integer;
begin
  LTotal := 0;
  LRem   := Length(ABuf);
  while LRem > 0 do
  begin
    LSent := send(ASocket, ABuf[LTotal], LRem, 0);
    if LSent <= 0 then
      Exit(False);
    Inc(LTotal, LSent);
    Dec(LRem, LSent);
  end;
  Result := True;
end;

// Receive up to AMax bytes from ASocket into AOut.
// Returns number of bytes received; 0 on disconnect; -1 on error.
function RecvSome(ASocket: TSocket; out AOut: TBytes; AMax: Integer = 4096): Integer;
begin
  SetLength(AOut, AMax);
  Result := recv(ASocket, AOut[0], AMax, 0);
  if Result > 0 then
    SetLength(AOut, Result)
  else
    SetLength(AOut, 0);
end;

// Perform HTTP/1.1 WebSocket upgrade handshake on ASocket.
// Returns True if the server responded with 101 Switching Protocols.
function DoWSHandshake(ASocket: TSocket; const APath: string): Boolean;
var
  LReq: TBytes;
  LResp: TBytes;
  LRespStr: string;
  LKey: string;
  LTimeout: Integer;
begin
  LKey := 'dGhlIHNhbXBsZSBub25jZQ==';  // RFC 6455 test vector key
  LReq := TEncoding.ASCII.GetBytes(
    'GET ' + APath + ' HTTP/1.1'#13#10 +
    'Host: 127.0.0.1'#13#10 +
    'Upgrade: websocket'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Sec-WebSocket-Key: ' + LKey + #13#10 +
    'Sec-WebSocket-Version: 13'#13#10#13#10);
  if not SendAll(ASocket, LReq) then
    Exit(False);
  LTimeout := 2000;
  setsockopt(ASocket, SOL_SOCKET, SO_RCVTIMEO,
    PAnsiChar(@LTimeout), SizeOf(LTimeout));
  RecvSome(ASocket, LResp, 1024);
  LRespStr := TEncoding.ASCII.GetString(LResp);
  Result := Pos('101 Switching Protocols', LRespStr) > 0;
end;

// Build a raw (unmasked) WebSocket frame with given opcode and payload.
// Client→Server frames must be masked (RFC 6455 §5.3); we use a zero mask for
// simplicity.  The server validates the FIN bit but not the mask in tests.
function BuildRawWSFrame(AOpcode: Byte; const APayload: TBytes): TBytes;
var
  LPayLen: Int64;
  LHeader: TBytes;
begin
  LPayLen := Length(APayload);
  if LPayLen < 126 then
  begin
    SetLength(LHeader, 6);  // 2 header + 4 mask
    LHeader[0] := $80 or AOpcode;          // FIN + opcode
    LHeader[1] := $80 or Byte(LPayLen);    // MASK bit + 1-byte length
    LHeader[2] := 0; LHeader[3] := 0;
    LHeader[4] := 0; LHeader[5] := 0;     // zero mask
  end
  else if LPayLen <= 65535 then
  begin
    SetLength(LHeader, 8);
    LHeader[0] := $80 or AOpcode;
    LHeader[1] := $80 or 126;
    LHeader[2] := Byte((LPayLen shr 8) and $FF);
    LHeader[3] := Byte( LPayLen        and $FF);
    LHeader[4] := 0; LHeader[5] := 0;
    LHeader[6] := 0; LHeader[7] := 0;     // zero mask
  end
  else
  begin
    SetLength(LHeader, 14);
    LHeader[0] := $80 or AOpcode;
    LHeader[1] := $80 or 127;
    LHeader[2]  := 0; LHeader[3]  := 0;
    LHeader[4]  := 0; LHeader[5]  := 0;
    LHeader[6]  := Byte((LPayLen shr 24) and $FF);
    LHeader[7]  := Byte((LPayLen shr 16) and $FF);
    LHeader[8]  := Byte((LPayLen shr  8) and $FF);
    LHeader[9]  := Byte( LPayLen         and $FF);
    LHeader[10] := 0; LHeader[11] := 0;
    LHeader[12] := 0; LHeader[13] := 0;   // zero mask
  end;
  SetLength(Result, Length(LHeader) + Length(APayload));
  Move(LHeader[0],  Result[0],              Length(LHeader));
  if Length(APayload) > 0 then
    Move(APayload[0], Result[Length(LHeader)], Length(APayload));
end;

{ TPoseidonHttpServerWSTests }

procedure TPoseidonHttpServerWSTests.SetupFixture;
begin
  FEvent         := TEvent.Create(nil, True, False, '');
  GWSServer      := TPoseidonNativeServer.Create;
  GWSListenReady := FEvent;
  TThread.CreateAnonymousThread(WSListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'WS server did not start within 5 s');
end;

procedure TPoseidonHttpServerWSTests.TeardownFixture;
begin
  GWSServer.Stop;
  FreeAndNil(GWSServer);
  FreeAndNil(FEvent);
  GWSListenReady := nil;
end;

procedure TPoseidonHttpServerWSTests.MaxWSFrameSize_OversizedFrame_ConnectionClosed;
// R-3: Server must close the connection when a frame payload exceeds MaxWSFrameSize.
var
  LSock:      TSocket;
  LPayload:   TBytes;
  LFrame:     TBytes;
  LResp:      TBytes;
  LRecv:      Integer;
  LTimeoutMs: Integer;
const
  FRAME_LIMIT = 512;      // very small limit for test
  OVERSIZED   = 600;
begin
  GWSServer.MaxWSFrameSize := FRAME_LIMIT;
  LSock := OpenTCPSocket(WS_PORT);
  try
    Assert.IsTrue(LSock <> INVALID_SOCKET, 'Could not connect to WS server');

    Assert.IsTrue(DoWSHandshake(LSock, '/ws'), 'WebSocket handshake failed');

    // Build and send an oversized text frame
    SetLength(LPayload, OVERSIZED);
    FillChar(LPayload[0], OVERSIZED, Ord('x'));
    LFrame := BuildRawWSFrame($01 {text}, LPayload);
    SendAll(LSock, LFrame);

    // Server should send a close frame (opcode 8) then close the connection.
    // Either we receive data with close opcode, or recv returns 0 (disconnect).
    LTimeoutMs := 2000;
    setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO,
      PAnsiChar(@LTimeoutMs), SizeOf(LTimeoutMs));
    LRecv := RecvSome(LSock, LResp, 1024);
    Assert.IsTrue((LRecv = 0) or
      ((LRecv >= 2) and ((LResp[0] and $0F) = $08)),
      'Server must close connection (recv=0) or send close frame (opcode 8) ' +
      'for oversized WS frame');
  finally
    closesocket(LSock);
    GWSServer.MaxWSFrameSize := 16 * 1024 * 1024;  // restore default
  end;
end;

procedure TPoseidonHttpServerWSTests.MaxWSFrameSize_FrameWithinLimit_Accepted;
// R-3: A PING frame within MaxWSFrameSize must be answered with a PONG frame.
// PING/PONG is handled unconditionally by the server (RFC 6455 §5.5.2),
// so no message handler registration is required.
var
  LSock:      TSocket;
  LPing:      TBytes;
  LResp:      TBytes;
  LRecv:      Integer;
  LTimeoutMs: Integer;
const
  FRAME_LIMIT     = 1024;
  RECV_TIMEOUT_MS = 2000;
begin
  GWSServer.MaxWSFrameSize := FRAME_LIMIT;
  LSock := OpenTCPSocket(WS_PORT);
  try
    Assert.IsTrue(LSock <> INVALID_SOCKET, 'Could not connect to WS server');
    Assert.IsTrue(DoWSHandshake(LSock, '/ws'), 'WebSocket handshake failed');

    // Set a recv timeout so the test never blocks indefinitely
    LTimeoutMs := RECV_TIMEOUT_MS;
    setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO,
      PAnsiChar(@LTimeoutMs), SizeOf(LTimeoutMs));

    // Send a masked PING frame (RFC 6455 §5.5.2) — no payload, well within limit
    LPing := BuildRawWSFrame($09 {ping}, nil);
    SendAll(LSock, LPing);

    LRecv := RecvSome(LSock, LResp, 256);

    // Must receive a PONG frame (opcode $0A = $8A with FIN bit = $80|$0A)
    Assert.IsTrue(LRecv > 0,
      Format('Server must reply to PING (recv returned %d)', [LRecv]));
    Assert.AreEqual($0A, Integer(LResp[0] and $0F),
      'Server must respond to PING with PONG (opcode 0x0A)');
  finally
    closesocket(LSock);
    GWSServer.MaxWSFrameSize := 16 * 1024 * 1024;
  end;
end;

// =============================================================================
// Fixture 5 — TPoseidonHttpServerH2CTests (port 19007)
// A-5: h2c cleartext upgrade via Upgrade: h2c header (RFC 7540 §3.2)
// =============================================================================

const
  H2C_PORT = 19007;

type
  TH2CExtraHeaders = TArray<TPair<string,string>>;

var
  GH2CServer:      TPoseidonNativeServer;
  GH2CListenReady: TEvent;

procedure H2COnReady;
begin
  GH2CListenReady.SetEvent;
end;

procedure H2CListenThread;
begin
  GH2CServer.Listen('127.0.0.1', H2C_PORT,
    procedure(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes;
      out AExtraHeaders: TH2CExtraHeaders)
    begin
      AStatus := 200; AContentType := 'application/json';
      ABody := TEncoding.UTF8.GetBytes('{"ok":true}'); AExtraHeaders := [];
    end,
    H2COnReady);
end;

{ TPoseidonHttpServerH2CTests }

procedure TPoseidonHttpServerH2CTests.SetupFixture;
begin
  FEvent          := TEvent.Create(nil, True, False, '');
  GH2CServer      := TPoseidonNativeServer.Create;
  GH2CServer.HTTP2Enabled := True;  // A-5: h2c requires HTTP2Enabled
  GH2CListenReady := FEvent;
  TThread.CreateAnonymousThread(H2CListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'h2c server did not start within 5 s');
end;

procedure TPoseidonHttpServerH2CTests.TeardownFixture;
begin
  GH2CServer.Stop;
  FreeAndNil(GH2CServer);
  FreeAndNil(FEvent);
  GH2CListenReady := nil;
end;

procedure TPoseidonHttpServerH2CTests.H2CUpgrade_ValidRequest_Returns101;
// A-5: A request with Upgrade: h2c and HTTP2-Settings must receive
// 101 Switching Protocols followed by a SETTINGS frame.
var
  LSock:      TSocket;
  LReq:       TBytes;
  LResp:      TBytes;
  LRespStr:   string;
  LTimeout:   Integer;
begin
  LSock := OpenTCPSocket(H2C_PORT);
  try
    Assert.IsTrue(LSock <> INVALID_SOCKET, 'Could not connect to h2c server');

    LTimeout := 2000;
    setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO,
      PAnsiChar(@LTimeout), SizeOf(LTimeout));

    // RFC 7540 §3.2 upgrade request
    // HTTP2-Settings is a base64url of a SETTINGS payload (empty = no settings)
    LReq := TEncoding.ASCII.GetBytes(
      'GET / HTTP/1.1'#13#10 +
      'Host: 127.0.0.1'#13#10 +
      'Connection: Upgrade, HTTP2-Settings'#13#10 +
      'Upgrade: h2c'#13#10 +
      'HTTP2-Settings: AAMAAABkAAQAAP__'#13#10#13#10);
    Assert.IsTrue(SendAll(LSock, LReq), 'Failed to send h2c upgrade request');

    // Read server response — should start with HTTP/1.1 101
    RecvSome(LSock, LResp, 2048);
    LRespStr := TEncoding.ASCII.GetString(LResp);
    Assert.IsTrue(
      Pos('101 Switching Protocols', LRespStr) > 0,
      'Server must respond with 101 Switching Protocols for Upgrade: h2c request. ' +
      'Got: ' + Copy(LRespStr, 1, 80));
  finally
    closesocket(LSock);
  end;
end;

procedure TPoseidonHttpServerH2CTests.H2CUpgrade_NoUpgradeHeader_ReturnsNormal200;
// A-5: A plain HTTP/1.1 request (no Upgrade header) must be served normally.
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get('http://127.0.0.1:' + IntToStr(H2C_PORT) + '/');
    Assert.AreEqual(200, LResponse.StatusCode,
      'Plain HTTP/1.1 request to h2c-enabled server must return 200');
  finally
    LClient.Free;
  end;
end;

// =============================================================================
// Fixture 6 — TPoseidonHttpServerIdleTests (port 19008)
// IdleTimeoutMs: connections with no inbound bytes for IdleTimeoutMs are closed.
// =============================================================================

const
  IDLE_PORT = 19008;

type
  TIdleExtraHeaders = TArray<TPair<string,string>>;

var
  GIdleServer:      TPoseidonNativeServer;
  GIdleListenReady: TEvent;

procedure IdleOnReady;
begin
  GIdleListenReady.SetEvent;
end;

procedure IdleListenThread;
begin
  GIdleServer.Listen('127.0.0.1', IDLE_PORT,
    procedure(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes;
      out AExtraHeaders: TIdleExtraHeaders)
    begin
      AStatus := 200; AContentType := 'text/plain';
      ABody := TEncoding.UTF8.GetBytes('ok'); AExtraHeaders := [];
    end,
    IdleOnReady);
end;

{ TPoseidonHttpServerIdleTests }

procedure TPoseidonHttpServerIdleTests.SetupFixture;
begin
  FEvent           := TEvent.Create(nil, True, False, '');
  GIdleServer      := TPoseidonNativeServer.Create;
  GIdleServer.IdleTimeoutMs := 500;   // very short — makes tests fast
  GIdleListenReady := FEvent;
  TThread.CreateAnonymousThread(IdleListenThread).Start;
  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'Idle server did not start within 5 s');
end;

procedure TPoseidonHttpServerIdleTests.TeardownFixture;
begin
  GIdleServer.Stop;
  FreeAndNil(GIdleServer);
  FreeAndNil(FEvent);
  GIdleListenReady := nil;
end;

procedure TPoseidonHttpServerIdleTests.IdleTimeout_InactiveConnection_ClosedByServer;
// Open a raw TCP connection, perform the HTTP/1.1 handshake to ensure the
// connection is accepted (LastActivity is set), then go silent.
// After IdleTimeoutMs + sweep interval the server should close the socket —
// observed as recv() returning 0 (FIN) on the client side.
var
  LSock:    TSocket;
  LReq:     TBytes;
  LResp:    TBytes;
  LRecv:    Integer;
  LTimeout: DWORD;
begin
  LSock := OpenTCPSocket(IDLE_PORT);
  try
    Assert.IsTrue(LSock <> INVALID_SOCKET,
      'Could not connect to idle-timeout server');

    // Send one complete request so the server accepts the connection and sets
    // LastActivity on it.
    LReq := TEncoding.ASCII.GetBytes(
      'GET / HTTP/1.1'#13#10 +
      'Host: 127.0.0.1'#13#10 +
      'Connection: keep-alive'#13#10#13#10);
    Assert.IsTrue(SendAll(LSock, LReq), 'Failed to send initial request');

    // Consume the response so the socket buffer is drained.
    Sleep(200);
    RecvSome(LSock, LResp, 4096);

    // Now go silent for 2× IdleTimeoutMs + 1.5 s sweep window.
    // GIdleServer.IdleTimeoutMs = 500; sweep runs every ~1 s; worst case ~1.5 s.
    Sleep(2200);

    // The server should have sent a FIN — recv() must return 0 or an error.
    LTimeout := 500;  // ms
    setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO,
      PAnsiChar(@LTimeout), SizeOf(LTimeout));
    LRecv := RecvSome(LSock, LResp, 1);
    Assert.IsTrue(LRecv <= 0,
      'Server should have closed the idle connection (recv must return 0 or error)');
  finally
    closesocket(LSock);
  end;
end;

procedure TPoseidonHttpServerIdleTests.IdleTimeout_ActiveConnection_NotClosed;
// A connection that sends a request every 200 ms must never be swept.
// After 1.5 s (3× sweep window) the connection should still be alive.
var
  LSock:   TSocket;
  LReq:    TBytes;
  LResp:   TBytes;
  I:       Integer;
  LRecv:   Integer;
  LTimeout: DWORD;
begin
  LSock := OpenTCPSocket(IDLE_PORT);
  try
    Assert.IsTrue(LSock <> INVALID_SOCKET,
      'Could not connect to idle-timeout server');

    LReq := TEncoding.ASCII.GetBytes(
      'GET / HTTP/1.1'#13#10 +
      'Host: 127.0.0.1'#13#10 +
      'Connection: keep-alive'#13#10#13#10);

    LTimeout := 2000;
    setsockopt(LSock, SOL_SOCKET, SO_RCVTIMEO,
      PAnsiChar(@LTimeout), SizeOf(LTimeout));

    for I := 1 to 6 do
    begin
      Assert.IsTrue(SendAll(LSock, LReq),
        Format('Request %d failed on active connection', [I]));
      LRecv := RecvSome(LSock, LResp, 4096);
      Assert.IsTrue(LRecv > 0,
        Format('Request %d: no response on active connection', [I]));
      Sleep(200);
    end;

    // Connection must still be alive — a fresh request should succeed.
    Assert.IsTrue(SendAll(LSock, LReq),
      'Active connection should still be open after activity');
    LRecv := RecvSome(LSock, LResp, 4096);
    Assert.IsTrue(LRecv > 0,
      'Active connection must still receive a response after continuous activity');
  finally
    closesocket(LSock);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonHttpServerTests);
  TDUnitX.RegisterTestFixture(TPoseidonHttpServerAdvTests);
  TDUnitX.RegisterTestFixture(TPoseidonHttpServerDrainTests);
  TDUnitX.RegisterTestFixture(TPoseidonHttpServerWSTests);
  TDUnitX.RegisterTestFixture(TPoseidonHttpServerH2CTests);
  TDUnitX.RegisterTestFixture(TPoseidonHttpServerIdleTests);

end.
