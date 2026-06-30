unit Poseidon.Tests.Integration.Native;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.SysUtils,
  System.Net.HttpClient,
  Poseidon.Provider.Native,
  Poseidon.Core,
  Poseidon.Request,
  Poseidon.Response;

const
  INTEST_PORT = 19999;
  INTEST_BASE = 'http://localhost:19999';

type
  [TestFixture]
  TPoseidonNativeIntegrationTests = class
  private
    FServerThread: TThread;
    function DoGet(const APath: string): IHTTPResponse;
    function DoPost(const APath, ABody: string): IHTTPResponse;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;

    [Test]
    procedure Get_Ping_Returns200WithBody;
    [Test]
    procedure Get_RouteParam_ExtractsValue;
    [Test]
    procedure Post_WithBody_ReturnsBodyEcho;
    [Test]
    procedure UnknownRoute_Returns404;
    [Test]
    procedure StatusOverride_Returns201;
  end;

implementation

procedure TPoseidonNativeIntegrationTests.SetupFixture;
begin
  TPoseidonNative.Get('/intest/ping',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send('pong');
    end);

  TPoseidonNative.Get('/intest/param/:id',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send(Req.Params.Get('id'));
    end);

  TPoseidonNative.Post('/intest/echo',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send(Req.RawBody);
    end);

  TPoseidonNative.Post('/intest/created',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Status(201).Send('created');
    end);

  FServerThread := TThread.CreateAnonymousThread(
    procedure
    begin
      TPoseidonNative.Listen(INTEST_PORT);
    end);
  FServerThread.FreeOnTerminate := False;
  FServerThread.Start;

  Sleep(300);
end;

procedure TPoseidonNativeIntegrationTests.TeardownFixture;
begin
  TPoseidonNative.StopListen;
  FServerThread.WaitFor;
  FreeAndNil(FServerThread);
end;

function TPoseidonNativeIntegrationTests.DoGet(const APath: string): IHTTPResponse;
var
  LClient: THTTPClient;
begin
  LClient := THTTPClient.Create;
  try
    Result := LClient.Get(INTEST_BASE + APath);
  finally
    LClient.Free;
  end;
end;

function TPoseidonNativeIntegrationTests.DoPost(
  const APath, ABody: string): IHTTPResponse;
var
  LClient: THTTPClient;
  LStream: TStringStream;
begin
  LClient := THTTPClient.Create;
  try
    LStream := TStringStream.Create(ABody, TEncoding.UTF8);
    try
      Result := LClient.Post(INTEST_BASE + APath, LStream);
    finally
      LStream.Free;
    end;
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonNativeIntegrationTests.Get_Ping_Returns200WithBody;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/intest/ping');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('pong', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonNativeIntegrationTests.Get_RouteParam_ExtractsValue;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/intest/param/hello42');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('hello42', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonNativeIntegrationTests.Post_WithBody_ReturnsBodyEcho;
var
  LResp: IHTTPResponse;
begin
  LResp := DoPost('/intest/echo', 'hello world');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('hello world', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonNativeIntegrationTests.UnknownRoute_Returns404;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/intest/doesnotexist');
  Assert.AreEqual(404, LResp.StatusCode);
end;

procedure TPoseidonNativeIntegrationTests.StatusOverride_Returns201;
var
  LResp: IHTTPResponse;
begin
  LResp := DoPost('/intest/created', '');
  Assert.AreEqual(201, LResp.StatusCode);
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonNativeIntegrationTests);

end.
