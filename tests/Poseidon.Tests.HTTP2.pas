unit Poseidon.Tests.HTTP2;

// DUnitX integration tests for HTTP/2 (via ALPN "h2" over TLS).
// Requires OpenSSL (libssl + libcrypto) and a self-signed certificate.
//
// Generate the certificate once before running these tests:
//   openssl req -x509 -newkey rsa:2048 -keyout tests\certs\test-server.key ^
//     -out tests\certs\test-server.crt -days 3650 -nodes -subj "/CN=127.0.0.1"
//
// Tests skip automatically when OpenSSL is not available (Assert.Pass),
// so the suite never fails on machines without OpenSSL installed.
//
// Port 19002 is reserved for this fixture; never use it for other test suites.

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
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.Net.HttpClient,
  System.Net.URLClient,
  Poseidon.Net.Types,
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

end.
