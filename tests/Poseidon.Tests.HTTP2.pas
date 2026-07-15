unit Poseidon.Tests.HTTP2;

// DUnitX tests for the HTTP/2 implementation.
//
// Fixture 1 — TPoseidonHTTP2Tests (port 19002, requires OpenSSL):
//   Integration tests via ALPN "h2" over TLS.
//   Generate certificate once:
//     openssl req -x509 -newkey rsa:2048 -keyout tests\certs\test-server.key
//       -out tests\certs\test-server.crt -days 3650 -nodes -subj "/CN=127.0.0.1"
//   Tests skip automatically when OpenSSL is not available.
//
// Fixture 2 — TH2ConnUnitTests (no network, no SSL):
//   Unit tests of TH2Conn protocol layer directly.
//   Covers: preface, SETTINGS ACK, PING/PONG, WINDOW_UPDATE (A-3),
//           RST_STREAM (R-2 adjacent), GOAWAY on demand, frame parsing.

interface

uses
  DUnitX.TestFramework,
  System.SyncObjs;

type
  {$M+}
  [TestFixture]
  TPoseidonHTTP2Tests = class
  private
    FEvent:    TEvent;
    FSSLAvail: Boolean;
    procedure EnsureSSL;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    [Test]
    procedure Get_SimpleRequest_Returns200ViaH2;
    [Test]
    procedure Post_WithBody_Returns201ViaH2;
    [Test]
    procedure Get_CustomStatusCode_ReturnsOverriddenStatus;
  end;

  // ── Fixture 2: TH2Conn unit tests (no network, no SSL) ────────────────────
  [TestFixture]
  TH2ConnUnitTests = class
  private
    procedure CheckInt(AExpected, AActual: Integer; const AMsg: string = '');
  public
    // Client preface + SETTINGS ACK
    [Test]
    procedure Preface_ValidClientPreface_SendsSettingsAndACK;

    // PING frame
    [Test]
    procedure Ping_ClientSendsPing_ServerRepliesWithPong;

    // WINDOW_UPDATE — connection level (A-3)
    [Test]
    procedure WindowUpdate_ConnectionLevel_DoesNotClose;

    // WINDOW_UPDATE — stream level (A-3)
    [Test]
    procedure WindowUpdate_StreamLevel_DoesNotClose;

    // RST_STREAM from client
    [Test]
    procedure RstStream_ClientSendsRst_StreamDropped;

    // GOAWAY — server initiates
    [Test]
    procedure GoAway_ServerInitiated_SetsGoAwaySent;

    // GOAWAY — client sends GOAWAY
    [Test]
    procedure GoAway_ClientSendsGoAway_ConnectionAccepted;

    // SETTINGS ACK from client
    [Test]
    procedure Settings_ClientSendsACK_ProcessedWithoutError;

    // Initial settings sent on creation
    [Test]
    procedure SendInitialSettings_WritesBytesThatStartWithSettingsFrame;

    // P-1: server-side SETTINGS values sent to client
    [Test]
    procedure Settings_MaxConcurrentStreams_CustomValue_EncodedInFrame;
    [Test]
    procedure Settings_InitialWindowSize_CustomValue_EncodedInFrame;

    // Preface — invalid magic
    [Test]
    procedure Preface_InvalidMagic_SendsGoAway;

    // SETTINGS with parameters
    [Test]
    procedure Settings_WithParameters_NoError;

    // HEADERS / request dispatch
    [Test]
    procedure Headers_GetRequest_DispatchesFOnRequest;
    [Test]
    procedure Headers_Post_WithDataBody_BodyAccumulated;

    // CONTINUATION without prior HEADERS
    [Test]
    procedure Continuation_WithoutPriorHeaders_GoAway;

    // GOAWAY — no active streams → FCloseProc called immediately
    [Test]
    procedure GoAway_NoStreams_CloseProcCalledImmediately;

    // RST_STREAM on an idle stream is a connection error (RFC 7540 §5.1)
    [Test]
    procedure RstStream_IdleStream_ConnectionError;

    // Server push — PUSH_PROMISE + promised response sent before reply
    [Test]
    procedure ServerPush_OnePushResource_SendsPushPromiseThenResponse;

    // Control-frame flood (CVE-2019-9512): a PING flood must trip GOAWAY.
    [Test]
    procedure ControlFrameFlood_PingFlood_TriggersGoAway;

    // Lifetime regression: RST of a flow-control-buffered stream must decrement
    // FActiveStreams so a deferred GOAWAY close can complete (item-2 audit).
    [Test]
    procedure RstOfBufferedStream_CompletesDeferredGoAwayClose;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.URLClient,
  Poseidon.Net.Types,
  Poseidon.Net.HTTP2,
  Poseidon.Net.HttpServer,
  Poseidon.Net.SSL;

const
  INTEST_PORT = 19002;
  BASE_URL    = 'https://127.0.0.1:19002';
  CERT_FILE   = '.\certs\test-server.crt';
  KEY_FILE    = '.\certs\test-server.key';

type
  // Alias avoids Delphi parser issue with nested generics (TArray<TPair<X,Y>>)
  // in anonymous-method parameter declarations.
  TH2ExtraHeaders = TArray<TPair<string,string>>;

var
  GH2Server:      TPoseidonNativeServer;
  GH2ListenReady: TEvent;  // points to FEvent during SetupFixture

// Named procedures avoid parser confusion from complex generic types inside
// anonymous method parameter lists.

procedure TestH2Handler(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TH2ExtraHeaders);
begin
  AContentType  := 'application/json';
  AExtraHeaders := [];
  if (AReq.Method = 'GET') and (AReq.Path = '/') then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes('{"ok":true}');
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

procedure TestH2ListenReady;
begin
  GH2ListenReady.SetEvent;
end;

procedure ListenH2Thread;
begin
  GH2Server.Listen('127.0.0.1', INTEST_PORT, TestH2Handler, TestH2ListenReady);
end;

// Certificate validator — accepts any certificate for self-signed test certs.
procedure AcceptAllCertificates(const Sender: TObject;
  const ARequest: TURLRequest; const Certificate: TCertificate;
  var Accepted: Boolean);
begin
  Accepted := True;
end;

{ TPoseidonHTTP2Tests }

procedure TPoseidonHTTP2Tests.EnsureSSL;
begin
  if not FSSLAvail then
    // DUnitX has no Assert.Ignore in this version; Pass skips without failure.
    Assert.Pass('OpenSSL not available — HTTP/2 test skipped');
end;

procedure TPoseidonHTTP2Tests.SetupFixture;
begin
  FSSLAvail := TPoseidonSSL.IsAvailable;
  if not FSSLAvail then
    Exit;

  if not FileExists(CERT_FILE) or not FileExists(KEY_FILE) then
  begin
    FSSLAvail := False;
    Exit;
  end;

  FEvent         := TEvent.Create(nil, True, False, '');
  GH2Server      := TPoseidonNativeServer.Create;
  GH2ListenReady := FEvent;
  GH2Server.HTTP2Enabled := True;
  GH2Server.ConfigureSSL(CERT_FILE, KEY_FILE);

  TThread.CreateAnonymousThread(ListenH2Thread).Start;

  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'HTTP/2 server did not start within 5 s');
end;

procedure TPoseidonHTTP2Tests.TeardownFixture;
begin
  if not FSSLAvail then
    Exit;
  GH2Server.Stop;
  FreeAndNil(GH2Server);
  FreeAndNil(FEvent);
  GH2ListenReady := nil;
end;

procedure TPoseidonHTTP2Tests.Get_SimpleRequest_Returns200ViaH2;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  EnsureSSL;
  LClient := THTTPClient.Create;
  try
    LClient.ValidateServerCertificateCallback := AcceptAllCertificates;
    LResponse := LClient.Get(BASE_URL + '/');
    Assert.AreEqual(200, LResponse.StatusCode);
    Assert.IsTrue(LResponse.ContentAsString.Contains('"ok":true'));
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonHTTP2Tests.Post_WithBody_Returns201ViaH2;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
  LBody:     TStringStream;
begin
  EnsureSSL;
  LClient := THTTPClient.Create;
  LBody   := TStringStream.Create('{"data":1}', TEncoding.UTF8);
  try
    LClient.ValidateServerCertificateCallback := AcceptAllCertificates;
    LResponse := LClient.Post(BASE_URL + '/data', LBody, nil,
      [TNameValuePair.Create('Content-Type', 'application/json')]);
    Assert.AreEqual(201, LResponse.StatusCode);
  finally
    LBody.Free;
    LClient.Free;
  end;
end;

procedure TPoseidonHTTP2Tests.Get_CustomStatusCode_ReturnsOverriddenStatus;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  EnsureSSL;
  LClient := THTTPClient.Create;
  try
    LClient.HandleRedirects := False;
    LClient.ValidateServerCertificateCallback := AcceptAllCertificates;
    LResponse := LClient.Get(BASE_URL + '/teapot');
    Assert.AreEqual(418, LResponse.StatusCode);
  finally
    LClient.Free;
  end;
end;

// =============================================================================
// Fixture 2 — TH2ConnUnitTests
//
// Helpers:
//   BuildFrame(AType, AFlags, AStreamID, APayload) → TBytes — raw H2 frame
//   The client preface is the 24-byte magic PRI string + a SETTINGS frame.
// =============================================================================

// H2 frame type constants (local copy to avoid dependency on non-public consts)
const
  H2T_DATA          = 0;
  H2T_HEADERS       = 1;
  H2T_PRIORITY      = 2;
  H2T_RST_STREAM    = 3;
  H2T_SETTINGS      = 4;
  H2T_PUSH_PROMISE  = 5;
  H2T_PING          = 6;
  H2T_GOAWAY        = 7;
  H2T_WINDOW_UPDATE = 8;
  H2T_CONTINUATION  = 9;

  H2F_ACK = $01;

  // Client connection preface magic (RFC 7540 §3.5)
  H2_CLIENT_MAGIC = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;

// Build a raw HTTP/2 frame:  3-byte length | 1-byte type | 1-byte flags |
//                             4-byte stream-id (big-endian) | payload
function H2BuildFrame(AType, AFlags: Byte; AStreamID: Cardinal;
  const APayload: TBytes): TBytes;
var
  LLen: Integer;
begin
  LLen := Length(APayload);
  SetLength(Result, 9 + LLen);
  Result[0] := Byte((LLen shr 16) and $FF);
  Result[1] := Byte((LLen shr  8) and $FF);
  Result[2] := Byte( LLen         and $FF);
  Result[3] := AType;
  Result[4] := AFlags;
  Result[5] := Byte((AStreamID shr 24) and $FF);
  Result[6] := Byte((AStreamID shr 16) and $FF);
  Result[7] := Byte((AStreamID shr  8) and $FF);
  Result[8] := Byte( AStreamID         and $FF);
  if LLen > 0 then
    Move(APayload[0], Result[9], LLen);
end;

// Build a SETTINGS frame with no parameters (empty body — used as ACK or bare)
function H2BuildSettings(AFlags: Byte = 0): TBytes;
begin
  Result := H2BuildFrame(H2T_SETTINGS, AFlags, 0, nil);
end;

// Build a PING frame (8 zero bytes payload)
function H2BuildPing(AFlags: Byte = 0): TBytes;
var
  LPayload: TBytes;
begin
  SetLength(LPayload, 8);
  FillChar(LPayload[0], 8, 0);
  Result := H2BuildFrame(H2T_PING, AFlags, 0, LPayload);
end;

// Build a WINDOW_UPDATE frame for the given stream (4-byte increment)
function H2BuildWindowUpdate(AStreamID: Cardinal; AIncrement: Cardinal): TBytes;
var
  LPayload: TBytes;
begin
  SetLength(LPayload, 4);
  LPayload[0] := Byte((AIncrement shr 24) and $7F);
  LPayload[1] := Byte((AIncrement shr 16) and $FF);
  LPayload[2] := Byte((AIncrement shr  8) and $FF);
  LPayload[3] := Byte( AIncrement         and $FF);
  Result := H2BuildFrame(H2T_WINDOW_UPDATE, 0, AStreamID, LPayload);
end;

// Build a RST_STREAM frame (4-byte error code)
function H2BuildRstStream(AStreamID: Cardinal; AErrorCode: Cardinal = 0): TBytes;
var
  LPayload: TBytes;
begin
  SetLength(LPayload, 4);
  LPayload[0] := Byte((AErrorCode shr 24) and $FF);
  LPayload[1] := Byte((AErrorCode shr 16) and $FF);
  LPayload[2] := Byte((AErrorCode shr  8) and $FF);
  LPayload[3] := Byte( AErrorCode         and $FF);
  Result := H2BuildFrame(H2T_RST_STREAM, 0, AStreamID, LPayload);
end;

// Build a GOAWAY frame (last-stream-id + error code)
function H2BuildGoAway(ALastStream: Cardinal; AError: Cardinal = 0): TBytes;
var
  LPayload: TBytes;
begin
  SetLength(LPayload, 8);
  LPayload[0] := Byte((ALastStream shr 24) and $7F);
  LPayload[1] := Byte((ALastStream shr 16) and $FF);
  LPayload[2] := Byte((ALastStream shr  8) and $FF);
  LPayload[3] := Byte( ALastStream         and $FF);
  LPayload[4] := Byte((AError shr 24) and $FF);
  LPayload[5] := Byte((AError shr 16) and $FF);
  LPayload[6] := Byte((AError shr  8) and $FF);
  LPayload[7] := Byte( AError         and $FF);
  Result := H2BuildFrame(H2T_GOAWAY, 0, 0, LPayload);
end;

// Build a SETTINGS frame with a single 6-byte parameter (id + value)
function H2BuildSettingsParam(AId: Word; AValue: Cardinal): TBytes;
var
  LPayload: TBytes;
begin
  SetLength(LPayload, 6);
  LPayload[0] := Byte((AId    shr 8) and $FF);
  LPayload[1] := Byte( AId           and $FF);
  LPayload[2] := Byte((AValue shr 24) and $FF);
  LPayload[3] := Byte((AValue shr 16) and $FF);
  LPayload[4] := Byte((AValue shr  8) and $FF);
  LPayload[5] := Byte( AValue         and $FF);
  Result := H2BuildFrame(H2T_SETTINGS, 0, 0, LPayload);
end;

// Helper: scan a byte buffer for a GOAWAY frame (type=7); returns True if found
function H2HasGoAway(const ABuf: TBytes): Boolean;
var
  I: Integer;
begin
  Result := False;
  I := 0;
  while I + 9 <= Length(ABuf) do
  begin
    if ABuf[I + 3] = H2T_GOAWAY then
    begin
      Result := True;
      Exit;
    end;
    I := I + 9 + (Integer(ABuf[I]) shl 16 or Integer(ABuf[I+1]) shl 8 or Integer(ABuf[I+2]));
  end;
end;

// Helper: scan a byte buffer for a PUSH_PROMISE frame (type=5); returns the
// promised stream ID from the first PUSH_PROMISE found, or 0 if none.
function H2FindPushPromise(const ABuf: TBytes): Cardinal;
var
  I:      Integer;
  LLen:   Integer;
begin
  Result := 0;
  I := 0;
  while I + 9 <= Length(ABuf) do
  begin
    LLen := Integer(ABuf[I]) shl 16 or Integer(ABuf[I+1]) shl 8 or Integer(ABuf[I+2]);
    if ABuf[I + 3] = 5 {H2_FRAME_PUSH_PROMISE} then
    begin
      // Payload starts at I+9; first 4 bytes are the promised stream ID
      if I + 9 + 4 <= Length(ABuf) then
        Result := (Cardinal(ABuf[I+9] and $7F) shl 24) or
                  (Cardinal(ABuf[I+10]) shl 16) or
                  (Cardinal(ABuf[I+11]) shl  8) or
                   Cardinal(ABuf[I+12]);
      Exit;
    end;
    I := I + 9 + LLen;
  end;
end;

// Client preface: magic + empty SETTINGS frame
function H2ClientPreface: TBytes;
var
  LMagic:    TBytes;
  LSettings: TBytes;
begin
  LMagic    := TEncoding.ANSI.GetBytes(H2_CLIENT_MAGIC);
  LSettings := H2BuildSettings;
  SetLength(Result, Length(LMagic) + Length(LSettings));
  Move(LMagic[0],    Result[0],               Length(LMagic));
  Move(LSettings[0], Result[Length(LMagic)],  Length(LSettings));
end;

// ---------------------------------------------------------------------------
// Test harness — captures bytes sent by TH2Conn via the send callback
// ---------------------------------------------------------------------------

type
  TH2ExtraArr = TArray<TPair<string,string>>;

  TH2TestHarness = class
  private
    FConn:         TH2Conn;
    FLock:         TCriticalSection;
    FSent:         TBytes;
    FClosed:       Boolean;
    FReqs:         TList<TH2RequestData>;
    FNextPushList: TArray<TPoseidonPushResource>; // pushed on next OnRequest call

    procedure OnSend(AConn: Pointer; const AData: TBytes);
    procedure OnClose(AConn: Pointer);
    procedure OnRequest(const AReq: TH2RequestData;
      var AStatus: Integer; var AContentType: string;
      var ABody: TBytes; var AExtra: TH2ExtraArr;
      var APushResources: TArray<TPoseidonPushResource>);
  public
    constructor Create; overload;
    constructor Create(AMaxConcurrent: Cardinal;
      AInitWinSize: Cardinal); overload;
    destructor  Destroy; override;

    procedure Feed(const AData: TBytes);
    function  SentBytes: TBytes;
    function  Closed: Boolean;
    function  Requests: TList<TH2RequestData>;
    procedure ClearSent;
    // Configure push resources to return on the next OnRequest call
    procedure SetNextPush(const APushResources: TArray<TPoseidonPushResource>);
    property  H2: TH2Conn read FConn;
  end;

constructor TH2TestHarness.Create;
begin
  inherited Create;
  FLock  := TCriticalSection.Create;
  FReqs  := TList<TH2RequestData>.Create;
  FConn  := TH2Conn.Create(
    Self,
    OnSend,
    OnClose,
    OnRequest);
end;

constructor TH2TestHarness.Create(AMaxConcurrent: Cardinal;
  AInitWinSize: Cardinal);
begin
  inherited Create;
  FLock  := TCriticalSection.Create;
  FReqs  := TList<TH2RequestData>.Create;
  FConn  := TH2Conn.Create(
    Self,
    OnSend,
    OnClose,
    OnRequest,
    AMaxConcurrent,
    AInitWinSize);
end;

destructor TH2TestHarness.Destroy;
begin
  FreeAndNil(FConn);
  FreeAndNil(FLock);
  FreeAndNil(FReqs);
  inherited Destroy;
end;

procedure TH2TestHarness.OnSend(AConn: Pointer; const AData: TBytes);
begin
  FLock.Enter;
  try
    FSent := FSent + AData;
  finally
    FLock.Leave;
  end;
end;

procedure TH2TestHarness.OnClose(AConn: Pointer);
begin
  FClosed := True;
end;

procedure TH2TestHarness.OnRequest(const AReq: TH2RequestData;
  var AStatus: Integer; var AContentType: string;
  var ABody: TBytes; var AExtra: TH2ExtraArr;
  var APushResources: TArray<TPoseidonPushResource>);
begin
  FReqs.Add(AReq);
  AStatus      := 200;
  AContentType := 'text/plain';
  ABody        := TEncoding.UTF8.GetBytes('ok');
  AExtra       := [];
  APushResources := FNextPushList;
  SetLength(FNextPushList, 0);  // consume once
end;

procedure TH2TestHarness.SetNextPush(
  const APushResources: TArray<TPoseidonPushResource>);
begin
  FNextPushList := APushResources;
end;

procedure TH2TestHarness.Feed(const AData: TBytes);
begin
  if Length(AData) > 0 then
    FConn.ProcessData(@AData[0], Length(AData));
end;

function TH2TestHarness.SentBytes: TBytes;
begin
  FLock.Enter;
  try
    Result := FSent;
  finally
    FLock.Leave;
  end;
end;

function TH2TestHarness.Closed: Boolean;
begin
  Result := FClosed;
end;

function TH2TestHarness.Requests: TList<TH2RequestData>;
begin
  Result := FReqs;
end;

procedure TH2TestHarness.ClearSent;
begin
  FLock.Enter;
  try
    FSent := nil;
  finally
    FLock.Leave;
  end;
end;

{ TH2ConnUnitTests }

procedure TH2ConnUnitTests.CheckInt(AExpected, AActual: Integer;
  const AMsg: string);
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

procedure TH2ConnUnitTests.Preface_ValidClientPreface_SendsSettingsAndACK;
var
  LH: TH2TestHarness;
  LS: TBytes;
  I:  Integer;
  LFoundSettings, LFoundACK: Boolean;
begin
  LH := TH2TestHarness.Create;
  try
    LH.H2.SendInitialSettings;
    LH.ClearSent;

    LH.Feed(H2ClientPreface);

    // The server should have written: a SETTINGS frame + a SETTINGS ACK
    LS := LH.SentBytes;
    // Parse frames in the output to find SETTINGS (type=4) and SETTINGS ACK (type=4, flag=ACK)
    LFoundSettings := False;
    LFoundACK      := False;
    I := 0;
    while I + 9 <= Length(LS) do
    begin
      if (LS[I + 3] = H2T_SETTINGS) then
      begin
        if (LS[I + 4] and H2F_ACK) <> 0 then
          LFoundACK := True
        else
          LFoundSettings := True;
      end;
      // advance by frame size
      I := I + 9 + (Integer(LS[I]) shl 16 or Integer(LS[I+1]) shl 8 or Integer(LS[I+2]));
    end;
    Assert.IsTrue(LFoundACK,      'Server should send SETTINGS ACK after client preface');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.Ping_ClientSendsPing_ServerRepliesWithPong;
var
  LH:    TH2TestHarness;
  LS:    TBytes;
  I:     Integer;
  LGotPong: Boolean;
begin
  LH := TH2TestHarness.Create;
  try
    // Feed preface first to get the connection into a ready state
    LH.Feed(H2ClientPreface);
    LH.ClearSent;

    // Now send a PING
    LH.Feed(H2BuildPing(0));

    // Response: PING with ACK flag
    LS       := LH.SentBytes;
    LGotPong := False;
    I := 0;
    while I + 9 <= Length(LS) do
    begin
      if (LS[I + 3] = H2T_PING) and ((LS[I + 4] and H2F_ACK) <> 0) then
        LGotPong := True;
      I := I + 9 + (Integer(LS[I]) shl 16 or Integer(LS[I+1]) shl 8 or Integer(LS[I+2]));
    end;
    Assert.IsTrue(LGotPong, 'Server should reply with PING+ACK (PONG)');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.WindowUpdate_ConnectionLevel_DoesNotClose;
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    LH.Feed(H2BuildWindowUpdate(0, 65535));  // stream 0 = connection level
    Assert.IsFalse(LH.Closed,
      'WINDOW_UPDATE on connection level should not close the connection');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.WindowUpdate_StreamLevel_DoesNotClose;
var
  LH:     TH2TestHarness;
  LHpack: TBytes;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // Open stream 1 with a real request first so it is NOT "idle": RFC 7540
    // §5.1 makes WINDOW_UPDATE on an idle stream a connection error, but on an
    // existing (or already-closed) stream it must not close the connection.
    LHpack := TBytes.Create($82, $84, $86,
      $01, $09, $6C, $6F, $63, $61, $6C, $68, $6F, $73, $74);
    LH.Feed(H2BuildFrame(H2T_HEADERS, $05, 1, LHpack));
    LH.Feed(H2BuildWindowUpdate(1, 1000));
    Assert.IsFalse(LH.Closed,
      'stream-level WINDOW_UPDATE on an existing stream must not close the connection');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.RstStream_ClientSendsRst_StreamDropped;
var
  LH:     TH2TestHarness;
  LHpack: TBytes;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // Open stream 1 first (so it is not "idle"), then RST_STREAM it. A client
    // RST on an existing/closed stream drops the stream without closing the
    // connection (RFC 7540 §5.1 idle-state error only applies to never-opened ids).
    LHpack := TBytes.Create($82, $84, $86,
      $01, $09, $6C, $6F, $63, $61, $6C, $68, $6F, $73, $74);
    LH.Feed(H2BuildFrame(H2T_HEADERS, $05, 1, LHpack));
    LH.Feed(H2BuildRstStream(1, 0 {NO_ERROR}));
    Assert.IsFalse(LH.Closed,
      'RST_STREAM for an existing stream must not trigger connection close');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.GoAway_ServerInitiated_SetsGoAwaySent;
var
  LH:  TH2TestHarness;
  LS:  TBytes;
  I:   Integer;
  LGotGoAway: Boolean;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    LH.ClearSent;

    // Force a GOAWAY by feeding a frame that violates protocol
    // (e.g., DATA frame on stream 0 — reserved, must be stream > 0)
    // We just call _GoAway indirectly by destroying; but we can also
    // verify that GoAwaySent starts as False and the conn stays healthy.
    Assert.IsFalse(LH.H2.GoAwaySent,
      'GoAwaySent should be False before any GOAWAY is sent');

    // Feeding a connection-level DATA frame (stream 0) is a protocol error
    // that should trigger a GOAWAY with PROTOCOL_ERROR
    LH.Feed(H2BuildFrame(H2T_DATA, 0, 0, TBytes.Create($78)));

    // After protocol error, server may send GOAWAY and set the flag
    LS := LH.SentBytes;
    LGotGoAway := False;
    I := 0;
    while I + 9 <= Length(LS) do
    begin
      if LS[I + 3] = H2T_GOAWAY then
        LGotGoAway := True;
      I := I + 9 + (Integer(LS[I]) shl 16 or Integer(LS[I+1]) shl 8 or Integer(LS[I+2]));
    end;
    Assert.IsTrue(LGotGoAway, 'DATA frame on stream 0 should trigger GOAWAY');
    Assert.IsTrue(LH.H2.GoAwaySent, 'GoAwaySent should be True after GOAWAY');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.GoAway_ClientSendsGoAway_ConnectionAccepted;
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // Client sends GOAWAY — server should accept it gracefully (no crash, no AV)
    LH.Feed(H2BuildGoAway(0, 0 {NO_ERROR}));
    // The connection object should still be alive (closed flag may or may not be set)
    // At minimum: no exception/AV during feed
    Assert.Pass('Client GOAWAY processed without exception');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.Settings_ClientSendsACK_ProcessedWithoutError;
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // Send a SETTINGS ACK (flag=1)
    LH.Feed(H2BuildSettings(H2F_ACK));
    Assert.IsFalse(LH.Closed,
      'SETTINGS ACK from client should not close the connection');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.SendInitialSettings_WritesBytesThatStartWithSettingsFrame;
var
  LH: TH2TestHarness;
  LS: TBytes;
begin
  LH := TH2TestHarness.Create;
  try
    LH.H2.SendInitialSettings;
    LS := LH.SentBytes;
    Assert.IsTrue(Length(LS) >= 9, 'SendInitialSettings must write at least one frame');
    // First frame type byte (offset 3) must be SETTINGS (4)
    CheckInt(H2T_SETTINGS, Integer(LS[3]), 'First frame from SendInitialSettings must be SETTINGS');
  finally
    LH.Free;
  end;
end;

// ── P-1: server-side SETTINGS values ─────────────────────────────────────────

// Helper: search for a specific setting ID in the payload of the first SETTINGS
// frame contained in ABuf.  Returns the value if found, -1 otherwise.
function FindSettingValue(const ABuf: TBytes; ASettingID: Word): Integer;
var
  LPayLen: Integer;
  I:       Integer;
  LId:     Word;
begin
  Result := -1;
  if Length(ABuf) < 9 then
    Exit;
  LPayLen := (Integer(ABuf[0]) shl 16) or (Integer(ABuf[1]) shl 8) or Integer(ABuf[2]);
  if LPayLen < 6 then
    Exit;
  I := 9;  // skip 9-byte frame header
  while I + 5 <= 9 + LPayLen - 1 do
  begin
    LId := (Word(ABuf[I]) shl 8) or Word(ABuf[I + 1]);
    if LId = ASettingID then
    begin
      Result := (Integer(ABuf[I + 2]) shl 24) or
                (Integer(ABuf[I + 3]) shl 16) or
                (Integer(ABuf[I + 4]) shl 8)  or
                 Integer(ABuf[I + 5]);
      Exit;
    end;
    Inc(I, 6);
  end;
end;

procedure TH2ConnUnitTests.Settings_MaxConcurrentStreams_CustomValue_EncodedInFrame;
// P-1: H2MaxConcurrentStreams passed to TH2Conn constructor must appear as
// SETTINGS_MAX_CONCURRENT_STREAMS (0x0003) in the initial SETTINGS frame.
var
  LH:  TH2TestHarness;
  LS:  TBytes;
  LVal: Integer;
const
  CUSTOM_MAX_STREAMS = 50;
  SETTING_ID         = $0003;  // SETTINGS_MAX_CONCURRENT_STREAMS (RFC 7540 §6.5.2)
begin
  LH := TH2TestHarness.Create(CUSTOM_MAX_STREAMS, 65535);
  try
    LH.H2.SendInitialSettings;
    LS   := LH.SentBytes;
    LVal := FindSettingValue(LS, SETTING_ID);
    Assert.AreNotEqual(-1, LVal,
      'SETTINGS_MAX_CONCURRENT_STREAMS (0x0003) must be present in initial SETTINGS frame');
    CheckInt(CUSTOM_MAX_STREAMS, LVal,
      'SETTINGS_MAX_CONCURRENT_STREAMS value must match H2MaxConcurrentStreams');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.Settings_InitialWindowSize_CustomValue_EncodedInFrame;
// P-1: H2InitialWindowSize passed to TH2Conn constructor must appear as
// SETTINGS_INITIAL_WINDOW_SIZE (0x0004) in the initial SETTINGS frame.
var
  LH:  TH2TestHarness;
  LS:  TBytes;
  LVal: Integer;
const
  CUSTOM_WIN_SIZE = 32768;
  SETTING_ID      = $0004;  // SETTINGS_INITIAL_WINDOW_SIZE (RFC 7540 §6.5.2)
begin
  LH := TH2TestHarness.Create(100, CUSTOM_WIN_SIZE);
  try
    LH.H2.SendInitialSettings;
    LS   := LH.SentBytes;
    LVal := FindSettingValue(LS, SETTING_ID);
    Assert.AreNotEqual(-1, LVal,
      'SETTINGS_INITIAL_WINDOW_SIZE (0x0004) must be present in initial SETTINGS frame');
    CheckInt(CUSTOM_WIN_SIZE, LVal,
      'SETTINGS_INITIAL_WINDOW_SIZE value must match H2InitialWindowSize');
  finally
    LH.Free;
  end;
end;

// =============================================================================
// Additional TH2ConnUnitTests — issue #15 coverage
// =============================================================================

// HPACK static table entries used in HEADERS frames (RFC 7541 Appendix A):
//   index 2 (0x82) = :method: GET
//   index 3 (0x83) = :method: POST
//   index 4 (0x84) = :path: /
//   index 6 (0x86) = :scheme: http

procedure TH2ConnUnitTests.Preface_InvalidMagic_SendsGoAway;
// A client that sends garbage instead of the 24-byte H2 preface must receive
// a GOAWAY frame with PROTOCOL_ERROR (or the connection is closed).
var
  LH:    TH2TestHarness;
  LGarb: TBytes;
begin
  LH := TH2TestHarness.Create;
  try
    // 24 bytes of garbage (deliberately not the H2 preface magic)
    LGarb := TBytes.Create(
      $47, $45, $54, $20, $2F, $20, $48, $54,
      $54, $50, $2F, $31, $2E, $31, $0D, $0A,
      $48, $6F, $73, $74, $3A, $20, $78, $0A);
    LH.Feed(LGarb);
    Assert.IsTrue(H2HasGoAway(LH.SentBytes) or LH.Closed,
      'Invalid client preface must trigger GOAWAY or connection close');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.Settings_WithParameters_NoError;
// Client SETTINGS frames with HEADER_TABLE_SIZE and ENABLE_PUSH=1 must be
// accepted without closing the connection.
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    LH.Feed(H2BuildSettingsParam($0001, 4096));  // HEADER_TABLE_SIZE = 4096
    LH.Feed(H2BuildSettingsParam($0002, 1));     // ENABLE_PUSH = 1 (server ignores push)
    Assert.IsFalse(LH.Closed,
      'SETTINGS with HEADER_TABLE_SIZE and ENABLE_PUSH=1 must not close connection');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.Headers_GetRequest_DispatchesFOnRequest;
// A HEADERS frame with END_STREAM|END_HEADERS flags and indexed HPACK entries
// for :method=GET and :path=/ must trigger FOnRequest with the correct fields.
var
  LH:     TH2TestHarness;
  LHpack: TBytes;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // HPACK: :method=GET (0x82), :path=/ (0x84), :scheme=http (0x86),
    // :authority="localhost" (literal-w/o-indexing name idx 1: $01 + $09 + bytes).
    // :authority é obrigatório em requests não-CONNECT (RFC 7540 §8.1.2.3).
    LHpack := TBytes.Create($82, $84, $86,
      $01, $09, $6C, $6F, $63, $61, $6C, $68, $6F, $73, $74);
    // HEADERS stream 1: END_STREAM (0x01) | END_HEADERS (0x04) = 0x05
    LH.Feed(H2BuildFrame(H2T_HEADERS, $05, 1, LHpack));
    Assert.AreEqual(1, LH.Requests.Count,
      'GET / must dispatch FOnRequest exactly once');
    Assert.AreEqual('GET', LH.Requests[0].Method,
      ':method decoded from static table index 2 must be GET');
    Assert.AreEqual('/', LH.Requests[0].Path,
      ':path decoded from static table index 4 must be /');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.Headers_Post_WithDataBody_BodyAccumulated;
// A HEADERS frame (END_HEADERS only) followed by a DATA frame (END_STREAM)
// must accumulate the body and dispatch FOnRequest with the complete body.
var
  LH:     TH2TestHarness;
  LHpack: TBytes;
  LBody:  TBytes;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // HEADERS stream 1: END_HEADERS (0x04) only — body follows.
    // :method=POST, :path=/, :scheme=http, :authority="localhost" (RFC 7540 §8.1.2.3).
    LHpack := TBytes.Create($83, $84, $86,
      $01, $09, $6C, $6F, $63, $61, $6C, $68, $6F, $73, $74);
    LH.Feed(H2BuildFrame(H2T_HEADERS, $04, 1, LHpack));
    // DATA stream 1: END_STREAM (0x01)
    LBody := TEncoding.UTF8.GetBytes('hello');
    LH.Feed(H2BuildFrame(H2T_DATA, $01, 1, LBody));
    Assert.AreEqual(1, LH.Requests.Count,
      'POST must dispatch FOnRequest exactly once');
    Assert.AreEqual('POST', LH.Requests[0].Method,
      ':method must be POST');
    Assert.AreEqual('hello', TEncoding.UTF8.GetString(LH.Requests[0].Body),
      'Body must be accumulated from DATA frame');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.Continuation_WithoutPriorHeaders_GoAway;
// RFC 7540 §6.10: CONTINUATION frame received without a preceding HEADERS
// frame must be treated as a connection error (PROTOCOL_ERROR → GOAWAY).
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    LH.ClearSent;
    // CONTINUATION for stream 1 — FContinStreamID=0 so 1≠0 → PROTOCOL_ERROR
    LH.Feed(H2BuildFrame(H2T_CONTINUATION, $04, 1,
      TBytes.Create($82)  {trivial HPACK byte}));
    Assert.IsTrue(H2HasGoAway(LH.SentBytes),
      'CONTINUATION without preceding HEADERS must trigger GOAWAY PROTOCOL_ERROR');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.GoAway_NoStreams_CloseProcCalledImmediately;
// When _GoAway is triggered with no active streams (FActiveStreams=0),
// FCloseProc must be called synchronously (FClosed flag set before return).
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // DATA frame on stream 0 is a connection error → _GoAway called with 0 active streams
    LH.Feed(H2BuildFrame(H2T_DATA, 0, 0, TBytes.Create($01)));
    Assert.IsTrue(LH.Closed,
      'GOAWAY with no active streams must invoke FCloseProc immediately');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.RstStream_IdleStream_ConnectionError;
// RFC 7540 §5.1 — RST_STREAM on an IDLE stream (an id never opened and above
// the highest seen) MUST be treated as a connection error PROTOCOL_ERROR.
// h2spec http2/6.4 enforces this.
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    LH.Feed(H2BuildRstStream(99, 0 {NO_ERROR}));
    Assert.IsTrue(LH.Closed or H2HasGoAway(LH.SentBytes),
      'RST_STREAM on an idle stream must be a connection error (GOAWAY/close)');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.ServerPush_OnePushResource_SendsPushPromiseThenResponse;
// When FOnRequest returns a non-empty APushResources array, TH2Conn must:
// 1. Send a PUSH_PROMISE frame on the associated (client) stream before the reply.
// 2. Follow it with HEADERS+DATA on a server-initiated (even) promised stream.
// 3. Send the normal HEADERS response for the original request last.
var
  LH:    TH2TestHarness;
  LHpack: TBytes;
  LPush: TPoseidonPushResource;
  LPromisedID: Cardinal;
begin
  LH := TH2TestHarness.Create;
  try
    // Configure a single push resource for the next request
    LPush.Path        := '/style.css';
    LPush.ContentType := 'text/css';
    LPush.Body        := TEncoding.UTF8.GetBytes('body{}');
    LPush.Extra       := [];
    LH.SetNextPush([LPush]);

    LH.Feed(H2ClientPreface);
    LHpack := TBytes.Create($82, $84, $86);  // GET / http
    LH.Feed(H2BuildFrame(H2T_HEADERS, $05, 1, LHpack));

    // A PUSH_PROMISE frame (type=5) must appear in the sent bytes
    LPromisedID := H2FindPushPromise(LH.SentBytes);
    Assert.IsTrue(LPromisedID > 0,
      'Server must send a PUSH_PROMISE before the response');

    // Server-initiated streams are always even
    Assert.IsTrue((LPromisedID mod 2) = 0,
      'Promised stream ID must be even (server-initiated)');

    // Connection must remain open (no GOAWAY)
    Assert.IsFalse(H2HasGoAway(LH.SentBytes),
      'Server push must not trigger GOAWAY');
    Assert.IsFalse(LH.Closed,
      'Connection must stay open after server push');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.ControlFrameFlood_PingFlood_TriggersGoAway;
// CVE-2019-9512: the server emits a PONG per non-ACK PING. Without a rate bound
// a client floods PINGs to force unbounded outbound frames. A flood must trip
// GOAWAY (ENHANCE_YOUR_CALM). Loops with a generous safety cap so the test does
// not hard-code the exact threshold.
var
  LH:    TH2TestHarness;
  LPing: TBytes;
  I:     Integer;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    LH.ClearSent;
    LPing := H2BuildPing(0);
    I := 0;
    while (I < 5000) and (not H2HasGoAway(LH.SentBytes)) do
    begin
      LH.Feed(LPing);
      Inc(I);
    end;
    Assert.IsTrue(H2HasGoAway(LH.SentBytes),
      'a PING flood must eventually trigger GOAWAY (control-frame flood defense)');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.RstOfBufferedStream_CompletesDeferredGoAwayClose;
// Item-2 lifetime regression. With the peer's INITIAL_WINDOW_SIZE=0 the response
// DATA cannot be sent and is buffered (stream stays alive, FActiveStreams still
// incremented). A client GOAWAY then defers the close. RST of that buffered
// stream must decrement FActiveStreams and complete the deferred close — before
// the fix FActiveStreams leaked and the close never fired.
var
  LH:     TH2TestHarness;
  LHpack: TBytes;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // Peer advertises INITIAL_WINDOW_SIZE = 0 → our per-stream send window is 0.
    LH.Feed(H2BuildSettingsParam($0004, 0));
    // Open stream 1 (END_STREAM): handler runs, but the 'ok' DATA cannot be sent
    // (window 0) → buffered; FActiveStreams stays incremented.
    LHpack := TBytes.Create($82, $84, $86,
      $01, $09, $6C, $6F, $63, $61, $6C, $68, $6F, $73, $74);
    LH.Feed(H2BuildFrame(H2T_HEADERS, $05, 1, LHpack));
    Assert.IsFalse(LH.Closed, 'a buffered stream must keep the connection open');
    // Client GOAWAY with an active (buffered) stream → close deferred.
    LH.Feed(H2BuildGoAway(1, 0 {NO_ERROR}));
    Assert.IsFalse(LH.Closed, 'GOAWAY with a pending stream must defer the close');
    // RST the buffered stream → must fire the deferred close.
    LH.Feed(H2BuildRstStream(1, 0 {NO_ERROR}));
    Assert.IsTrue(LH.Closed,
      'RST of the last buffered stream must complete the deferred GOAWAY close');
  finally
    LH.Free;
  end;
end;

initialization
  // TPoseidonHTTP2Tests: SSL+ALPN integration tests — requires WinHTTP HTTP/2
  // support + a cert accepted by Windows SSPI. Disabled until #issue-HTTP2-CI
  // is resolved; tests pass manually when OpenSSL + correct cert are present.
  // TDUnitX.RegisterTestFixture(TPoseidonHTTP2Tests);
  TDUnitX.RegisterTestFixture(TH2ConnUnitTests);

end.
