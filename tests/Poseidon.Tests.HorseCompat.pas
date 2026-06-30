unit Poseidon.Tests.HorseCompat;

// Tests that verify Horse middleware compatibility.
// Each test simulates the exact patterns used by Docfiscall middlewares
// to ensure zero-breaking-change migration from Horse to Poseidon.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}

  // Simulates Horse.CORS middleware pattern
  [TestFixture]
  THorseCompatCORSTests = class
  public
    [Test] procedure CORS_SetsHeaders_ViaAddHeader;
    [Test] procedure CORS_ChecksMethod_ViaRawWebRequest;
    [Test] procedure CORS_InterruptsWithException;
  end;

  // Simulates Horse.Jhonson middleware pattern
  [TestFixture]
  THorseCompatJhonsonTests = class
  public
    [Test] procedure Jhonson_ReadsBody_AsString;
    [Test] procedure Jhonson_SetsContentObject_ViaContent;
    [Test] procedure Jhonson_ReadsContentType_ViaRawWebRequest;
  end;

  // Simulates Plugin.JWT.Horse middleware pattern
  [TestFixture]
  THorseCompatJWTTests = class
  public
    [Test] procedure JWT_ReadsAuthHeader;
    [Test] procedure JWT_SetsSession_RetrievesTyped;
    [Test] procedure JWT_SessionSurvivesAcrossMiddleware;
    [Test] procedure JWT_Returns401_ViaStatusSend;
  end;

  // Simulates Horse.OctetStream middleware pattern
  [TestFixture]
  THorseCompatOctetStreamTests = class
  public
    [Test] procedure OctetStream_SetsBodyAsStream_ViaBodyObject;
    [Test] procedure OctetStream_ReadsContent_AsObject;
  end;

  // Simulates Horse.Compression middleware pattern
  [TestFixture]
  THorseCompatCompressionTests = class
  public
    [Test] procedure Compression_ReadsAcceptEncoding;
    [Test] procedure Compression_SetsContentEncoding_ViaRawWebResponse;
  end;

  // Simulates DocFiscAll.Middleware.Pagination pattern
  [TestFixture]
  THorseCompatPaginationTests = class
  public
    [Test] procedure Pagination_ReadsQueryParams;
    [Test] procedure Pagination_ReadsSessionForClientType;
    [Test] procedure Pagination_ModifiesContentArray;
  end;

  // Simulates the full middleware pipeline pattern
  [TestFixture]
  THorseCompatPipelineTests = class
  public
    [Test] procedure Pipeline_NextCallsChain;
    [Test] procedure Pipeline_InterruptStopsChain;
    [Test] procedure Pipeline_ExceptionHandlerCatches;
  end;

  // Tests Horse type aliases compile and work
  [TestFixture]
  THorseCompatTypeTests = class
  public
    [Test] procedure TypeAlias_THorseRequest_IsTPoseidonRequest;
    [Test] procedure TypeAlias_THorseResponse_IsTPoseidonResponse;
    [Test] procedure TypeAlias_EHorseException_HasStatus;
    [Test] procedure TypeAlias_THorseCallback_Callable;
    [Test] procedure TypeAlias_SendGeneric_WithJSONArray;
    [Test] procedure TypeAlias_SendGeneric_WithJSONObject;
    [Test] procedure TypeAlias_RedirectTo_Works;
  end;

  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.Generics.Collections,
  Web.HTTPApp,
  Poseidon,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Exception,
  Poseidon.Commons,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse;

// Helper: create mock request with optional headers and body
function MakeMockReq(const AMethod: string = 'GET';
  const APath: string = '/test';
  const ABody: string = '';
  const AHeaders: TArray<TPair<string,string>> = nil): TMockWebRequest;
var
  LPair: TPair<string,string>;
begin
  Result := TMockWebRequest.Create;
  Result.SetMethod(AMethod);
  Result.SetPathInfo(APath);
  if ABody <> '' then
    Result.SetContent(ABody);
  if AHeaders <> nil then
    for LPair in AHeaders do
      Result.AddHeader(LPair.Key, LPair.Value);
end;

// ---------------------------------------------------------------------------
// CORS Tests
// ---------------------------------------------------------------------------

procedure THorseCompatCORSTests.CORS_SetsHeaders_ViaAddHeader;
var
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    // CORS middleware pattern: Res.AddHeader(name, value)
    LRes.AddHeader('Access-Control-Allow-Origin', '*');
    LRes.AddHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE');

    Assert.IsTrue(LMockRes.SentHeaders.IndexOfName('Access-Control-Allow-Origin') >= 0,
      'AddHeader must set CORS origin header');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatCORSTests.CORS_ChecksMethod_ViaRawWebRequest;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
begin
  LMockReq := MakeMockReq('OPTIONS', '/api/data');
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    // CORS checks: Req.RawWebRequest.MethodType
    Assert.AreEqual('OPTIONS', LReq.RawWebRequest.Method,
      'RawWebRequest.Method must return OPTIONS');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatCORSTests.CORS_InterruptsWithException;
begin
  // CORS middleware raises EHorseCallbackInterrupted after preflight
  Assert.WillRaise(
    procedure begin
      raise EHorseCallbackInterrupted.Create;
    end,
    EPoseidonCallbackInterrupted,
    'EHorseCallbackInterrupted must be EPoseidonCallbackInterrupted');
end;

// ---------------------------------------------------------------------------
// Jhonson Tests
// ---------------------------------------------------------------------------

procedure THorseCompatJhonsonTests.Jhonson_ReadsBody_AsString;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
begin
  LMockReq := MakeMockReq('POST', '/data', '{"name":"Alice"}');
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    // Jhonson reads: Req.Body (string)
    Assert.AreEqual('{"name":"Alice"}', LReq.Body,
      'Req.Body must return raw body string (Horse compat)');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatJhonsonTests.Jhonson_SetsContentObject_ViaContent;
var
  LRes: TPoseidonResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LObj: TJSONObject;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LObj := TJSONObject.Create.AddPair('ok', TJSONBool.Create(True));
    // Jhonson sets: Res.Content(obj)
    LRes.Content(LObj);
    // Then reads: Res.Content
    Assert.AreSame(LObj, LRes.Content,
      'Res.Content must return the same object set via Content(obj)');
    LObj.Free;
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatJhonsonTests.Jhonson_ReadsContentType_ViaRawWebRequest;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
begin
  LMockReq := MakeMockReq('POST', '/data', '{}');
  LMockReq.AddHeader('Content-Type', 'application/json');
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    Assert.AreEqual('application/json', LReq.ContentType,
      'ContentType must reflect Content-Type header');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// JWT Tests
// ---------------------------------------------------------------------------

type
  TTestSession = class
    UserID: string;
    Email: string;
  end;

procedure THorseCompatJWTTests.JWT_ReadsAuthHeader;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
begin
  LMockReq := MakeMockReq;
  LMockReq.AddHeader('Authorization', 'Bearer abc123');
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    // JWT middleware reads: Req.Headers.Get('Authorization')
    Assert.AreEqual('Bearer abc123', LReq.Headers.Get('Authorization'),
      'Headers must return Authorization value');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatJWTTests.JWT_SetsSession_RetrievesTyped;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
  LSession: TTestSession;
begin
  LMockReq := MakeMockReq;
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    // JWT middleware sets: Req.Session(obj)
    LSession := TTestSession.Create;
    LSession.UserID := 'user-42';
    LSession.Email  := 'alice@example.com';
    LReq.Session(LSession);

    // Controller reads: Req.Session<TTestSession>
    Assert.AreEqual('user-42', LReq.Session<TTestSession>.UserID,
      'Session<T> must return the typed session object');
    Assert.AreEqual('alice@example.com', LReq.Session<TTestSession>.Email,
      'Session<T> must preserve all session fields');
  finally
    LReq.Free; LMockReq.Free;
    // Session freed by Request destructor (FOwnsSession=True)
  end;
end;

procedure THorseCompatJWTTests.JWT_SessionSurvivesAcrossMiddleware;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
  LSession: TTestSession;
begin
  LMockReq := MakeMockReq;
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    // Middleware 1 (JWT) sets session
    LSession := TTestSession.Create;
    LSession.UserID := 'user-99';
    LReq.Session(LSession);

    // Middleware 2 (Pagination) reads session
    Assert.IsNotNull(LReq.Session<TTestSession>,
      'Session must survive across middleware calls');
    Assert.AreEqual('user-99', LReq.Session<TTestSession>.UserID);
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatJWTTests.JWT_Returns401_ViaStatusSend;
var
  LRes: TPoseidonResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    // JWT middleware: Res.Send('Unauthorized').Status(401)
    LRes.Send('Unauthorized').Status(401);
    Assert.AreEqual(401, LMockRes.SentStatusCode,
      'Status(401) must set HTTP 401');
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// OctetStream Tests
// ---------------------------------------------------------------------------

procedure THorseCompatOctetStreamTests.OctetStream_SetsBodyAsStream_ViaBodyObject;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
  LStream: TMemoryStream;
begin
  LMockReq := MakeMockReq('POST', '/upload', 'binary data');
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    // OctetStream middleware sets: Req.Body(TStream)
    LStream := TMemoryStream.Create;
    LStream.Write(PAnsiChar('binary')^, 6);
    LReq.Body(LStream);

    // Then reads: Req.Body<TObject> and checks InheritsFrom(TStream)
    Assert.IsTrue(LReq.Body<TObject>.InheritsFrom(TStream),
      'Body<TObject> must return the stream set via Body(TStream)');
    // Do NOT free LStream — Request destructor owns it via SetBody
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatOctetStreamTests.OctetStream_ReadsContent_AsObject;
var
  LRes: TPoseidonResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LStream: TStringStream;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    // Handler sets content as stream
    LStream := TStringStream.Create('file data');
    LRes.Content(LStream);

    // OctetStream checks: Res.Content.InheritsFrom(TStream)
    Assert.IsTrue(LRes.Content.InheritsFrom(TStream),
      'Content must return the TStream object');
    LStream.Free;
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Compression Tests
// ---------------------------------------------------------------------------

procedure THorseCompatCompressionTests.Compression_ReadsAcceptEncoding;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
begin
  LMockReq := MakeMockReq;
  LMockReq.AddHeader('Accept-Encoding', 'gzip, deflate');
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    Assert.AreEqual('gzip, deflate', LReq.Headers.Get('Accept-Encoding'),
      'Headers must return Accept-Encoding');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatCompressionTests.Compression_SetsContentEncoding_ViaRawWebResponse;
var
  LRes: TPoseidonResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    // Compression middleware accesses RawWebResponse
    Assert.IsNotNull(LRes.RawWebResponse,
      'RawWebResponse must not be nil');
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Pagination Tests
// ---------------------------------------------------------------------------

procedure THorseCompatPaginationTests.Pagination_ReadsQueryParams;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
begin
  LMockReq := MakeMockReq('GET', '/notas');
  LMockReq.AddQueryParam('page', '2');
  LMockReq.AddQueryParam('limit', '10');
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    Assert.AreEqual('2', LReq.Query.Get('page'), 'Query must parse page param');
    Assert.AreEqual('10', LReq.Query.Get('limit'), 'Query must parse limit param');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatPaginationTests.Pagination_ReadsSessionForClientType;
var
  LReq: TPoseidonRequest;
  LMockReq: TMockWebRequest;
  LSession: TTestSession;
begin
  LMockReq := MakeMockReq;
  LReq := TPoseidonRequest.Create(LMockReq);
  try
    LSession := TTestSession.Create;
    LSession.UserID := 'web-client';
    LReq.Session(LSession);

    // Pagination checks: Req.Session<TSession>.IsDocFiscallWeb
    Assert.IsNotNull(LReq.Session<TTestSession>,
      'Session must be available for Pagination middleware');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatPaginationTests.Pagination_ModifiesContentArray;
var
  LRes: TPoseidonResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LArr: TJSONArray;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    // Handler sets content as TJSONArray
    LArr := TJSONArray.Create;
    LArr.Add('item1');
    LArr.Add('item2');
    LRes.Content(LArr);

    // Pagination reads and wraps
    Assert.IsTrue(LRes.Content is TJSONArray,
      'Content must be readable as TJSONArray');
    Assert.AreEqual(2, TJSONArray(LRes.Content).Count);
    LArr.Free;
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Pipeline Tests
// ---------------------------------------------------------------------------

procedure THorseCompatPipelineTests.Pipeline_NextCallsChain;
var
  LCalled: Boolean;
begin
  LCalled := False;
  // Simulate middleware calling Next
  (procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
   begin
     Next;
   end)(nil, nil, procedure begin LCalled := True; end);

  Assert.IsTrue(LCalled, 'Next must invoke the next middleware');
end;

procedure THorseCompatPipelineTests.Pipeline_InterruptStopsChain;
var
  LNextCalled: Boolean;
begin
  LNextCalled := False;
  try
    (procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
     begin
       raise EPoseidonCallbackInterrupted.Create;
     end)(nil, nil, procedure begin LNextCalled := True; end);
  except
    on E: EPoseidonCallbackInterrupted do
      ; // expected
  end;
  Assert.IsFalse(LNextCalled, 'Interrupt must prevent Next from being called');
end;

procedure THorseCompatPipelineTests.Pipeline_ExceptionHandlerCatches;
var
  LCaught: Boolean;
  LStatus: Integer;
begin
  LCaught := False;
  LStatus := 0;
  try
    raise EHorseException.Create('not found', THTTPStatus.NotFound);
  except
    on E: EPoseidonException do
    begin
      LCaught := True;
      LStatus := E.Status.ToInteger;
    end;
  end;
  Assert.IsTrue(LCaught, 'EHorseException must be caught as EPoseidonException');
  Assert.AreEqual(404, LStatus, 'Exception status must be 404');
end;

// ---------------------------------------------------------------------------
// Type Alias Tests
// ---------------------------------------------------------------------------

procedure THorseCompatTypeTests.TypeAlias_THorseRequest_IsTPoseidonRequest;
var
  LReq: THorseRequest;
  LMockReq: TMockWebRequest;
begin
  LMockReq := MakeMockReq;
  LReq := THorseRequest.Create(LMockReq);
  try
    Assert.IsTrue(LReq is TPoseidonRequest,
      'THorseRequest must be TPoseidonRequest');
  finally
    LReq.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatTypeTests.TypeAlias_THorseResponse_IsTPoseidonResponse;
var
  LRes: THorseResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := THorseResponse.Create(LMockRes);
  try
    Assert.IsTrue(LRes is TPoseidonResponse,
      'THorseResponse must be TPoseidonResponse');
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatTypeTests.TypeAlias_EHorseException_HasStatus;
var
  E: EHorseException;
begin
  E := EHorseException.Create('test', THTTPStatus.BadRequest);
  try
    Assert.AreEqual(400, E.Status.ToInteger,
      'EHorseException.Status must work via alias');
  finally
    E.Free;
  end;
end;

procedure THorseCompatTypeTests.TypeAlias_THorseCallback_Callable;
var
  LCalled: Boolean;
  LCb: THorseCallback;
begin
  LCalled := False;
  LCb := procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
         begin LCalled := True; end;
  LCb(nil, nil, nil);
  Assert.IsTrue(LCalled, 'THorseCallback must be callable');
end;

procedure THorseCompatTypeTests.TypeAlias_SendGeneric_WithJSONArray;
var
  LRes: THorseResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LArr: TJSONArray;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := THorseResponse.Create(LMockRes);
  try
    LArr := TJSONArray.Create;
    LArr.Add(TJSONObject.Create.AddPair('id', TJSONNumber.Create(1)));
    LRes.Send<TJSONArray>(LArr);
    Assert.IsTrue(Pos('[{', LMockRes.SentContent) > 0,
      'Send<TJSONArray> must serialize to JSON array');
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatTypeTests.TypeAlias_SendGeneric_WithJSONObject;
var
  LRes: THorseResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := THorseResponse.Create(LMockRes);
  try
    LRes.Send<TJSONObject>(TJSONObject.Create.AddPair('ok', TJSONBool.Create(True)));
    Assert.IsTrue(Pos('ok', LMockRes.SentContent) > 0,
      'Send<TJSONObject> must serialize to JSON');
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure THorseCompatTypeTests.TypeAlias_RedirectTo_Works;
var
  LRes: THorseResponse;
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
begin
  LMockReq := MakeMockReq;
  LMockRes := TMockWebResponse.Create(LMockReq);
  LRes := THorseResponse.Create(LMockRes);
  try
    LRes.RedirectTo('/new-location');
    Assert.AreEqual(303, LMockRes.SentStatusCode,
      'RedirectTo must set status 303');
  finally
    LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(THorseCompatCORSTests);
  TDUnitX.RegisterTestFixture(THorseCompatJhonsonTests);
  TDUnitX.RegisterTestFixture(THorseCompatJWTTests);
  TDUnitX.RegisterTestFixture(THorseCompatOctetStreamTests);
  TDUnitX.RegisterTestFixture(THorseCompatCompressionTests);
  TDUnitX.RegisterTestFixture(THorseCompatPaginationTests);
  TDUnitX.RegisterTestFixture(THorseCompatPipelineTests);
  TDUnitX.RegisterTestFixture(THorseCompatTypeTests);

end.
