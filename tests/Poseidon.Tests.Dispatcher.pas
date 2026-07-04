unit Poseidon.Tests.Dispatcher;

// Unit tests for TProtocolDispatcher (#83 — Pipeline pattern).
//
// Tests routing logic in isolation via a mock IDispatchCallbacks — no live
// server, no sockets.  Each test builds a TNativeConn with a pre-filled
// accumulation buffer, creates a TDispatchConfig, and calls Dispatch.
//
// Fixtures:
//   TDispatcherBasicTests       — valid requests, handler invocation, response
//   TDispatcherSizeCheckTests   — 413 on oversized payloads
//   TDispatcherProtocolTests    — H2/WS branching, proxy protocol
//   TDispatcherUpgradeTests     — WebSocket/H2C upgrade detection
//   TDispatcherLightweightTests — lightweight pipeline (no protocol checks)
//   TDispatcherBackpressureTests — MaxQueueDepth passthrough

interface

uses
  DUnitX.TestFramework;

type
  {$M+}

  [TestFixture]
  TDispatcherBasicTests = class
  public
    [Test] procedure ValidGET_HandlerInvoked;
    [Test] procedure ValidPOST_HandlerInvoked;
    [Test] procedure ValidGET_Returns200;
    [Test] procedure ValidGET_LogRequestCalled;
  end;

  [TestFixture]
  TDispatcherSizeCheckTests = class
  public
    [Test] procedure OversizedPayload_Returns413;
    [Test] procedure OversizedPayload_HandlerNotInvoked;
    [Test] procedure WithinLimit_HandlerInvoked;
  end;

  [TestFixture]
  TDispatcherProtocolTests = class
  public
    [Test] procedure H2Connection_BranchTaken;
    [Test] procedure H2Connection_HandlerNotInvoked;
    [Test] procedure WSConnection_BranchTaken;
    [Test] procedure WSConnection_HandlerNotInvoked;
  end;

  [TestFixture]
  TDispatcherUpgradeTests = class
  public
    [Test] procedure WSUpgrade_UpgradeToWSCalled;
    [Test] procedure H2CUpgrade_UpgradeToH2CCalled;
    [Test] procedure NonGET_NoUpgradeCheck;
  end;

  [TestFixture]
  TDispatcherLightweightTests = class
  public
    [Test] procedure LightweightGET_HandlerInvoked;
    [Test] procedure LightweightGET_LogNotCalled;
    [Test] procedure LightweightOversized_Returns413;
  end;

  // R-5 backpressure was moved from Dispatcher to HttpServer._DispatchAccumBuf.
  // Dispatcher now always receives MaxQueueDepth=0 (no check).  These tests
  // verify the Dispatcher passes requests through regardless of config values.
  [TestFixture]
  TDispatcherBackpressureTests = class
  public
    [Test] procedure QueueNotFull_HandlerInvoked;
    [Test] procedure QueueFull_DispatcherPassesThrough;
    [Test] procedure MaxQueueDepthZero_NoBackpressure;
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
  Poseidon.Net.HTTP2,
  Poseidon.Net.ProxyProtocol,
  Poseidon.Net.Dispatcher;

// =============================================================================
// Mock IDispatchCallbacks
// =============================================================================

type
  TMockCallbacks = class(TInterfacedObject, IDispatchCallbacks)
  public
    // Captured results
    SendResponseData:   TBytes;
    SendResponseStatus: Integer;
    HandlerInvoked:     Boolean;
    CloseConnCalled:    Boolean;
    PostRecvCalled:     Boolean;
    LogRequestCalled:   Boolean;
    UpgradeToWSCalled:  Boolean;
    UpgradeToH2CCalled: Boolean;
    DispatchWSCalled:   Boolean;

    constructor Create;

    // IDispatchCallbacks
    procedure PostRecv(AConn: Pointer);
    procedure CloseConn(AConn: Pointer);
    procedure SendResponse(AConn: Pointer; const AData: TBytes; AActualLen: Integer);
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function  DispatchWSFrames(AConn: Pointer): Boolean;
    procedure InvokeRequest(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtra: TArray<TPair<string,string>>);
    procedure LogRequest(const AEvent: TPoseidonRequestLogEvent);
  end;

constructor TMockCallbacks.Create;
begin
  inherited Create;
  SendResponseStatus  := 0;
  HandlerInvoked      := False;
  CloseConnCalled     := False;
  PostRecvCalled      := False;
  LogRequestCalled    := False;
  UpgradeToWSCalled   := False;
  UpgradeToH2CCalled  := False;
  DispatchWSCalled    := False;
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
  LStr := TEncoding.ASCII.GetString(AData, 0, Min(Length(AData), 50));
  LPos := Pos('HTTP/1.1 ', LStr);
  if LPos > 0 then
    SendResponseStatus := StrToIntDef(Copy(LStr, LPos + 9, 3), 0);
end;

procedure TMockCallbacks.UpgradeToWS(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
  UpgradeToWSCalled := True;
end;

procedure TMockCallbacks.UpgradeToH2C(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
begin
  UpgradeToH2CCalled := True;
end;

function TMockCallbacks.DispatchWSFrames(AConn: Pointer): Boolean;
begin
  DispatchWSCalled := True;
  Result := False;
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

procedure TMockCallbacks.LogRequest(const AEvent: TPoseidonRequestLogEvent);
begin
  LogRequestCalled := True;
end;

// =============================================================================
// Helpers
// =============================================================================

function MakeConn(const AMethod, APath: string;
  const ARemoteAddr: string = '127.0.0.1:12345';
  AKeepAlive: Boolean = False): TNativeConn;
var
  LReq:     string;
  LBytes:   TBytes;
  LConn:    TNativeConn;
  LConnVal: string;
begin
  if AKeepAlive then LConnVal := 'keep-alive' else LConnVal := 'close';
  LReq := AMethod + ' ' + APath + ' HTTP/1.1'#13#10 +
          'Host: 127.0.0.1'#13#10 +
          'Connection: ' + LConnVal + #13#10#13#10;
  LBytes := TEncoding.ASCII.GetBytes(LReq);

  LConn := TNativeConn.Create(0, ARemoteAddr);
  LConn.PPParsed := True;
  LConn.AccumLen := Length(LBytes);
  Move(LBytes[0], LConn.AccumBuf[0], LConn.AccumLen);
  Result := LConn;
end;

function MakeConnWithUpgrade(const APath, AUpgrade, AWsKey: string): TNativeConn;
var
  LReq:   string;
  LBytes: TBytes;
  LConn:  TNativeConn;
begin
  LReq := 'GET ' + APath + ' HTTP/1.1'#13#10 +
          'Host: 127.0.0.1'#13#10 +
          'Connection: Upgrade'#13#10 +
          'Upgrade: ' + AUpgrade + #13#10;
  if AWsKey <> '' then
    LReq := LReq + 'Sec-WebSocket-Key: ' + AWsKey + #13#10;
  LReq := LReq + #13#10;
  LBytes := TEncoding.ASCII.GetBytes(LReq);

  LConn := TNativeConn.Create(0, '127.0.0.1:12345');
  LConn.PPParsed := True;
  LConn.AccumLen := Length(LBytes);
  Move(LBytes[0], LConn.AccumBuf[0], LConn.AccumLen);
  Result := LConn;
end;

function DefaultConfig: TDispatchConfig;
begin
  FillChar(Result, SizeOf(Result), 0);
  Result.ProxyProtocol        := ppDisabled;
  Result.MaxRequestSize       := 8 * 1024 * 1024;
  Result.MaxHeaderSize        := 65536;
  Result.H2Enabled            := False;
  Result.SecureHeadersEnabled := False;
  Result.ServerBanner         := 'Poseidon/1.0';
  Result.MaxQueueDepth        := 0;
  Result.InFlightCount        := nil;
end;

procedure DoDispatch(AConn: TNativeConn; var AConfig: TDispatchConfig;
  AMock: TMockCallbacks; ALightweight: Boolean = False);
var
  LDispatcher: TProtocolDispatcher;
begin
  LDispatcher := TProtocolDispatcher.Create(AMock, ALightweight);
  try
    LDispatcher.Dispatch(AConn, AConfig);
  finally
    LDispatcher.Free;
  end;
end;

// =============================================================================
// Fixture 1 — Basic dispatch
// =============================================================================

procedure TDispatcherBasicTests.ValidGET_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Valid GET must invoke the handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherBasicTests.ValidPOST_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('POST', '/data');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Valid POST must invoke the handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherBasicTests.ValidGET_Returns200;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(200, LMock.SendResponseStatus,
      'Valid GET must return 200');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherBasicTests.ValidGET_LogRequestCalled;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.LogRequestCalled,
      'Full pipeline must call LogRequest');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 2 — Size check (413)
// =============================================================================

procedure TDispatcherSizeCheckTests.OversizedPayload_Returns413;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  LConfig.MaxRequestSize := 10;  // artificially small
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.AreEqual(413, LMock.SendResponseStatus,
      'Oversized request must return 413');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherSizeCheckTests.OversizedPayload_HandlerNotInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  LConfig.MaxRequestSize := 10;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.HandlerInvoked,
      'Oversized request must NOT reach the handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherSizeCheckTests.WithinLimit_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Request within size limit must reach the handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 3 — Protocol branching (H2 / WS)
// =============================================================================

procedure TDispatcherProtocolTests.H2Connection_BranchTaken;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LConn.AccumLen := 0;  // H2 branch — no HTTP/1.1 data to parse
  LConn.H2Conn := TH2Conn.Create(LConn, nil, nil, nil);
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.PostRecvCalled,
      'H2 branch must call PostRecv to continue reading');
  finally
    LConn.H2Conn.Free;
    LConn.H2Conn := nil;
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherProtocolTests.H2Connection_HandlerNotInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LConn.AccumLen := 0;  // H2 branch — no HTTP/1.1 data to parse
  LConn.H2Conn := TH2Conn.Create(LConn, nil, nil, nil);
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.HandlerInvoked,
      'H2 branch must not invoke the HTTP/1.1 handler');
  finally
    LConn.H2Conn.Free;
    LConn.H2Conn := nil;
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherProtocolTests.WSConnection_BranchTaken;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/ws');
  LConn.WSMode := CM_WEBSOCKET;
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.DispatchWSCalled,
      'WS branch must call DispatchWSFrames');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherProtocolTests.WSConnection_HandlerNotInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/ws');
  LConn.WSMode := CM_WEBSOCKET;
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.HandlerInvoked,
      'WS branch must not invoke the HTTP/1.1 handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 4 — Upgrade detection
// =============================================================================

procedure TDispatcherUpgradeTests.WSUpgrade_UpgradeToWSCalled;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConnWithUpgrade('/chat', 'websocket', 'dGhlIHNhbXBsZSBub25jZQ==');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.UpgradeToWSCalled,
      'GET with Upgrade: websocket + Sec-WebSocket-Key must trigger WS upgrade');
    Assert.IsFalse(LMock.HandlerInvoked,
      'WS upgrade must not invoke the application handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherUpgradeTests.H2CUpgrade_UpgradeToH2CCalled;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConnWithUpgrade('/', 'h2c', '');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  LConfig.H2Enabled := True;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.UpgradeToH2CCalled,
      'GET with Upgrade: h2c + H2Enabled must trigger H2C upgrade');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherUpgradeTests.NonGET_NoUpgradeCheck;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
  LReq:    string;
  LBytes:  TBytes;
begin
  // POST with Upgrade header — should NOT trigger upgrade
  LReq := 'POST / HTTP/1.1'#13#10 +
          'Host: 127.0.0.1'#13#10 +
          'Connection: Upgrade'#13#10 +
          'Upgrade: websocket'#13#10 +
          'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ=='#13#10 +
          'Content-Length: 0'#13#10#13#10;
  LBytes := TEncoding.ASCII.GetBytes(LReq);
  LConn := TNativeConn.Create(0, '127.0.0.1:12345');
  LConn.PPParsed := True;
  LConn.AccumLen := Length(LBytes);
  Move(LBytes[0], LConn.AccumBuf[0], LConn.AccumLen);

  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsFalse(LMock.UpgradeToWSCalled,
      'POST must not trigger WebSocket upgrade');
    Assert.IsTrue(LMock.HandlerInvoked,
      'POST with Upgrade header must reach handler (upgrade only on GET)');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 5 — Lightweight pipeline
// =============================================================================

procedure TDispatcherLightweightTests.LightweightGET_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/ping');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock, True);
    Assert.IsTrue(LMock.HandlerInvoked,
      'Lightweight pipeline must invoke the handler');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherLightweightTests.LightweightGET_LogNotCalled;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/ping');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  try
    DoDispatch(LConn, LConfig, LMock, True);
    Assert.IsFalse(LMock.LogRequestCalled,
      'Lightweight pipeline must NOT call LogRequest');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

procedure TDispatcherLightweightTests.LightweightOversized_Returns413;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  LConfig.MaxRequestSize := 10;
  try
    DoDispatch(LConn, LConfig, LMock, True);
    Assert.AreEqual(413, LMock.SendResponseStatus,
      'Lightweight pipeline must still enforce size limit');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

// =============================================================================
// Fixture 6 — Backpressure passthrough
// =============================================================================

procedure TDispatcherBackpressureTests.QueueNotFull_HandlerInvoked;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
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
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
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

procedure TDispatcherBackpressureTests.MaxQueueDepthZero_NoBackpressure;
var
  LConn:   TNativeConn;
  LMock:   TMockCallbacks;
  LConfig: TDispatchConfig;
begin
  LConn   := MakeConn('GET', '/');
  LMock   := TMockCallbacks.Create;
  LConfig := DefaultConfig;
  LConfig.MaxQueueDepth := 0;
  try
    DoDispatch(LConn, LConfig, LMock);
    Assert.IsTrue(LMock.HandlerInvoked,
      'MaxQueueDepth=0 disables backpressure; handler must always be invoked');
  finally
    LConn.Free;
    LMock := nil;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TDispatcherBasicTests);
  TDUnitX.RegisterTestFixture(TDispatcherSizeCheckTests);
  TDUnitX.RegisterTestFixture(TDispatcherProtocolTests);
  TDUnitX.RegisterTestFixture(TDispatcherUpgradeTests);
  TDUnitX.RegisterTestFixture(TDispatcherLightweightTests);
  TDUnitX.RegisterTestFixture(TDispatcherBackpressureTests);

end.
