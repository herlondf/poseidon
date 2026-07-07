unit Poseidon.Tests.Middleware.OpenAPI;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TOpenAPIMiddlewareTests = class
  public
    [Test]
    procedure SpecEndpointReturns200;
    [Test]
    procedure SpecContainsOpenAPIVersion;
    [Test]
    procedure SpecContainsRegisteredRoute;
    [Test]
    procedure UIEndpointReturnsHtml;
    [Test]
    procedure NonDocPathCallsNext;
    [Test]
    procedure PathParamsConverted;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.OpenAPI;

function BuildTestMiddleware: TNativeMiddlewareFunc;
begin
  Result := TPoseidonOpenAPI.Create
    .Title('Test API')
    .Version('2.0.0')
    .AddRoute('GET', '/ping', 'Health check')
    .AddRoute('GET', '/users/:id', 'Get user by ID')
    .Build;
end;

procedure TOpenAPIMiddlewareTests.SpecEndpointReturns200;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := BuildTestMiddleware;
  LCtx := TContextBuilder.New.Path('/api-docs').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.AreEqual('application/json', LCtx.ContentType);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TOpenAPIMiddlewareTests.SpecContainsOpenAPIVersion;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LBody: string;
begin
  LMw := BuildTestMiddleware;
  LCtx := TContextBuilder.New.Path('/api-docs').Build;
  LMw(LCtx, procedure begin end);
  LBody := BodyAsString(LCtx);
  Assert.IsTrue(LBody.Contains('3.0.3'));
  Assert.IsTrue(LBody.Contains('Test API'));
  Assert.IsTrue(LBody.Contains('2.0.0'));
end;

procedure TOpenAPIMiddlewareTests.SpecContainsRegisteredRoute;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LBody: string;
begin
  LMw := BuildTestMiddleware;
  LCtx := TContextBuilder.New.Path('/api-docs').Build;
  LMw(LCtx, procedure begin end);
  LBody := BodyAsString(LCtx);
  Assert.IsTrue(LBody.Contains('/ping'));
  Assert.IsTrue(LBody.Contains('Health check'));
end;

procedure TOpenAPIMiddlewareTests.UIEndpointReturnsHtml;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := BuildTestMiddleware;
  LCtx := TContextBuilder.New.Path('/api-docs/ui').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.IsTrue(LCtx.ContentType.Contains('text/html'));
  Assert.IsTrue(BodyAsString(LCtx).Contains('swagger-ui'));
end;

procedure TOpenAPIMiddlewareTests.NonDocPathCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LMw := BuildTestMiddleware;
  LCtx := TContextBuilder.New.Path('/api/data').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
  Assert.IsFalse(LCtx.Handled);
end;

procedure TOpenAPIMiddlewareTests.PathParamsConverted;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LBody: string;
begin
  LMw := BuildTestMiddleware;
  LCtx := TContextBuilder.New.Path('/api-docs').Build;
  LMw(LCtx, procedure begin end);
  LBody := BodyAsString(LCtx);
  Assert.IsTrue(LBody.Contains('{id}'));
  Assert.IsFalse(LBody.Contains(':id'));
end;

initialization
  TDUnitX.RegisterTestFixture(TOpenAPIMiddlewareTests);

end.
