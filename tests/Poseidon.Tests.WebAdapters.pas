unit Poseidon.Tests.WebAdapters;

// DUnitX unit tests for Poseidon.Net.WebAdapters.Native.
//
// Coverage:
//   TNativeWebRequest.Reset — pool reuse cache invalidation (QueryFields,
//     CookieFields, MethodType).
//   TNativeWebRequest.GetStringVariable — all supported SV indices.
//   TNativeWebRequest.GetFieldByName — ALL_RAW ISAPI convention.
//   TNativeWebRequest.ReadClient / ReadString — body reading.
//   TNativeWebResponse.CommitResponse — ContentType, ContentStream, headers.
//   TNativeWebResponse.Reset — state isolation.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TNativeWebRequestTests = class
  public
    // --- Pool reuse (Reset) ---
    [Test] procedure Reset_AfterEmptyQS_ReadsNewQueryParams;
    [Test] procedure Reset_AfterNonEmptyQS_StaleParamsNotBleedThrough;
    [Test] procedure Reset_EmptyQS_ClearsPreviousParams;
    [Test] procedure Reset_CookieFields_NotBleedThrough;
    [Test] procedure Reset_MethodType_UpdatedCorrectly;
    // --- GetStringVariable ---
    [Test] procedure GetStringVariable_Method_ReturnsCorrect;
    [Test] procedure GetStringVariable_PathWithQS_ReturnsFullURI;
    [Test] procedure GetStringVariable_QueryString_ReturnsOnly;
    [Test] procedure GetStringVariable_PathInfo_ReturnsPathOnly;
    [Test] procedure GetStringVariable_Host_ReturnsHeader;
    [Test] procedure GetStringVariable_ContentType_ReturnsHeader;
    [Test] procedure GetStringVariable_RemoteAddr_ReturnsIP;
    [Test] procedure GetStringVariable_Cookie_ReturnsHeader;
    [Test] procedure GetStringVariable_Authorization_ReturnsHeader;
    [Test] procedure GetStringVariable_UnknownIndex_ReturnsEmpty;
    // --- GetFieldByName ---
    [Test] procedure GetFieldByName_AllRaw_ReturnsAllHeaders;
    [Test] procedure GetFieldByName_SpecificHeader_ReturnsValue;
    // --- ReadClient / ReadString ---
    [Test] procedure ReadClient_ReturnsBodyBytes;
    [Test] procedure ReadString_ReturnsUTF8Body;
    [Test] procedure ReadClient_EmptyBody_ReturnsZero;
  end;

  [TestFixture]
  TNativeWebResponseTests = class
  public
    [Test] procedure CommitResponse_NoContentTypeSet_FlushesEmptyString;
    [Test] procedure CommitResponse_ContentTypeSet_FlushesCorrectValue;
    [Test] procedure CommitResponse_WithContentStream_FlushesStreamData;
    [Test] procedure CommitResponse_WithCustomHeaders_FlushesAll;
    [Test] procedure Reset_ClearsAllState;
    [Test] procedure CommitResponse_CalledOnce_FlushesOnce;
    [Test] procedure SendRedirect_FlushesLocationHeader;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.WebAdapters.Native;

function MakeReq(const APath, AQueryString: string): TPoseidonNativeRequest; overload;
begin
  Result.Method      := 'GET';
  Result.Path        := APath;
  Result.QueryString := AQueryString;
  Result.RawBody     := [];
  Result.RemoteAddr  := '127.0.0.1';
  Result.KeepAlive   := False;
  Result.Headers     := [];
end;

function MakeReq(const AMethod, APath, AQueryString: string;
  const AHeaders: TArray<TPair<string,string>>;
  const ABody: TBytes): TPoseidonNativeRequest; overload;
begin
  Result.Method      := AMethod;
  Result.Path        := APath;
  Result.QueryString := AQueryString;
  Result.RawBody     := ABody;
  Result.RemoteAddr  := '10.0.0.42:54321';
  Result.KeepAlive   := True;
  Result.Headers     := AHeaders;
end;

// ---------------------------------------------------------------------------
// TNativeWebRequestTests
// ---------------------------------------------------------------------------

procedure TNativeWebRequestTests.Reset_AfterEmptyQS_ReadsNewQueryParams;
// Pool reuse scenario: first request has no query string (e.g. a warm-up ping),
// second request carries query params. After Reset, QueryFields must contain the
// new params — not the stale empty set from the warm-up.
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/ping', ''));
  try
    // Force lazy init of FQueryFields with empty query string
    Assert.AreEqual('', LWebReq.QueryFields.Values['situacao'],
      'QueryFields must be empty for the warm-up request');

    // Simulate pool reuse: reset with a request that has query params
    LWebReq.Reset(MakeReq('/nfce', 'situacao=snEmAberto&page=1'));

    Assert.AreEqual('snEmAberto', LWebReq.QueryFields.Values['situacao'],
      'situacao must be populated after Reset with new QueryString');
    Assert.AreEqual('1', LWebReq.QueryFields.Values['page'],
      'page must be populated after Reset with new QueryString');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.Reset_AfterNonEmptyQS_StaleParamsNotBleedThrough;
// Pool reuse scenario: first request has params A, second request has params B.
// After Reset, only B must be visible — A must not bleed through.
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/search', 'q=hello&page=1'));
  try
    // Populate FQueryFields with first request's params
    Assert.AreEqual('hello', LWebReq.QueryFields.Values['q']);
    Assert.AreEqual('1',     LWebReq.QueryFields.Values['page']);

    // Pool reuse: reset with a different query string
    LWebReq.Reset(MakeReq('/search', 'q=world&size=20'));

    Assert.AreEqual('world', LWebReq.QueryFields.Values['q'],
      'q must reflect the new request value after Reset');
    Assert.AreEqual('20',    LWebReq.QueryFields.Values['size'],
      'size from new request must be present after Reset');
    Assert.AreEqual('',      LWebReq.QueryFields.Values['page'],
      'page from previous request must not bleed through after Reset');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.Reset_EmptyQS_ClearsPreviousParams;
// Pool reuse scenario: after a request with query params, Reset with an empty
// query string must clear all previous param values.
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('/empresa/123/nfce',
      'dataEmissaoFim=2025-02-26&dataEmissaoInicio=2025-02-20'));
  try
    // Populate FQueryFields
    Assert.AreEqual('2025-02-26',
      LWebReq.QueryFields.Values['dataEmissaoFim']);

    // Pool reuse: reset with no query string
    LWebReq.Reset(MakeReq('/ping', ''));

    Assert.AreEqual('', LWebReq.QueryFields.Values['dataEmissaoFim'],
      'dataEmissaoFim must be absent after Reset with empty QueryString');
    Assert.AreEqual('', LWebReq.QueryFields.Values['dataEmissaoInicio'],
      'dataEmissaoInicio must be absent after Reset with empty QueryString');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.Reset_CookieFields_NotBleedThrough;
// Pool reuse: first request has Cookie header, second does not.
// CookieFields must NOT carry stale values from the first request.
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('GET', '/api', '', [
      TPair<string,string>.Create('Cookie', 'session=abc123; theme=dark')
    ], []));
  try
    // Force lazy init of FCookieFields
    Assert.AreEqual('abc123', LWebReq.CookieFields.Values['session'],
      'session cookie must be present on first request');

    // Pool reuse: new request without cookies
    LWebReq.Reset(MakeReq('/ping', ''));

    Assert.AreEqual('', LWebReq.CookieFields.Values['session'],
      'session cookie must not bleed through after Reset');
    Assert.AreEqual('', LWebReq.CookieFields.Values['theme'],
      'theme cookie must not bleed through after Reset');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.Reset_MethodType_UpdatedCorrectly;
// Pool reuse: GET request reused for POST must reflect POST in MethodType.
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/api', ''));
  try
    Assert.AreEqual('GET', LWebReq.Method, 'Initial method must be GET');

    LWebReq.Reset(MakeReq('POST', '/api/data', '',
      [TPair<string,string>.Create('Content-Type', 'application/json')],
      TEncoding.UTF8.GetBytes('{"x":1}')));

    Assert.AreEqual('POST', LWebReq.Method, 'Method must be POST after Reset');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_Method_ReturnsCorrect;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('DELETE', '/item/42', '', [], []));
  try
    // SV index 0 = Method
    Assert.AreEqual('DELETE', LWebReq.MethodType.ToString);
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_PathWithQS_ReturnsFullURI;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/search', 'q=hello'));
  try
    // SV index 2 = URL (path + query string)
    Assert.AreEqual('/search?q=hello', LWebReq.URL,
      'URL must include path and query string');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_QueryString_ReturnsOnly;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/api', 'key=val&n=1'));
  try
    // SV index 3 = Query
    Assert.AreEqual('key=val&n=1', LWebReq.Query,
      'Query must return only the query string');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_PathInfo_ReturnsPathOnly;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/empresa/123/nfce', 'page=1'));
  try
    // SV index 4/5 = PathInfo
    Assert.AreEqual('/empresa/123/nfce', LWebReq.PathInfo,
      'PathInfo must return path without query string');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_Host_ReturnsHeader;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('GET', '/api', '', [
      TPair<string,string>.Create('Host', 'app.docfiscall.com.br')
    ], []));
  try
    Assert.AreEqual('app.docfiscall.com.br', LWebReq.Host,
      'Host must come from Host header');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_ContentType_ReturnsHeader;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('POST', '/data', '', [
      TPair<string,string>.Create('Content-Type', 'application/json; charset=utf-8')
    ], TEncoding.UTF8.GetBytes('{}')));
  try
    Assert.AreEqual('application/json; charset=utf-8', LWebReq.ContentType,
      'ContentType must match Content-Type header');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_RemoteAddr_ReturnsIP;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('GET', '/', '', [], []));
  try
    // SV index 21/22 = RemoteAddr
    Assert.AreEqual('10.0.0.42:54321', LWebReq.RemoteAddr,
      'RemoteAddr must return client IP:port');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_Cookie_ReturnsHeader;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('GET', '/', '', [
      TPair<string,string>.Create('Cookie', 'sid=xyz; lang=pt')
    ], []));
  try
    // SV index 27 = Cookie
    Assert.AreEqual('sid=xyz; lang=pt', LWebReq.Cookie,
      'Cookie must return Cookie header value');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_Authorization_ReturnsHeader;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('GET', '/secure', '', [
      TPair<string,string>.Create('Authorization', 'Bearer tok123')
    ], []));
  try
    // SV index 28 = Authorization
    Assert.AreEqual('Bearer tok123', LWebReq.Authorization,
      'Authorization must return Authorization header value');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetStringVariable_UnknownIndex_ReturnsEmpty;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/', ''));
  try
    // SV index 99 = unknown
    Assert.AreEqual('', LWebReq.GetStringVariable(99),
      'Unknown SV index must return empty string');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetFieldByName_AllRaw_ReturnsAllHeaders;
var
  LWebReq: TNativeWebRequest;
  LRaw: string;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('GET', '/', '', [
      TPair<string,string>.Create('Host', 'localhost'),
      TPair<string,string>.Create('Accept', '*/*'),
      TPair<string,string>.Create('X-Custom', 'value')
    ], []));
  try
    LRaw := LWebReq.GetFieldByName('ALL_RAW');
    Assert.IsTrue(Pos('Host: localhost', LRaw) > 0, 'ALL_RAW must contain Host header');
    Assert.IsTrue(Pos('Accept: */*', LRaw) > 0, 'ALL_RAW must contain Accept header');
    Assert.IsTrue(Pos('X-Custom: value', LRaw) > 0, 'ALL_RAW must contain X-Custom header');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.GetFieldByName_SpecificHeader_ReturnsValue;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('GET', '/', '', [
      TPair<string,string>.Create('X-Request-ID', '12345')
    ], []));
  try
    Assert.AreEqual('12345', LWebReq.GetFieldByName('X-Request-ID'),
      'GetFieldByName must return the matching header value');
    Assert.AreEqual('', LWebReq.GetFieldByName('X-Missing'),
      'GetFieldByName for absent header must return empty string');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.ReadClient_ReturnsBodyBytes;
var
  LWebReq: TNativeWebRequest;
  LBuf: array[0..255] of Byte;
  LRead: Integer;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('POST', '/data', '', [],
      TEncoding.UTF8.GetBytes('Hello World')));
  try
    LRead := LWebReq.ReadClient(LBuf, SizeOf(LBuf));
    Assert.AreEqual(11, LRead, 'ReadClient must return number of bytes read');
    Assert.AreEqual('Hello World',
      TEncoding.UTF8.GetString(TBytes(@LBuf), 0, LRead),
      'ReadClient must copy body bytes into buffer');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.ReadString_ReturnsUTF8Body;
var
  LWebReq: TNativeWebRequest;
begin
  LWebReq := TNativeWebRequest.Create(
    MakeReq('POST', '/data', '', [],
      TEncoding.UTF8.GetBytes('Texto UTF-8')));
  try
    Assert.AreEqual('Texto UTF-8', LWebReq.ReadString(100),
      'ReadString must return UTF-8 decoded body');
  finally
    LWebReq.Free;
  end;
end;

procedure TNativeWebRequestTests.ReadClient_EmptyBody_ReturnsZero;
var
  LWebReq: TNativeWebRequest;
  LBuf: array[0..31] of Byte;
begin
  LWebReq := TNativeWebRequest.Create(MakeReq('/', ''));
  try
    Assert.AreEqual(0, LWebReq.ReadClient(LBuf, SizeOf(LBuf)),
      'ReadClient with empty body must return 0');
  finally
    LWebReq.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TNativeWebResponseTests
// ---------------------------------------------------------------------------

procedure TNativeWebResponseTests.CommitResponse_NoContentTypeSet_FlushesEmptyString;
// When ContentType is never assigned on the response, CommitResponse must invoke
// FOnFlush with AContentType = '' so that no Content-Type header is emitted.
// This lets the browser/client sniff the actual type (e.g. renders Swagger HTML).
var
  LWebReq:    TNativeWebRequest;
  LWebResp:   TNativeWebResponse;
  LFlushedCT: string;
  LFlushed:   Boolean;
begin
  LFlushedCT := 'SENTINEL';
  LFlushed   := False;
  LWebReq    := TNativeWebRequest.Create(MakeReq('/swagger/doc/html', ''));
  LWebResp   := TNativeWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
              const ABody: TBytes;
              const AExtra: TArray<TPair<string,string>>)
    begin
      LFlushedCT := AContentType;
      LFlushed   := True;
    end);
  try
    LWebResp.Content    := '<html></html>';
    LWebResp.StatusCode := 200;
    // ContentType intentionally NOT set

    LWebResp.CommitResponse;

    Assert.IsTrue(LFlushed,
      'FOnFlush must be called by CommitResponse');
    Assert.AreEqual('', LFlushedCT,
      'AContentType must be empty string when ContentType was not set');
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

procedure TNativeWebResponseTests.CommitResponse_ContentTypeSet_FlushesCorrectValue;
// When ContentType is explicitly assigned, CommitResponse must pass it to FOnFlush.
var
  LWebReq:    TNativeWebRequest;
  LWebResp:   TNativeWebResponse;
  LFlushedCT: string;
begin
  LFlushedCT := '';
  LWebReq    := TNativeWebRequest.Create(MakeReq('/data', ''));
  LWebResp   := TNativeWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
              const ABody: TBytes;
              const AExtra: TArray<TPair<string,string>>)
    begin
      LFlushedCT := AContentType;
    end);
  try
    LWebResp.ContentType := 'application/json';
    LWebResp.Content     := '{"ok":true}';
    LWebResp.StatusCode  := 200;

    LWebResp.CommitResponse;

    Assert.AreEqual('application/json', LFlushedCT,
      'AContentType must match the explicitly assigned ContentType');
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

procedure TNativeWebResponseTests.CommitResponse_WithContentStream_FlushesStreamData;
// When ContentStream has data and FContent is empty, CommitResponse must
// read from the stream.
var
  LWebReq:     TNativeWebRequest;
  LWebResp:    TNativeWebResponse;
  LFlushedBody: TBytes;
  LStream:     TStringStream;
begin
  LFlushedBody := nil;
  LWebReq  := TNativeWebRequest.Create(MakeReq('/data', ''));
  LWebResp := TNativeWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
              const ABody: TBytes;
              const AExtra: TArray<TPair<string,string>>)
    begin
      LFlushedBody := ABody;
    end);
  try
    LStream := TStringStream.Create('stream-content', TEncoding.UTF8);
    LWebResp.ContentStream := LStream;
    LWebResp.StatusCode    := 200;

    LWebResp.CommitResponse;

    Assert.AreEqual('stream-content',
      TEncoding.UTF8.GetString(LFlushedBody),
      'Body must come from ContentStream when Content is empty');
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

procedure TNativeWebResponseTests.CommitResponse_WithCustomHeaders_FlushesAll;
var
  LWebReq:       TNativeWebRequest;
  LWebResp:      TNativeWebResponse;
  LFlushedExtra: TArray<TPair<string,string>>;
  LFlushedCT:    string;
begin
  LFlushedExtra := nil;
  LFlushedCT    := '';
  LWebReq  := TNativeWebRequest.Create(MakeReq('/api', ''));
  LWebResp := TNativeWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
              const ABody: TBytes;
              const AExtra: TArray<TPair<string,string>>)
    begin
      LFlushedCT    := AContentType;
      LFlushedExtra := AExtra;
    end);
  try
    LWebResp.ContentType := 'application/json';
    LWebResp.SetCustomHeader('X-Request-ID', '999');
    LWebResp.SetCustomHeader('X-Powered-By', 'Poseidon');
    LWebResp.Content    := '{}';
    LWebResp.StatusCode := 200;

    LWebResp.CommitResponse;

    Assert.AreEqual('application/json', LFlushedCT,
      'ContentType must be flushed correctly');
    Assert.AreEqual(2, Length(LFlushedExtra),
      'Must flush 2 extra headers (excluding Content-Type)');
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

procedure TNativeWebResponseTests.Reset_ClearsAllState;
var
  LWebReq:  TNativeWebRequest;
  LWebResp: TNativeWebResponse;
  LFlushedStatus: Integer;
  LFlushedBody: TBytes;
begin
  LFlushedStatus := 0;
  LFlushedBody   := nil;
  LWebReq  := TNativeWebRequest.Create(MakeReq('/api', ''));
  LWebResp := TNativeWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
              const ABody: TBytes;
              const AExtra: TArray<TPair<string,string>>)
    begin
      LFlushedStatus := AStatus;
      LFlushedBody   := ABody;
    end);
  try
    // Set state on first use
    LWebResp.StatusCode  := 404;
    LWebResp.Content     := 'not found';
    LWebResp.ContentType := 'text/plain';

    // Reset for pool reuse
    LWebResp.Reset(
      procedure(AStatus: Integer; const AContentType: string;
                const ABody: TBytes;
                const AExtra: TArray<TPair<string,string>>)
      begin
        LFlushedStatus := AStatus;
        LFlushedBody   := ABody;
      end);

    Assert.AreEqual(200, LWebResp.StatusCode,
      'StatusCode must be 200 after Reset');
    Assert.AreEqual('', LWebResp.Content,
      'Content must be empty after Reset');

    LWebResp.Content := 'ok';
    LWebResp.CommitResponse;

    Assert.AreEqual(200, LFlushedStatus,
      'Flushed status must be 200 (reset default)');
    Assert.AreEqual('ok', TEncoding.UTF8.GetString(LFlushedBody),
      'Flushed body must be from new Content, not stale');
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

procedure TNativeWebResponseTests.CommitResponse_CalledOnce_FlushesOnce;
var
  LWebReq:    TNativeWebRequest;
  LWebResp:   TNativeWebResponse;
  LCallCount: Integer;
begin
  LCallCount := 0;
  LWebReq  := TNativeWebRequest.Create(MakeReq('/api', ''));
  LWebResp := TNativeWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
              const ABody: TBytes;
              const AExtra: TArray<TPair<string,string>>)
    begin
      Inc(LCallCount);
    end);
  try
    LWebResp.Content    := 'data';
    LWebResp.StatusCode := 200;
    LWebResp.CommitResponse;

    Assert.AreEqual(1, LCallCount,
      'FOnFlush must be called exactly once per CommitResponse');
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

procedure TNativeWebResponseTests.SendRedirect_FlushesLocationHeader;
var
  LWebReq:       TNativeWebRequest;
  LWebResp:      TNativeWebResponse;
  LFlushedStatus: Integer;
  LFlushedExtra: TArray<TPair<string,string>>;
begin
  LFlushedStatus := 0;
  LFlushedExtra  := nil;
  LWebReq  := TNativeWebRequest.Create(MakeReq('/old', ''));
  LWebResp := TNativeWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
              const ABody: TBytes;
              const AExtra: TArray<TPair<string,string>>)
    begin
      LFlushedStatus := AStatus;
      LFlushedExtra  := AExtra;
    end);
  try
    LWebResp.SendRedirect('/new-location');

    Assert.AreEqual(303, LFlushedStatus,
      'SendRedirect must flush status 303');
    Assert.AreEqual(1, Length(LFlushedExtra),
      'SendRedirect must flush exactly one extra header');
    Assert.AreEqual('Location', LFlushedExtra[0].Key,
      'Extra header must be Location');
    Assert.AreEqual('/new-location', LFlushedExtra[0].Value,
      'Location must match the redirect URI');
  finally
    LWebResp.Free;
    LWebReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TNativeWebRequestTests);
  TDUnitX.RegisterTestFixture(TNativeWebResponseTests);

end.
