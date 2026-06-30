unit Poseidon.Tests.Router;

interface

uses
  DUnitX.TestFramework,
  Web.HTTPApp,
  Poseidon.Core.RouterTree,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Proc,
  Poseidon.Callback,
  Poseidon.Commons,
  Poseidon.Exception,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse;

type
  [TestFixture]
  TPoseidonRouterTests = class
  private
    FRouter: TPoseidonRouterTree;
    FWebReq: TMockWebRequest;
    FWebRes: TMockWebResponse;
    FRequest: TPoseidonRequest;
    FResponse: TPoseidonResponse;

    procedure Route(const AMethod, APath: string);
    function LastBody: string;
    function LastStatus: Integer;
  public
    [Setup]
    procedure Setup;
    [TearDown]
    procedure TearDown;

    [Test]
    procedure LiteralRoute_GET_Matches;
    [Test]
    procedure LiteralRoute_POST_Matches;
    [Test]
    procedure LiteralRoute_WrongMethod_Returns405;
    [Test]
    procedure LiteralRoute_NotFound_Returns404;
    [Test]
    procedure ParamRoute_ExtractsParamValue;
    [Test]
    procedure ParamRoute_MultipleParams;
    [Test]
    procedure MiddlewareExecutesBefore_Handler;
    [Test]
    procedure MiddlewareCanShortCircuit;
    [Test]
    procedure NestedPaths_Match;
    [Test]
    procedure Wildcard_CatchAll;
    [Test]
    procedure SpecificRouteWins_OverParam;
  end;

implementation

procedure TPoseidonRouterTests.Setup;
begin
  FRouter  := TPoseidonRouterTree.Create;
  FWebReq  := TMockWebRequest.Create;
  FWebRes  := TMockWebResponse.Create(FWebReq);
  FRequest  := TPoseidonRequest.Create(FWebReq);
  FResponse := TPoseidonResponse.Create(FWebRes);
end;

procedure TPoseidonRouterTests.TearDown;
begin
  FResponse.Free;
  FRequest.Free;
  FWebRes.Free;
  FWebReq.Free;
  FRouter.Free;
end;

procedure TPoseidonRouterTests.Route(const AMethod, APath: string);
begin
  FWebReq.SetMethod(AMethod);
  FWebReq.SetPathInfo(APath);
  FRouter.Execute(FRequest, FResponse);
end;

function TPoseidonRouterTests.LastBody: string;
begin Result := FWebRes.Content; end;

function TPoseidonRouterTests.LastStatus: Integer;
begin Result := FWebRes.StatusCode; end;

procedure TPoseidonRouterTests.LiteralRoute_GET_Matches;
begin
  FRouter.RegisterRoute(mtGet, '/ping',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin Res.Send('pong'); end);

  Route('GET', '/ping');
  Assert.AreEqual('pong', LastBody);
end;

procedure TPoseidonRouterTests.LiteralRoute_POST_Matches;
begin
  FRouter.RegisterRoute(mtPost, '/items',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin Res.Status(201).Send('created'); end);

  Route('POST', '/items');
  Assert.AreEqual(201, LastStatus);
  Assert.AreEqual('created', LastBody);
end;

procedure TPoseidonRouterTests.LiteralRoute_WrongMethod_Returns405;
begin
  FRouter.RegisterRoute(mtGet, '/users',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin Res.Send('ok'); end);

  Route('DELETE', '/users');
  Assert.AreEqual(405, LastStatus);
end;

procedure TPoseidonRouterTests.LiteralRoute_NotFound_Returns404;
begin
  FRouter.RegisterRoute(mtGet, '/exists',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin Res.Send('ok'); end);

  Route('GET', '/does-not-exist');
  Assert.AreEqual(404, LastStatus);
end;

procedure TPoseidonRouterTests.ParamRoute_ExtractsParamValue;
var LCaptured: string;
begin
  FRouter.RegisterRoute(mtGet, '/users/:id',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      LCaptured := Req.Params.Get('id');
      Res.Send(LCaptured);
    end);

  Route('GET', '/users/42');
  Assert.AreEqual('42', LCaptured);
  Assert.AreEqual('42', LastBody);
end;

procedure TPoseidonRouterTests.ParamRoute_MultipleParams;
var LUserId, LOrderId: string;
begin
  FRouter.RegisterRoute(mtGet, '/users/:userId/orders/:orderId',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      LUserId  := Req.Params.Get('userId');
      LOrderId := Req.Params.Get('orderId');
      Res.Send('ok');
    end);

  Route('GET', '/users/10/orders/99');
  Assert.AreEqual('10', LUserId);
  Assert.AreEqual('99', LOrderId);
end;

procedure TPoseidonRouterTests.MiddlewareExecutesBefore_Handler;
var LOrder: string;
begin
  FRouter.RegisterMiddleware('/',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      LOrder := LOrder + 'MW1-';
      Next;
    end);

  FRouter.RegisterRoute(mtGet, '/test',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      LOrder := LOrder + 'HANDLER';
      Res.Send('ok');
    end);

  Route('GET', '/test');
  Assert.AreEqual('MW1-HANDLER', LOrder);
end;

procedure TPoseidonRouterTests.MiddlewareCanShortCircuit;
var LHandlerCalled: Boolean;
begin
  LHandlerCalled := False;
  FRouter.RegisterMiddleware('/',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      Res.Status(401).Send('Unauthorized');
      // Not calling Next — pipeline stops here
    end);

  FRouter.RegisterRoute(mtGet, '/protected',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      LHandlerCalled := True;
      Res.Send('ok');
    end);

  Route('GET', '/protected');
  Assert.IsFalse(LHandlerCalled);
  Assert.AreEqual(401, LastStatus);
end;

procedure TPoseidonRouterTests.NestedPaths_Match;
begin
  FRouter.RegisterRoute(mtGet, '/api/v1/users',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin Res.Send('v1-users'); end);

  Route('GET', '/api/v1/users');
  Assert.AreEqual('v1-users', LastBody);
end;

procedure TPoseidonRouterTests.Wildcard_CatchAll;
begin
  FRouter.RegisterRoute(mtGet, '/*',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin Res.Status(404).Send('Not Found'); end);

  Route('GET', '/anything/at/all');
  Assert.AreEqual(404, LastStatus);
end;

procedure TPoseidonRouterTests.SpecificRouteWins_OverParam;
var LWhichRoute: string;
begin
  FRouter.RegisterRoute(mtGet, '/users/me',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      LWhichRoute := 'literal-me';
      Res.Send('me');
    end);

  FRouter.RegisterRoute(mtGet, '/users/:id',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      LWhichRoute := 'param-id';
      Res.Send('param');
    end);

  Route('GET', '/users/me');
  Assert.AreEqual('literal-me', LWhichRoute, 'Literal route must win over :param');
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonRouterTests);

end.
