unit Poseidon.Tests.HttpServer;

// DUnitX integration tests for TPoseidonNativeServer (HTTP/1.1).
// Server runs on port 19001 in a background thread.
// HTTP client: System.Net.HttpClient (Delphi RTL — no external dependencies).
//
// Port 19001 is reserved for this fixture; never use it for other test suites.

interface

uses
  DUnitX.TestFramework,
  System.SyncObjs;

type
  {$M+}
  [TestFixture]
  TPoseidonHttpServerTests = class
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
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  System.Net.URLClient,
  Poseidon.Net.HttpServer;

const
  INTEST_PORT = 19001;
  BASE_URL    = 'http://127.0.0.1:19001';

var
  GServer: TPoseidonNativeServer;

{ TPoseidonHttpServerTests }

procedure TPoseidonHttpServerTests.SetupFixture;
begin
  FEvent  := TEvent.Create(nil, True, False, '');
  GServer := TPoseidonNativeServer.Create;

  TThread.CreateAnonymousThread(
    procedure
    begin
      GServer.Listen('127.0.0.1', INTEST_PORT,
        procedure(const AReq: TPoseidonNativeRequest;
          out AStatus:       Integer;
          out AContentType:  string;
          out ABody:         TBytes;
          out AExtraHeaders: TArray<TPair<string,string>>)
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
        end,
        procedure begin FEvent.SetEvent; end);
    end).Start;

  Assert.AreEqual(TWaitResult.wrSignaled,
    FEvent.WaitFor(5000), 'HTTP/1.1 server did not start within 5 s');
end;

procedure TPoseidonHttpServerTests.TeardownFixture;
begin
  GServer.Stop;
  FreeAndNil(GServer);
  FreeAndNil(FEvent);
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

end.
