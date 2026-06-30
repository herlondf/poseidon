unit Poseidon.Tests.Integration;

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
  ITEST_PORT = 19999;
  ITEST_BASE = 'http://localhost:19999';

type
  [TestFixture]
  TPoseidonIntegrationTests = class
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

procedure TPoseidonIntegrationTests.SetupFixture;
begin
  TPoseidonNative.Get('/itest/ping',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send('pong');
    end);

  TPoseidonNative.Get('/itest/param/:id',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send(Req.Params.Get('id'));
    end);

  TPoseidonNative.Post('/itest/echo',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send(Req.RawBody);
    end);

  TPoseidonNative.Post('/itest/created',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Status(201).Send('created');
    end);

  FServerThread := TThread.CreateAnonymousThread(
    procedure
    begin
      TPoseidonNative.Listen(ITEST_PORT);
    end);
  FServerThread.FreeOnTerminate := False;
  FServerThread.Start;

  Sleep(300);
end;

procedure TPoseidonIntegrationTests.TeardownFixture;
begin
  TPoseidonNative.StopListen;
  FServerThread.WaitFor;
  FreeAndNil(FServerThread);
end;

function TPoseidonIntegrationTests.DoGet(const APath: string): IHTTPResponse;
var
  LClient: THTTPClient;
begin
  LClient := THTTPClient.Create;
  try
    Result := LClient.Get(ITEST_BASE + APath);
  finally
    LClient.Free;
  end;
end;

function TPoseidonIntegrationTests.DoPost(const APath, ABody: string): IHTTPResponse;
var
  LClient: THTTPClient;
  LStream: TStringStream;
begin
  LClient := THTTPClient.Create;
  try
    LStream := TStringStream.Create(ABody, TEncoding.UTF8);
    try
      Result := LClient.Post(ITEST_BASE + APath, LStream);
    finally
      LStream.Free;
    end;
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonIntegrationTests.Get_Ping_Returns200WithBody;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/itest/ping');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('pong', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonIntegrationTests.Get_RouteParam_ExtractsValue;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/itest/param/hello42');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('hello42', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonIntegrationTests.Post_WithBody_ReturnsBodyEcho;
var
  LResp: IHTTPResponse;
begin
  LResp := DoPost('/itest/echo', 'hello world');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('hello world', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonIntegrationTests.UnknownRoute_Returns404;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/itest/doesnotexist');
  Assert.AreEqual(404, LResp.StatusCode);
end;

procedure TPoseidonIntegrationTests.StatusOverride_Returns201;
var
  LResp: IHTTPResponse;
begin
  LResp := DoPost('/itest/created', '');
  Assert.AreEqual(201, LResp.StatusCode);
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonIntegrationTests);

end.
