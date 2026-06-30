unit Poseidon.Tests.WebAdapters;

// DUnitX unit tests for Poseidon.Net.WebAdapters.Native.
//
// Coverage:
//   TNativeWebRequest.Reset — pool reuse: QueryFields cache is invalidated and
//     repopulated from the new request's QueryString on every Reset call.
//   TNativeWebResponse.CommitResponse — when ContentType is not set, FOnFlush
//     receives AContentType = '' (not a default value like 'text/plain').

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TNativeWebRequestTests = class
  public
    [Test] procedure Reset_AfterEmptyQS_ReadsNewQueryParams;
    [Test] procedure Reset_AfterNonEmptyQS_StaleParamsNotBleedThrough;
    [Test] procedure Reset_EmptyQS_ClearsPreviousParams;
  end;

  [TestFixture]
  TNativeWebResponseTests = class
  public
    [Test] procedure CommitResponse_NoContentTypeSet_FlushesEmptyString;
    [Test] procedure CommitResponse_ContentTypeSet_FlushesCorrectValue;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.WebAdapters.Native;

function MakeReq(const APath, AQueryString: string): TPoseidonNativeRequest;
begin
  Result.Method      := 'GET';
  Result.Path        := APath;
  Result.QueryString := AQueryString;
  Result.RawBody     := [];
  Result.RemoteAddr  := '127.0.0.1';
  Result.KeepAlive   := False;
  Result.Headers     := [];
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

initialization
  TDUnitX.RegisterTestFixture(TNativeWebRequestTests);
  TDUnitX.RegisterTestFixture(TNativeWebResponseTests);

end.
