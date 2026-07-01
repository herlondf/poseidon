unit Poseidon.Tests.MiddlewareIntegration;

// Integration tests: execute REAL Horse middlewares from Docfiscall
// against Poseidon, verifying actual request/response behavior.
// These are NOT compilation tests — they verify correctness.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}

  [TestFixture]
  TJhonsonIntegrationTests = class
  public
    [Test] procedure POST_JsonBody_ParsedIntoBodyObject;
    [Test] procedure POST_NonJson_BodyNotParsed;
    [Test] procedure GET_NoBody_PassesThrough;
    [Test] procedure Response_JsonContent_SerializedToResponseBody;
    [Test] procedure Response_NonJsonContent_NotTouched;
  end;

  [TestFixture]
  TCORSIntegrationTests = class
  public
    [Test] procedure GET_SetsAllCORSHeaders;
    [Test] procedure OPTIONS_Returns204_RaisesInterrupt;
    [Test] procedure GET_CallsNext;
  end;

  [TestFixture]
  TPortinariResponseIntegrationTests = class
  public
    [Test] procedure GET_WithPagination_WrapsInHasNextItems;
    [Test] procedure GET_WithoutPagination_PassesThrough;
    [Test] procedure GET_HasNext_True_WhenExtraItem;
    [Test] procedure POST_Ignored;
  end;

  [TestFixture]
  TExceptionMiddlewareIntegrationTests = class
  public
    [Test] procedure HandlerException_Returns400WithJSON;
    [Test] procedure CallbackInterrupted_Passthrough;
    [Test] procedure NoException_PassesThrough;
  end;

  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  Web.HTTPApp,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Exception,
  Poseidon.Commons,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse,
  Horse,
  Horse.Jhonson,
  Horse.Cors,
  Horse.Portinari.Response,
  Horse.Exception.Middleware,
  Horse.Exception.Types;

// ---------------------------------------------------------------------------
// Jhonson Tests
// ---------------------------------------------------------------------------

procedure TJhonsonIntegrationTests.POST_JsonBody_ParsedIntoBodyObject;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LParsedBody: TObject;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('POST');
  LMockReq.SetPathInfo('/api/data');
  LMockReq.SetContent('{"name":"Alice","age":30}');
  LMockReq.SetContentType('application/json');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    // Execute Jhonson middleware
    Jhonson(LReq, LRes, procedure begin
      // Inside the handler, Body<TObject> should be the parsed JSON
      LParsedBody := LReq.Body<TObject>;
    end);

    Assert.IsNotNull(LParsedBody, 'Jhonson must parse JSON body into Body<TObject>');
    Assert.IsTrue(LParsedBody is TJSONValue, 'Parsed body must be TJSONValue');
    Assert.AreEqual('Alice',
      TJSONObject(LParsedBody).GetValue<string>('name'),
      'Parsed JSON must contain name=Alice');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TJhonsonIntegrationTests.POST_NonJson_BodyNotParsed;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LBodyWasNull: Boolean;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('POST');
  LMockReq.SetPathInfo('/upload');
  LMockReq.SetContent('plain text data');
  LMockReq.SetContentType('text/plain');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    Jhonson(LReq, LRes, procedure begin
      LBodyWasNull := LReq.Body<TObject> = nil;
    end);

    Assert.IsTrue(LBodyWasNull, 'Jhonson must NOT parse non-JSON body');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TJhonsonIntegrationTests.GET_NoBody_PassesThrough;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LNextCalled: Boolean;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/ping');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LNextCalled := False;
    Jhonson(LReq, LRes, procedure begin LNextCalled := True; end);
    Assert.IsTrue(LNextCalled, 'Jhonson must call Next for GET requests');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TJhonsonIntegrationTests.Response_JsonContent_SerializedToResponseBody;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/data');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    Jhonson(LReq, LRes, procedure begin
      // Handler sets a JSON object as response content
      LRes.Content(TJSONObject.Create.AddPair('ok', TJSONBool.Create(True)));
    end);

    // After Jhonson, response body should be serialized JSON
    Assert.AreEqual('application/json', LMockRes.ContentType,
      'Jhonson must set ContentType to application/json');
    Assert.IsTrue(Pos('"ok"', LMockRes.Content) > 0,
      'Jhonson must serialize Content TJSONObject to response body');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TJhonsonIntegrationTests.Response_NonJsonContent_NotTouched;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/text');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    Jhonson(LReq, LRes, procedure begin
      // Handler sets plain text WITHOUT using Content(TObject)
      LRes.ContentType('text/plain').Send('plain text');
    end);

    // Jhonson should NOT override plain text content with JSON
    Assert.AreEqual('plain text', LMockRes.Content,
      'Jhonson must not override non-JSON response body');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// CORS Tests
// ---------------------------------------------------------------------------

procedure TCORSIntegrationTests.GET_SetsAllCORSHeaders;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/api');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    CORS(LReq, LRes, procedure begin end);

    Assert.IsTrue(LMockRes.CustomHeaders.IndexOfName('Access-Control-Allow-Origin') >= 0,
      'CORS must set Access-Control-Allow-Origin');
    Assert.IsTrue(LMockRes.CustomHeaders.IndexOfName('Access-Control-Allow-Methods') >= 0,
      'CORS must set Access-Control-Allow-Methods');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TCORSIntegrationTests.OPTIONS_Returns204_RaisesInterrupt;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LInterrupted: Boolean;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('OPTIONS');
  LMockReq.SetPathInfo('/api');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LInterrupted := False;
  try
    try
      CORS(LReq, LRes, procedure begin end);
    except
      on E: EPoseidonCallbackInterrupted do
        LInterrupted := True;
    end;

    Assert.IsTrue(LInterrupted, 'CORS must raise interrupt on OPTIONS');
    Assert.AreEqual(204, LMockRes.SentStatusCode, 'CORS OPTIONS must return 204');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TCORSIntegrationTests.GET_CallsNext;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LNextCalled: Boolean;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/api');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LNextCalled := False;
    CORS(LReq, LRes, procedure begin LNextCalled := True; end);
    Assert.IsTrue(LNextCalled, 'CORS must call Next on non-OPTIONS');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Portinari Response Tests
// ---------------------------------------------------------------------------

procedure TPortinariResponseIntegrationTests.GET_WithPagination_WrapsInHasNextItems;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/notas');
  LMockReq.AddQueryParam('page', '1');
  LMockReq.AddQueryParam('pageSize', '2');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    Horse.Portinari.Response.Middleware(LReq, LRes, procedure begin
      // Handler returns 2 items (exactly pageSize — no hasNext)
      var LArr := TJSONArray.Create;
      LArr.Add(TJSONObject.Create.AddPair('id', TJSONNumber.Create(1)));
      LArr.Add(TJSONObject.Create.AddPair('id', TJSONNumber.Create(2)));
      LRes.Content(LArr);
    end);

    // Portinari should wrap in {hasNext, items}
    Assert.IsTrue(Pos('"hasNext"', LMockRes.SentContent) > 0,
      'Portinari must wrap response with hasNext');
    Assert.IsTrue(Pos('"items"', LMockRes.SentContent) > 0,
      'Portinari must wrap response with items');
    Assert.IsTrue(Pos('"hasNext":false', LMockRes.SentContent) > 0,
      'hasNext must be false when items <= pageSize');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPortinariResponseIntegrationTests.GET_WithoutPagination_PassesThrough;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/notas');
  // No page/pageSize params
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    Horse.Portinari.Response.Middleware(LReq, LRes, procedure begin
      var LArr := TJSONArray.Create;
      LArr.Add('item1');
      LRes.Content(LArr);
    end);

    // Without pagination, Portinari should NOT wrap
    Assert.IsFalse(Pos('"hasNext"', LMockRes.SentContent) > 0,
      'Portinari must NOT wrap when no pagination params');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPortinariResponseIntegrationTests.GET_HasNext_True_WhenExtraItem;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/notas');
  LMockReq.AddQueryParam('page', '1');
  LMockReq.AddQueryParam('pageSize', '2');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    Horse.Portinari.Response.Middleware(LReq, LRes, procedure begin
      // Handler returns 3 items (pageSize+1 — hasNext=true)
      var LArr := TJSONArray.Create;
      LArr.Add(TJSONObject.Create.AddPair('id', TJSONNumber.Create(1)));
      LArr.Add(TJSONObject.Create.AddPair('id', TJSONNumber.Create(2)));
      LArr.Add(TJSONObject.Create.AddPair('id', TJSONNumber.Create(3)));
      LRes.Content(LArr);
    end);

    Assert.IsTrue(Pos('"hasNext":true', LMockRes.SentContent) > 0,
      'hasNext must be true when items > pageSize');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TPortinariResponseIntegrationTests.POST_Ignored;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LNextCalled: Boolean;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('POST');
  LMockReq.SetPathInfo('/notas');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LNextCalled := False;
    Horse.Portinari.Response.Middleware(LReq, LRes, procedure begin
      LNextCalled := True;
    end);
    Assert.IsTrue(LNextCalled, 'Portinari must pass through POST requests');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Exception Middleware Tests
// ---------------------------------------------------------------------------

procedure TExceptionMiddlewareIntegrationTests.HandlerException_Returns400WithJSON;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/error');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    HorseException(LReq, LRes, procedure begin
      raise Exception.Create('test error');
    end);

    Assert.IsTrue(LMockRes.SentStatusCode >= 400,
      'Exception middleware must set error status');
    Assert.IsTrue(Pos('messageInfo', LMockRes.SentContent) > 0,
      'Exception middleware must return JSON with messageInfo');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TExceptionMiddlewareIntegrationTests.CallbackInterrupted_Passthrough;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LInterrupted: Boolean;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/cors-preflight');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LInterrupted := False;
  try
    try
      HorseException(LReq, LRes, procedure begin
        raise EPoseidonCallbackInterrupted.Create;
      end);
    except
      on E: EPoseidonCallbackInterrupted do
        LInterrupted := True;
    end;
    Assert.IsTrue(LInterrupted,
      'Exception middleware must re-raise EHorseCallbackInterrupted');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TExceptionMiddlewareIntegrationTests.NoException_PassesThrough;
var
  LMockReq: TMockWebRequest;
  LMockRes: TMockWebResponse;
  LReq: TPoseidonRequest;
  LRes: TPoseidonResponse;
  LNextCalled: Boolean;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetMethod('GET');
  LMockReq.SetPathInfo('/ok');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  try
    LNextCalled := False;
    HorseException(LReq, LRes, procedure begin LNextCalled := True; end);
    Assert.IsTrue(LNextCalled, 'Exception middleware must call Next when no exception');
  finally
    LReq.Free; LRes.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TJhonsonIntegrationTests);
  TDUnitX.RegisterTestFixture(TCORSIntegrationTests);
  TDUnitX.RegisterTestFixture(TPortinariResponseIntegrationTests);
  TDUnitX.RegisterTestFixture(TExceptionMiddlewareIntegrationTests);

end.
