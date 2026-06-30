unit Poseidon.Tests.Integration.CrossSocket;

interface

uses
  DUnitX.TestFramework,
  System.Classes,
  System.SysUtils,
  System.Net.HttpClient,
  Poseidon.Provider.CrossSocket,
  Poseidon.Core,
  Poseidon.Request,
  Poseidon.Response;

const
  ICSTEST_PORT = 19998;
  ICSTEST_BASE = 'http://localhost:19998';

type
  [TestFixture]
  TPoseidonCrossSocketIntegrationTests = class
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

procedure TPoseidonCrossSocketIntegrationTests.SetupFixture;
begin
  TPoseidonCrossSocket.Get('/icstest/ping',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send('pong');
    end);

  TPoseidonCrossSocket.Get('/icstest/param/:id',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send(Req.Params.Get('id'));
    end);

  TPoseidonCrossSocket.Post('/icstest/echo',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Send(Req.RawBody);
    end);

  TPoseidonCrossSocket.Post('/icstest/created',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.Status(201).Send('created');
    end);

  FServerThread := TThread.CreateAnonymousThread(
    procedure
    begin
      TPoseidonCrossSocket.Listen(ICSTEST_PORT);
    end);
  FServerThread.FreeOnTerminate := False;
  FServerThread.Start;

  Sleep(300);
end;

procedure TPoseidonCrossSocketIntegrationTests.TeardownFixture;
begin
  TPoseidonCrossSocket.StopListen;
  FServerThread.WaitFor;
  FreeAndNil(FServerThread);
end;

function TPoseidonCrossSocketIntegrationTests.DoGet(const APath: string): IHTTPResponse;
var
  LClient: THTTPClient;
begin
  LClient := THTTPClient.Create;
  try
    Result := LClient.Get(ICSTEST_BASE + APath);
  finally
    LClient.Free;
  end;
end;

function TPoseidonCrossSocketIntegrationTests.DoPost(
  const APath, ABody: string): IHTTPResponse;
var
  LClient: THTTPClient;
  LStream: TStringStream;
begin
  LClient := THTTPClient.Create;
  try
    LStream := TStringStream.Create(ABody, TEncoding.UTF8);
    try
      Result := LClient.Post(ICSTEST_BASE + APath, LStream);
    finally
      LStream.Free;
    end;
  finally
    LClient.Free;
  end;
end;

procedure TPoseidonCrossSocketIntegrationTests.Get_Ping_Returns200WithBody;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/icstest/ping');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('pong', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonCrossSocketIntegrationTests.Get_RouteParam_ExtractsValue;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/icstest/param/hello42');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('hello42', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonCrossSocketIntegrationTests.Post_WithBody_ReturnsBodyEcho;
var
  LResp: IHTTPResponse;
begin
  LResp := DoPost('/icstest/echo', 'hello world');
  Assert.AreEqual(200, LResp.StatusCode);
  Assert.AreEqual('hello world', LResp.ContentAsString(TEncoding.UTF8));
end;

procedure TPoseidonCrossSocketIntegrationTests.UnknownRoute_Returns404;
var
  LResp: IHTTPResponse;
begin
  LResp := DoGet('/icstest/doesnotexist');
  Assert.AreEqual(404, LResp.StatusCode);
end;

procedure TPoseidonCrossSocketIntegrationTests.StatusOverride_Returns201;
var
  LResp: IHTTPResponse;
begin
  LResp := DoPost('/icstest/created', '');
  Assert.AreEqual(201, LResp.StatusCode);
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonCrossSocketIntegrationTests);

end.
