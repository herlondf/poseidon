unit Poseidon.Tests.Dispatcher;

// Unit tests for TProtocolDispatcher (Poseidon.Net.Dispatcher).
//
// Tests routing logic in isolation via a mock IDispatchCallbacks — no live
// server, no sockets.  Each test builds a TNativeConn with a pre-filled
// accumulation buffer, creates a TDispatchConfig, and calls Dispatch.
//
// Fixtures:
//   TDispatcherMethodTests     — S-1: method allowlist
//   TDispatcherPathTests       — S-2: path traversal
//   TDispatcherRateLimitTests  — rate limit callback integration
//   TDispatcherBackpressureTests — R-5: MaxQueueDepth → 503
//   TDispatcherMetricsTests    — Prometheus metrics endpoint routing

interface

uses
  DUnitX.TestFramework;

type
  {$M+}

  [TestFixture]
  TDispatcherMethodTests = class
  public
    [Test] procedure AllowedMethod_GET_InvokesHandler;
    [Test] procedure DisallowedMethod_DELETE_Returns405;
    [Test] procedure DisallowedMethod_DoesNotInvokeHandler;
    [Test] procedure EmptyAllowlist_AllowsAllMethods;
  end;

  [TestFixture]
  TDispatcherPathTests = class
  public
    [Test] procedure SafePath_Root_Dispatched;
    [Test] procedure DotDotSegment_Returns400;
    [Test] procedure PercentEncodedDotDot_Returns400;
    [Test] procedure NullByte_Returns400;
  end;

  [TestFixture]
  TDispatcherRateLimitTests = class
  public
    [Test] procedure RateLimitAllowed_HandlerInvoked;
    [Test] procedure RateLimitDenied_ReturnsRateLimitStatus;
    [Test] procedure RateLimitDenied_HandlerNotInvoked;
  end;

  // R-5 backpressure was moved from Dispatcher to HttpServer._DispatchAccumBuf.
  // Dispatcher now always receives MaxQueueDepth=0 (no check).  These tests
  // verify the Dispatcher passes requests through regardless of config values.
  [TestFixture]
  TDispatcherBackpressureTests = class
  public
    [Test] procedure QueueNotFull_HandlerInvoked;
    [Test] procedure QueueFull_DispatcherPassesThrough;
    [Test] procedure QueueFull_HandlerStillInvoked;
    [Test] procedure MaxQueueDepthZero_NoBackpressure;
  end;

  [TestFixture]
  TDispatcherMetricsTests = class
  public
    [Test] procedure MetricsDisabled_HandlerInvoked;
    [Test] procedure MetricsEnabled_CorrectPath_GetMetricsBodyCalled;
    [Test] procedure MetricsEnabled_CorrectPath_Returns200;
    [Test] procedure MetricsEnabled_DifferentPath_HandlerInvoked;
    [Test] procedure MetricsEnabled_BlockedCIDR_Returns403;
  end;

  {$M-}

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  System.Math,
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.ProxyProtocol,
  Poseidon.Net.Dispatcher;

// =============================================================================
// Mock IDispatchCallbacks
// =============================================================================

type
  TMockCallbacks = class(TInterfacedObject, IDispatchCallbacks)
  public
    // Configurable
    RateLimitResult:    Boolean;
    MetricsBodyResult:  Boolean;
    MetricsBody:        TBytes;

    // Captured results
    SendResponseData:   TBytes;
    SendResponseStatus: Integer;   // parsed HTTP status from SendResponse
    HandlerInvoked:     Boolean;
    CloseConnCalled:    Boolean;
    PostRecvCalled:     Boolean;
    GetMetricsCalled:   Boolean;

    constructor Create;

    // IDispatchCallbacks
    procedure PostRecv(AConn: Pointer);
    procedure CloseConn(AConn: Pointer);
    procedure SendResponse(AConn: Pointer; const AData: TBytes; AActualLen: Integer);
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function  DispatchWSFrames(AConn: Pointer): Boolean;
    function  CheckRateLimit(const ARemoteAddr: string): Boolean;
    procedure InvokeRequest(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtra: TArray<TPair<string,string>>);
    function  GetMetricsBody(const APath, ARemoteAddr: string;
      out ABody: TBytes): Boolean;
    procedure LogRequest(const AEvent: TPoseidonRequestLogEvent);
    procedure AdjustInflight(ADelta: Integer);
    procedure RecordRequest(AStatus: Integer; ADurationMs, ARxBytes, ATxBytes: Int64);
  end;

constructor TMockCallbacks.Create;
begin
  inherited Create;
  RateLimitResult   := True;
  MetricsBodyResult := True;
  MetricsBody       := TEncoding.ASCII.GetBytes('# metrics');
  SendResponseStatus := 0;
  HandlerInvoked    := False;
  CloseConnCalled   := False;
  PostRecvCalled    := False;
  GetMetricsCalled  := False;
end;

procedure TMockCallbacks.PostRecv(AConn: Pointer);
begin
  PostRecvCalled := True;
end;

procedure TMockCallbacks.CloseConn(AConn: Pointer);
begin
  CloseConnCalled := True;
end;

procedure TMockCallbacks.SendResponse(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
var
  LStr: string;
  LPos: Integer;
begin
  SendResponseData := AData;
  // Parse "HTTP/1.1 NNN " from response bytes
  LStr := TEncoding.ASCII.GetString(AData, 0, Min(Length(AData), 50));
  LPos := Pos('HTTP/1.1 ', LStr);
  if LPos > 0 then
    SendResponseStatus := StrToIntDef(Copy(LStr, LPos + 9, 3), 0);
end;

procedure TMockCallbacks.UpgradeToWS(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
end;

procedure TMockCallbacks.UpgradeToH2C(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
end;

function TMockCallbacks.DispatchWSFrames(AConn: Pointer): Boolean;
begin
  Result := False;
end;

function TMockCallbacks.CheckRateLimit(const ARemoteAddr: string): Boolean;
begin
  Result := RateLimitResult;
end;

procedure TMockCallbacks.InvokeRequest(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtra: TArray<TPair<string,string>>);
begin
  HandlerInvoked := True;
  AStatus        := 200;
  AContentType   := 'application/json';
  ABody          := TEncoding.UTF8.GetBytes('{"ok":true}');
  AExtra         := [];
end;

function TMockCallbacks.GetMetricsBody(const APath, ARemoteAddr: string;
  out ABody: TBytes): Boolean;
begin
  GetMetricsCalled := True;
  ABody            := MetricsBody;
  Result           := MetricsBodyResult;
end;

procedure TMockCallbacks.LogRequest(const AEvent: TPoseidonRequestLogEvent);
begin
end;

procedure TMockCallbacks.AdjustInflight(ADelta: Integer);
begin
end;

procedure TMockCallbacks.RecordRequest(AStatus: Integer;
  ADurationMs, ARxBytes, ATxBytes: Int64);
begin
end;

// =============================================================================
// Helpers
// =============================================================================

// Build a minimal HTTP/1.1 request string and put it in a TNativeConn.
// Returns a new TNativeConn — caller owns it and must call Free.
function MakeConn(const AMethod, APath: string;
  const ARemoteAddr: string = '127.0.0.1:12345';
  AKeepAlive: Boolean = False): TNativeConn;
var
  LReq: string;
  LBytes: TBytes;
  LConn: TNativeConn;
  LConnVal: string;
begin
  if AKeepAlive then LConnVal := 'keep-alive' else LConnVal := 'close';
  LReq := AMethod + ' ' + APath + ' HTTP/1.1'#13#10 +
          'Host: 127.0.0.1'#13#10 +
          'Connection: ' + LConnVal + #13#10#13#10;
  LBytes := TEncoding.ASCII.GetBytes(LReq);

  LConn := TNativeConn.Create(0, ARemoteAddr);
  LConn.PPParsed := True;   // skip proxy protocol
  LConn.AccumLen := Length(LBytes);
  Move(LBytes[0], LConn.AccumBuf[0], LConn.AccumLen);
  Result := LConn;
end;

// Build a default TDispatchConfig that lets requests through.
function DefaultConfig(AInFlightCount: PInt64 = nil): TDispatchConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ProxyProtocol        := ppDisabled;
  Result.MaxRequestSize       := 8 * 1024 * 1024;
  Result.MaxHeaderSize        := 65536;
  Result.AllowedMethods       := [];   // empty = allow all
  Result.H2Enabled            := False;
  Result.SecureHeadersEnabled := False;
  Result.ServerBanner         := 'Poseidon/1.0';
  Result.MaxQueueDepth        := 0;    // disabled
  Result.RateLimitResponse    := 429;
  Result.CompressionEnabled   := False;
  Result.BrotliEnabled        := False;
  Result.MetricsEnabled       := False;
  Result.MetricsPath          := '/metrics';
  Result.MetricsAllowedCIDR   := '';
  if AInFlightCount <> nil then
    Result.InFlightCount := AInFlightCount;
end;

// Dispatch a single request and return the mock callbacks for inspection.
// AConn is owned by the caller (not freed here).
procedure DoDispatch(AConn: TNativeConn; var AConfig: TDispatchConfig;
  AMock: TMockCallbacks);
var
  LDispatcher: TProtocolDispatcher;
begin
  LDispatcher := TProtocolDispatcher.Create(AMock);
  try
    LDispatcher.Dispatch(AConn, AConfig);
  finally
    LDispatcher.Free;
  end;
end;

// =============================================================================
// Fixture 1 — Method allowlist (S-1)
// =============================================================================

procedure TDispatcherMethodTests.AllowedMethod_GET_InvokesHandler;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.AllowedMethods := ['GET', 'POST'];
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'GET in AllowedMethods must invoke the handler');
    Assert.AreNotEqual(405, LMock.SendResponseStatus,
      'GET must not receive 405 when it is in AllowedMethods');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherMethodTests.DisallowedMethod_DELETE_Returns405;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('DELETE', '/resource');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.AllowedMethods := ['GET', 'POST'];
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(405, LMock.SendResponseStatus,
      'DELETE not in AllowedMethods must return 405');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherMethodTests.DisallowedMethod_DoesNotInvokeHandler;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('TRACE', '/');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.AllowedMethods := ['GET'];
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.HandlerInvoked,
      'Disallowed method must NOT reach the application handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherMethodTests.EmptyAllowlist_AllowsAllMethods;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('DELETE', '/x');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.AllowedMethods := [];   // empty = unrestricted
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Empty AllowedMethods must allow any method through');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 2 — Path traversal (S-2)
// =============================================================================

procedure TDispatcherPathTests.SafePath_Root_Dispatched;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Safe path "/" must reach the handler');
    Assert.AreNotEqual(400, LMock.SendResponseStatus);
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherPathTests.DotDotSegment_Returns400;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/../etc/passwd');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(400, LMock.SendResponseStatus,
      'Path with .. segment must return 400');
    Assert.IsFalse(LMock.HandlerInvoked,
      'Path traversal must not reach the handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherPathTests.PercentEncodedDotDot_Returns400;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/%2e%2e/etc/passwd');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(400, LMock.SendResponseStatus,
      '%2e%2e (encoded ..) must return 400');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherPathTests.NullByte_Returns400;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  // %00 is a null byte in the URL — must be rejected
  LConn   := MakeConn('GET', '/file%00.txt');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(400, LMock.SendResponseStatus,
      'Path with %00 (null byte) must return 400');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 3 — Rate limit
// =============================================================================

procedure TDispatcherRateLimitTests.RateLimitAllowed_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LMock.RateLimitResult := True;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.RateLimitResponse := 429;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Allowed request must reach handler when rate limit is not exceeded');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherRateLimitTests.RateLimitDenied_ReturnsRateLimitStatus;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LMock.RateLimitResult := False;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.RateLimitResponse := 429;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(429, LMock.SendResponseStatus,
      'Rate-limited request must receive status 429 (RateLimitResponse)');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherRateLimitTests.RateLimitDenied_HandlerNotInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LMock.RateLimitResult := False;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.HandlerInvoked,
      'Rate-limited request must NOT invoke the application handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 4 — Backpressure / MaxQueueDepth (R-5)
// =============================================================================

procedure TDispatcherBackpressureTests.QueueNotFull_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;   // current in-flight = 0
  LConfig := DefaultConfig(@LIF);
  LConfig.MaxQueueDepth := 5;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Handler must be invoked when in-flight count < MaxQueueDepth');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherBackpressureTests.QueueFull_DispatcherPassesThrough;
// R-5 backpressure is now enforced in HttpServer._DispatchAccumBuf, not here.
// Dispatcher must pass requests through even when MaxQueueDepth/InFlightCount
// values suggest overload — it no longer checks them.
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LIF     := 5;   // at the limit — Dispatcher should NOT care
  LConfig := DefaultConfig(@LIF);
  LConfig.MaxQueueDepth := 5;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(200, LMock.SendResponseStatus,
      'Dispatcher must pass request through (backpressure is in HttpServer)');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherBackpressureTests.QueueFull_HandlerStillInvoked;
// Since backpressure moved to HttpServer, Dispatcher always invokes handler.
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LIF     := 10;
  LConfig := DefaultConfig(@LIF);
  LConfig.MaxQueueDepth := 5;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Dispatcher must invoke handler (backpressure is in HttpServer)');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherBackpressureTests.MaxQueueDepthZero_NoBackpressure;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LIF     := 999;  // very high in-flight — should not matter when depth=0
  LConfig := DefaultConfig(@LIF);
  LConfig.MaxQueueDepth := 0;  // disabled
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'MaxQueueDepth=0 disables backpressure; handler must always be invoked');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 5 — Metrics endpoint routing
// =============================================================================

procedure TDispatcherMetricsTests.MetricsDisabled_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/metrics');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.MetricsEnabled := False;
  LConfig.MetricsPath    := '/metrics';
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.GetMetricsCalled,
      'GetMetricsBody must NOT be called when MetricsEnabled=False');
    Assert.IsTrue(LMock.HandlerInvoked,
      'Request to /metrics must reach handler when MetricsEnabled=False');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherMetricsTests.MetricsEnabled_CorrectPath_GetMetricsBodyCalled;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/metrics');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.MetricsEnabled := True;
  LConfig.MetricsPath    := '/metrics';
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.GetMetricsCalled,
      'GetMetricsBody must be called for GET /metrics when MetricsEnabled=True');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherMetricsTests.MetricsEnabled_CorrectPath_Returns200;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/metrics');
  LMock   := TMockCallbacks.Create;
  LMock.MetricsBodyResult := True;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.MetricsEnabled := True;
  LConfig.MetricsPath    := '/metrics';
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(200, LMock.SendResponseStatus,
      'Metrics endpoint must respond 200 OK');
    Assert.IsFalse(LMock.HandlerInvoked,
      'Application handler must NOT be invoked for the metrics endpoint');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherMetricsTests.MetricsEnabled_DifferentPath_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  LConn   := MakeConn('GET', '/api/status');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.MetricsEnabled := True;
  LConfig.MetricsPath    := '/metrics';
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.GetMetricsCalled,
      'GetMetricsBody must NOT be called for paths other than MetricsPath');
    Assert.IsTrue(LMock.HandlerInvoked,
      'Non-metrics path must reach the application handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherMetricsTests.MetricsEnabled_BlockedCIDR_Returns403;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LIF:     Int64;
begin
  // RemoteAddr 10.0.0.5 is NOT in 192.168.0.0/16 → must be blocked
  LConn   := MakeConn('GET', '/metrics', '10.0.0.5:4321');
  LMock   := TMockCallbacks.Create;
  LIF     := 0;
  LConfig := DefaultConfig(@LIF);
  LConfig.MetricsEnabled     := True;
  LConfig.MetricsPath        := '/metrics';
  LConfig.MetricsAllowedCIDR := '192.168.0.0/16';
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(403, LMock.SendResponseStatus,
      'Request from outside MetricsAllowedCIDR must receive 403');
    Assert.IsFalse(LMock.GetMetricsCalled,
      'GetMetricsBody must NOT be called when CIDR check fails');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TDispatcherMethodTests);
  TDUnitX.RegisterTestFixture(TDispatcherPathTests);
  TDUnitX.RegisterTestFixture(TDispatcherRateLimitTests);
  TDUnitX.RegisterTestFixture(TDispatcherBackpressureTests);
  TDUnitX.RegisterTestFixture(TDispatcherMetricsTests);

end.
