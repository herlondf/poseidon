unit Poseidon.Tests.HttpServer;

// DUnitX integration tests for TPoseidonNativeServer (HTTP/1.1).
//
// Fixture 1 — TPoseidonHttpServerTests  (port 19001): basic HTTP paths
// Fixture 2 — TPoseidonHttpServerAdvTests (port 19002): security / reliability
//   properties: AllowedMethods, MaxRequestSize, MaxQueueDepth,
//   SecureHeaders, ServerBanner, RateLimit, path traversal, request smuggling.
//
// HTTP client: System.Net.HttpClient (Delphi RTL — no external deps).

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
  end;

  // ── Fixture 2: security / reliability properties ────────────────────────────
  [TestFixture]
  TPoseidonHttpServerAdvTests = class  // port 19002
  private
    FEvent: TEvent;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    // AllowedMethods (S-1)
    [Test]
    procedure AllowedMethods_DisallowedVerb_Returns405;
    [Test]
    procedure AllowedMethods_AllowedVerb_Returns200;

    // Path traversal (S-2)
    [Test]
    procedure PathTraversal_DotDotSegment_Returns400;

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

    // Rate limit
    [Test]
    procedure RateLimit_PerIP_ExceededReturns429;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.URLClient,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer;

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
    LResponse := LClient.Get(BASE_URL + '/echo/Poseidon');
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
    LResponse := LClient.Get(BASE_URL + '/nao-existe');
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

// =============================================================================
// Fixture 2 — TPoseidonHttpServerAdvTests (port 19002)
// =============================================================================

const
  ADV_PORT = 19002;
  ADV_BASE = 'http://127.0.0.1:19002';

type
  TAdvExtraHeaders = TArray<TPair<string,string>>;

var
  GAdvServer:      TPoseidonNativeServer;
  GAdvListenReady: TEvent;

procedure AdvHandler(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TAdvExtraHeaders);
begin
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

procedure TPoseidonHttpServerAdvTests.AllowedMethods_DisallowedVerb_Returns405;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  GAdvServer.AllowedMethods := ['GET', 'POST'];
  LClient := THTTPClient.Create;
  try
    LClient.HandleRedirects := False;
    LResponse := LClient.Delete(ADV_BASE + '/');
    Assert.AreEqual(405, LResponse.StatusCode,
      'DELETE should be rejected with 405 when not in AllowedMethods');
  finally
    LClient.Free;
    GAdvServer.AllowedMethods := [];  // reset to unrestricted
  end;
end;

procedure TPoseidonHttpServerAdvTests.AllowedMethods_AllowedVerb_Returns200;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  GAdvServer.AllowedMethods := ['GET', 'POST'];
  LClient := THTTPClient.Create;
  try
    LResponse := LClient.Get(ADV_BASE + '/');
    Assert.AreEqual(200, LResponse.StatusCode,
      'GET should succeed when in AllowedMethods');
  finally
    LClient.Free;
    GAdvServer.AllowedMethods := [];
  end;
end;

// ── Path traversal ────────────────────────────────────────────────────────────

procedure TPoseidonHttpServerAdvTests.PathTraversal_DotDotSegment_Returns400;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LClient.HandleRedirects := False;
    LResponse := LClient.Get(ADV_BASE + '/../etc/passwd');
    Assert.AreEqual(400, LResponse.StatusCode,
      'Path with .. segment should return 400');
  finally
    LClient.Free;
  end;
end;

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
var
  LTasks:    TArray<ITask>;
  LWork:     TProc;
  I:         Integer;
  LGot503:   Integer;  // 0 = false, 1 = true (atomic via TInterlocked)
const
  QUEUE_LIMIT = 1;
  FLOOD_COUNT = 20;
begin
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
    TTask.WaitForAll(LTasks, 8000);
    Assert.IsTrue(LGot503 = 1,
      'At least one request should receive 503 when MaxQueueDepth is exceeded');
  finally
    GAdvServer.MaxQueueDepth := 0;  // restore unlimited
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

// ── Rate limit ────────────────────────────────────────────────────────────────

procedure TPoseidonHttpServerAdvTests.RateLimit_PerIP_ExceededReturns429;
var
  LClient:   THTTPClient;
  LResponse: IHTTPResponse;
  LGot429:   Boolean;
  I:         Integer;
begin
  GAdvServer.RateLimitPerIP := 1;  // at most 1 req/s from 127.0.0.1
  LClient  := THTTPClient.Create;
  LGot429  := False;
  try
    // Fire several sequential requests — the second onward should hit the limit
    for I := 1 to 10 do
    begin
      LClient.HandleRedirects := False;
      try
        LResponse := LClient.Get(ADV_BASE + '/');
        if LResponse.StatusCode = 429 then
        begin
          LGot429 := True;
          Break;
        end;
      except
      end;
    end;
    Assert.IsTrue(LGot429,
      'Requests exceeding RateLimitPerIP should receive 429');
  finally
    LClient.Free;
    GAdvServer.RateLimitPerIP := 0;  // restore unlimited
  end;
end;

end.
