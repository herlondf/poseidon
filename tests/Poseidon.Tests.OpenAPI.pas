unit Poseidon.Tests.OpenAPI;

interface

uses
  DUnitX.TestFramework,
  System.JSON,
  Web.HTTPApp,
  Poseidon.Core.Registry,
  Poseidon.OpenAPI,
  Poseidon.Commons;

type
  [TestFixture]
  TPoseidonOpenAPITests = class
  private
    FConfig: TPoseidonOpenAPIConfig;
    function ParseSpec: TJSONObject;
  public
    [Setup]
    procedure Setup;

    [Test]
    procedure Spec_HasOpenAPIVersion;
    [Test]
    procedure Spec_HasInfoTitleAndVersion;
    [Test]
    procedure Spec_LiteralRoute_AppearsInPaths;
    [Test]
    procedure Spec_ParamRoute_ConvertedToOpenAPIFormat;
    [Test]
    procedure Spec_ParamRoute_HasPathParameters;
    [Test]
    procedure Spec_PostRoute_HasRequestBody;
    [Test]
    procedure Spec_SpecPath_ExcludedFromPaths;
    [Test]
    procedure Registry_ToOpenAPIPath_ConvertsColonParams;
  end;

implementation

procedure TPoseidonOpenAPITests.Setup;
begin
  // Clear registry between tests
  TPoseidonRouteRegistry.Register(mtGet,    '/spec-test/users');
  TPoseidonRouteRegistry.Register(mtGet,    '/spec-test/users/:id');
  TPoseidonRouteRegistry.Register(mtPost,   '/spec-test/users');
  TPoseidonRouteRegistry.Register(mtDelete, '/spec-test/users/:id');

  FConfig.Title        := 'Test API';
  FConfig.Version      := '2.0.0';
  FConfig.Description  := 'Test description';
  FConfig.ContactName  := '';
  FConfig.ContactEmail := '';
  FConfig.LicenseName  := '';
  FConfig.SpecPath     := '/api-docs';
  FConfig.UIPath       := '/api-docs/ui';
end;

function TPoseidonOpenAPITests.ParseSpec: TJSONObject;
var LSpec: string;
begin
  LSpec := TPoseidonOpenAPI.GenerateSpec(FConfig);
  Result := TJSONObject.ParseJSONValue(LSpec) as TJSONObject;
  Assert.IsNotNull(Result, 'Spec must be valid JSON');
end;

procedure TPoseidonOpenAPITests.Spec_HasOpenAPIVersion;
var LSpec: TJSONObject;
begin
  LSpec := ParseSpec;
  try
    Assert.AreEqual('3.0.3', LSpec.GetValue<string>('openapi'));
  finally
    LSpec.Free;
  end;
end;

procedure TPoseidonOpenAPITests.Spec_HasInfoTitleAndVersion;
var LSpec: TJSONObject;
    LInfo: TJSONObject;
begin
  LSpec := ParseSpec;
  try
    LInfo := LSpec.GetValue<TJSONObject>('info');
    Assert.IsNotNull(LInfo);
    Assert.AreEqual('Test API', LInfo.GetValue<string>('title'));
    Assert.AreEqual('2.0.0',    LInfo.GetValue<string>('version'));
  finally
    LSpec.Free;
  end;
end;

procedure TPoseidonOpenAPITests.Spec_LiteralRoute_AppearsInPaths;
var LSpec, LPaths, LPathItem: TJSONObject;
begin
  LSpec := ParseSpec;
  try
    LPaths := LSpec.GetValue<TJSONObject>('paths');
    Assert.IsNotNull(LPaths);
    LPathItem := LPaths.GetValue<TJSONObject>('/spec-test/users');
    Assert.IsNotNull(LPathItem, 'Path /spec-test/users must exist');
    Assert.IsNotNull(LPathItem.GetValue('get'), 'GET method must be present');
  finally
    LSpec.Free;
  end;
end;

procedure TPoseidonOpenAPITests.Spec_ParamRoute_ConvertedToOpenAPIFormat;
var LSpec, LPaths: TJSONObject;
begin
  LSpec := ParseSpec;
  try
    LPaths := LSpec.GetValue<TJSONObject>('paths');
    Assert.IsNotNull(LPaths.GetValue('/spec-test/users/{id}'),
      'Path parameter must be in {id} format, not :id');
  finally
    LSpec.Free;
  end;
end;

procedure TPoseidonOpenAPITests.Spec_ParamRoute_HasPathParameters;
var
  LSpec, LPaths, LPathItem, LOperation: TJSONObject;
  LParams: TJSONArray;
  LParam: TJSONObject;
begin
  LSpec := ParseSpec;
  try
    LPaths    := LSpec.GetValue<TJSONObject>('paths');
    LPathItem := LPaths.GetValue<TJSONObject>('/spec-test/users/{id}');
    LOperation := LPathItem.GetValue<TJSONObject>('get');
    LParams   := LOperation.GetValue<TJSONArray>('parameters');

    Assert.IsNotNull(LParams, 'Path params must be present');
    Assert.AreEqual(1, LParams.Count, 'Must have 1 path parameter');

    LParam := LParams.Items[0] as TJSONObject;
    Assert.AreEqual('id',   LParam.GetValue<string>('name'));
    Assert.AreEqual('path', LParam.GetValue<string>('in'));
    Assert.IsTrue(LParam.GetValue<Boolean>('required'));
  finally
    LSpec.Free;
  end;
end;

procedure TPoseidonOpenAPITests.Spec_PostRoute_HasRequestBody;
var
  LSpec, LPaths, LPathItem, LOperation: TJSONObject;
begin
  LSpec := ParseSpec;
  try
    LPaths     := LSpec.GetValue<TJSONObject>('paths');
    LPathItem  := LPaths.GetValue<TJSONObject>('/spec-test/users');
    LOperation := LPathItem.GetValue<TJSONObject>('post');

    Assert.IsNotNull(LOperation.GetValue('requestBody'),
      'POST must include requestBody');
  finally
    LSpec.Free;
  end;
end;

procedure TPoseidonOpenAPITests.Spec_SpecPath_ExcludedFromPaths;
var LSpec, LPaths: TJSONObject;
begin
  // Register the spec path itself (as happens when Use(OpenAPI.Middleware) is called)
  TPoseidonRouteRegistry.Register(mtGet, '/api-docs');
  LSpec := ParseSpec;
  try
    LPaths := LSpec.GetValue<TJSONObject>('paths');
    Assert.IsNull(LPaths.GetValue('/api-docs'),
      '/api-docs must not appear in the spec paths');
  finally
    LSpec.Free;
  end;
end;

procedure TPoseidonOpenAPITests.Registry_ToOpenAPIPath_ConvertsColonParams;
begin
  Assert.AreEqual('/users/{id}',
    TPoseidonRouteRegistry.ToOpenAPIPath('/users/:id'));
  Assert.AreEqual('/a/{b}/c/{d}',
    TPoseidonRouteRegistry.ToOpenAPIPath('/a/:b/c/:d'));
  Assert.AreEqual('/no-params',
    TPoseidonRouteRegistry.ToOpenAPIPath('/no-params'));
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonOpenAPITests);

end.
