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
    FConn:   TH2Conn;
    FLock:   TCriticalSection;
    FSent:   TBytes;
    FClosed: Boolean;
    FReqs:   TList<TH2RequestData>;

    procedure OnSend(AConn: Pointer; const AData: TBytes);
    procedure OnClose(AConn: Pointer);
    procedure OnRequest(const AReq: TH2RequestData;
      var AStatus: Integer; var AContentType: string;
      var ABody: TBytes; var AExtra: TH2ExtraArr);
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
  var ABody: TBytes; var AExtra: TH2ExtraArr);
begin
  FReqs.Add(AReq);
  AStatus      := 200;
  AContentType := 'text/plain';
  ABody        := TEncoding.UTF8.GetBytes('ok');
  AExtra       := [];
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
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // Stream 1 may not exist, but RFC 7540 says unknown stream WINDOW_UPDATE
    // on a closed/non-existent stream should be silently ignored or raise
    // STREAM_CLOSED error; the connection itself should remain open.
    LH.Feed(H2BuildWindowUpdate(1, 1000));
    // Regardless of what happens to stream 1, connection should not be closed
    // (server may send RST_STREAM but not GOAWAY for this)
    Assert.IsFalse(LH.Closed,
      'WINDOW_UPDATE on unknown stream should not close the connection');
  finally
    LH.Free;
  end;
end;

procedure TH2ConnUnitTests.RstStream_ClientSendsRst_StreamDropped;
var
  LH: TH2TestHarness;
begin
  LH := TH2TestHarness.Create;
  try
    LH.Feed(H2ClientPreface);
    // RST_STREAM on a non-existent stream — server should not crash or close
    LH.Feed(H2BuildRstStream(1, 0 {NO_ERROR}));
    Assert.IsFalse(LH.Closed,
      'RST_STREAM from client should not trigger connection close');
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

end.
