unit Poseidon.Tests.ResponseBuilder;

// DUnitX unit tests for Poseidon.Net.ResponseBuilder.BuildHTTPResponse.
//
// Tests verify that the assembled TBytes contain the correct HTTP/1.1
// response structure without needing a running server.
//
// Coverage:
//   Status lines (200, 404, custom)
//   Content-Type header (common pre-encoded values, custom)
//   Content-Length header (0, small, large)
//   Connection header (keep-alive vs close)
//   Extra headers (single, multiple, S-3 CRLF stripped from values)
//   Security headers (A-1: opt-in)
//   Server banner (A-2: configurable / omitted)
//   DefaultErrorBody (non-nil, UTF-8 JSON)

interface

uses
  System.SysUtils,
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TResponseBuilderTests = class
  private
    function ResponseToString(const ABytes: TBytes): string;
    function HasHeader(const AResponse, AName, AValue: string): Boolean;
    function HasStatusLine(const AResponse: string; AExpected: string): Boolean;
  public
    [Test] procedure Status200_ContainsOKStatusLine;
    [Test] procedure Status404_ContainsNotFoundStatusLine;
    [Test] procedure Status201_ContainsCreatedStatusLine;
    [Test] procedure CustomStatus_ContainsUnknownStatusLine;
    [Test] procedure ContentType_JSON_UsesPreencoded;
    [Test] procedure ContentType_TextPlain_UsesPreencoded;
    [Test] procedure ContentType_Custom_UsedVerbatim;
    [Test] procedure ContentType_Empty_HeaderOmitted;
    [Test] procedure KeepAlive_True_ContainsKeepAliveHeader;
    [Test] procedure KeepAlive_False_ContainsCloseHeader;
    [Test] procedure ContentLength_Zero_WrittenCorrectly;
    [Test] procedure ContentLength_Large_WrittenCorrectly;
    [Test] procedure ExtraHeader_Appended;
    [Test] procedure ExtraHeader_CRLFStripped;
    [Test] procedure SecureHeaders_Disabled_NotPresent;
    [Test] procedure SecureHeaders_Enabled_AllPresent;
    [Test] procedure ServerBanner_Empty_HeaderOmitted;
    [Test] procedure ServerBanner_NonEmpty_HeaderPresent;
    [Test] procedure Body_PresentInResponse;
    [Test] procedure Body_Empty_NoBodyBytes;
    [Test] procedure DefaultErrorBody_IsValidJSON;
    [Test] procedure Response_EndsWithDoubleCRLF_BeforeBody;

    // Edge cases — Fase 3
    [Test] procedure Status_204_NoContentStatusLine;
    [Test] procedure Status_301_WithLocationHeader;
    [Test] procedure LargeBody_ContentLengthCorrect;
    [Test] procedure ExtraHeaders_MultipleValues;
    [Test] procedure ContentType_WithCharset_PreservedVerbatim;
    [Test] procedure Status_503_ServiceUnavailable;

    // P-4: BuildHTTPResponsePooled
    [Test] procedure Pooled_ContentMatchesNonPooled;
    [Test] procedure Pooled_ActualLen_EqualsNonPooledLength;
    [Test] procedure Pooled_Release_DoesNotCrash;
  end;
  {$M-}

implementation

uses
  System.Classes,
  System.Generics.Collections,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.ResponseBuilder;

procedure CheckInt(AExpected, AActual: Integer; const AMsg: string = '');
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

function TResponseBuilderTests.ResponseToString(const ABytes: TBytes): string;
begin
  Result := TEncoding.ASCII.GetString(ABytes);
end;

function TResponseBuilderTests.HasHeader(const AResponse, AName, AValue: string): Boolean;
var
  LSearch: string;
begin
  LSearch := AName + ': ' + AValue;
  Result  := Pos(LSearch, AResponse) > 0;
end;

function TResponseBuilderTests.HasStatusLine(const AResponse: string;
  AExpected: string): Boolean;
begin
  Result := Pos(AExpected, AResponse) = 1;
end;

procedure TResponseBuilderTests.Status200_ContainsOKStatusLine;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, [], False, ''));
  Assert.IsTrue(HasStatusLine(LResp, 'HTTP/1.1 200 OK'));
end;

procedure TResponseBuilderTests.Status404_ContainsNotFoundStatusLine;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(404, 'text/plain', [], False, [], False, ''));
  Assert.IsTrue(HasStatusLine(LResp, 'HTTP/1.1 404 Not Found'));
end;

procedure TResponseBuilderTests.Status201_ContainsCreatedStatusLine;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(201, 'application/json', [], False, [], False, ''));
  Assert.IsTrue(HasStatusLine(LResp, 'HTTP/1.1 201 Created'));
end;

procedure TResponseBuilderTests.CustomStatus_ContainsUnknownStatusLine;
var
  LResp: string;
begin
  // Status codes not in the pre-encoded table use "Unknown"
  LResp := ResponseToString(
    BuildHTTPResponse(418, 'text/plain', [], False, [], False, ''));
  Assert.IsTrue(HasStatusLine(LResp, 'HTTP/1.1 418 Unknown'));
end;

procedure TResponseBuilderTests.ContentType_JSON_UsesPreencoded;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'application/json', [], False, [], False, ''));
  Assert.IsTrue(HasHeader(LResp, 'Content-Type', 'application/json'));
end;

procedure TResponseBuilderTests.ContentType_TextPlain_UsesPreencoded;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, [], False, ''));
  Assert.IsTrue(HasHeader(LResp, 'Content-Type', 'text/plain'));
end;

procedure TResponseBuilderTests.ContentType_Custom_UsedVerbatim;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/csv; charset=utf-8', [], False, [], False, ''));
  Assert.IsTrue(HasHeader(LResp, 'Content-Type', 'text/csv; charset=utf-8'));
end;

procedure TResponseBuilderTests.ContentType_Empty_HeaderOmitted;
// When AContentType is empty, no Content-Type header must appear in the response.
// This allows the client to sniff the content type (e.g. browser renders HTML).
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, '', [], False, [], False, ''));
  Assert.IsFalse(Pos('Content-Type:', LResp) > 0,
    'Content-Type header must be absent when AContentType is empty string');
end;

procedure TResponseBuilderTests.KeepAlive_True_ContainsKeepAliveHeader;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], True, [], False, ''));
  Assert.IsTrue(Pos('Connection: keep-alive', LResp) > 0);
end;

procedure TResponseBuilderTests.KeepAlive_False_ContainsCloseHeader;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, [], False, ''));
  Assert.IsTrue(Pos('Connection: close', LResp) > 0);
end;

procedure TResponseBuilderTests.ContentLength_Zero_WrittenCorrectly;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, [], False, ''));
  Assert.IsTrue(HasHeader(LResp, 'Content-Length', '0'));
end;

procedure TResponseBuilderTests.ContentLength_Large_WrittenCorrectly;
var
  LBody: TBytes;
  LResp: string;
begin
  SetLength(LBody, 123456);
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'application/octet-stream', LBody, False, [], False, ''));
  Assert.IsTrue(HasHeader(LResp, 'Content-Length', '123456'));
end;

procedure TResponseBuilderTests.ExtraHeader_Appended;
var
  LExtra: TArray<TPair<string,string>>;
  LResp:  string;
begin
  LExtra := [TPair<string,string>.Create('X-Request-Id', 'abc123')];
  LResp  := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, LExtra, False, ''));
  Assert.IsTrue(HasHeader(LResp, 'X-Request-Id', 'abc123'));
end;

procedure TResponseBuilderTests.ExtraHeader_CRLFStripped;
var
  LExtra: TArray<TPair<string,string>>;
  LResp:  string;
begin
  // S-3: injection attempt in header value must be stripped
  LExtra := [TPair<string,string>.Create('Location',
    'https://example.com'#13#10'X-Evil: injected')];
  LResp  := ResponseToString(
    BuildHTTPResponse(302, 'text/plain', [], False, LExtra, False, ''));
  Assert.IsFalse(Pos('X-Evil', LResp) > 0, 'Injected header must be stripped');
  Assert.IsTrue(Pos('Location:', LResp) > 0, 'Location header must be present');
end;

procedure TResponseBuilderTests.SecureHeaders_Disabled_NotPresent;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/html', [], False, [], False, ''));
  Assert.IsFalse(Pos('X-Content-Type-Options', LResp) > 0);
  Assert.IsFalse(Pos('X-Frame-Options', LResp) > 0);
end;

procedure TResponseBuilderTests.SecureHeaders_Enabled_AllPresent;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/html', [], False, [], True, ''));
  Assert.IsTrue(Pos('X-Content-Type-Options: nosniff', LResp) > 0);
  Assert.IsTrue(Pos('X-Frame-Options: DENY', LResp) > 0);
  Assert.IsTrue(Pos('Referrer-Policy: strict-origin-when-cross-origin', LResp) > 0);
end;

procedure TResponseBuilderTests.ServerBanner_Empty_HeaderOmitted;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, [], False, ''));
  Assert.IsFalse(Pos('Server:', LResp) > 0);
end;

procedure TResponseBuilderTests.ServerBanner_NonEmpty_HeaderPresent;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, [], False, 'Poseidon/2.0'));
  Assert.IsTrue(HasHeader(LResp, 'Server', 'Poseidon/2.0'));
end;

procedure TResponseBuilderTests.Body_PresentInResponse;
var
  LBodyStr: string;
  LBody:    TBytes;
  LFull:    TBytes;
  LResp:    string;
begin
  LBodyStr := '{"ok":true}';
  LBody    := TEncoding.UTF8.GetBytes(LBodyStr);
  LFull    := BuildHTTPResponse(200, 'application/json', LBody, False, [], False, '');
  LResp    := TEncoding.UTF8.GetString(LFull);
  Assert.IsTrue(LResp.EndsWith(LBodyStr));
end;

procedure TResponseBuilderTests.Body_Empty_NoBodyBytes;
var
  LFull: TBytes;
  LResp: string;
begin
  LFull := BuildHTTPResponse(204, 'text/plain', [], False, [], False, '');
  LResp := ResponseToString(LFull);
  // Must end with CRLFCRLF (header terminator + empty body)
  Assert.IsTrue(LResp.EndsWith(#13#10#13#10));
end;

procedure TResponseBuilderTests.DefaultErrorBody_IsValidJSON;
var
  LBody: TBytes;
  LStr:  string;
begin
  LBody := DefaultErrorBody;
  Assert.IsTrue(Length(LBody) > 0);
  LStr := TEncoding.UTF8.GetString(LBody);
  // Must start with '{' and contain "error"
  Assert.IsTrue(LStr.StartsWith('{'));
  Assert.IsTrue(Pos('"error"', LStr) > 0);
end;

procedure TResponseBuilderTests.Response_EndsWithDoubleCRLF_BeforeBody;
var
  LBody:    TBytes;
  LFull:    TBytes;
  LHeaderPart: string;
  LHeaderEnd:  Integer;
begin
  LBody := TEncoding.UTF8.GetBytes('hello');
  LFull := BuildHTTPResponse(200, 'text/plain', LBody, False, [], False, '');
  // Find the CRLFCRLF separator between headers and body
  LHeaderPart := TEncoding.ASCII.GetString(LFull);
  LHeaderEnd  := Pos(#13#10#13#10, LHeaderPart);
  Assert.IsTrue(LHeaderEnd > 0, 'Must have CRLFCRLF between headers and body');
  // Body starts at LHeaderEnd + 4 (the CRLFCRLF is 4 bytes, Pos returns 1-based)
  // Length of body = total - (header section + 4 separator bytes)
  CheckInt(Length(LBody), Length(LFull) - (LHeaderEnd + 3));
end;

// ── Fase 3: Edge cases ──────────────────────────────────────────────────────

procedure TResponseBuilderTests.Status_204_NoContentStatusLine;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(204, '', [], False, [], False, ''));
  Assert.IsTrue(HasStatusLine(LResp, 'HTTP/1.1 204 No Content'));
  Assert.IsTrue(HasHeader(LResp, 'Content-Length', '0'),
    '204 with empty body must have Content-Length: 0');
end;

procedure TResponseBuilderTests.Status_301_WithLocationHeader;
var
  LExtra: TArray<TPair<string,string>>;
  LResp:  string;
begin
  LExtra := [TPair<string,string>.Create('Location', 'https://new.example.com/path')];
  LResp  := ResponseToString(
    BuildHTTPResponse(301, 'text/plain', [], False, LExtra, False, ''));
  Assert.IsTrue(HasStatusLine(LResp, 'HTTP/1.1 301 Moved Permanently'));
  Assert.IsTrue(HasHeader(LResp, 'Location', 'https://new.example.com/path'));
end;

procedure TResponseBuilderTests.LargeBody_ContentLengthCorrect;
var
  LBody: TBytes;
  LResp: string;
begin
  SetLength(LBody, 1048576);  // 1 MB
  FillChar(LBody[0], Length(LBody), Ord('X'));
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'application/octet-stream', LBody, True, [], False, ''));
  Assert.IsTrue(HasHeader(LResp, 'Content-Length', '1048576'),
    'Content-Length must be 1048576 for 1 MB body');
end;

procedure TResponseBuilderTests.ExtraHeaders_MultipleValues;
var
  LExtra: TArray<TPair<string,string>>;
  LResp:  string;
begin
  SetLength(LExtra, 5);
  LExtra[0] := TPair<string,string>.Create('X-A', '1');
  LExtra[1] := TPair<string,string>.Create('X-B', '2');
  LExtra[2] := TPair<string,string>.Create('X-C', '3');
  LExtra[3] := TPair<string,string>.Create('X-D', '4');
  LExtra[4] := TPair<string,string>.Create('X-E', '5');
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/plain', [], False, LExtra, False, ''));
  Assert.IsTrue(HasHeader(LResp, 'X-A', '1'), 'Must contain X-A header');
  Assert.IsTrue(HasHeader(LResp, 'X-E', '5'), 'Must contain X-E header');
end;

procedure TResponseBuilderTests.ContentType_WithCharset_PreservedVerbatim;
var
  LResp: string;
begin
  LResp := ResponseToString(
    BuildHTTPResponse(200, 'text/html; charset=utf-8', [], False, [], False, ''));
  Assert.IsTrue(HasHeader(LResp, 'Content-Type', 'text/html; charset=utf-8'),
    'Custom Content-Type with charset must be preserved verbatim');
end;

procedure TResponseBuilderTests.Status_503_ServiceUnavailable;
var
  LExtra: TArray<TPair<string,string>>;
  LResp:  string;
begin
  LExtra := [TPair<string,string>.Create('Retry-After', '5')];
  LResp  := ResponseToString(
    BuildHTTPResponse(503, 'text/plain',
      TEncoding.ASCII.GetBytes('Service Unavailable'),
      False, LExtra, False, ''));
  Assert.IsTrue(HasStatusLine(LResp, 'HTTP/1.1 503 Service Unavailable'));
  Assert.IsTrue(HasHeader(LResp, 'Retry-After', '5'));
end;

// ── P-4: BuildHTTPResponsePooled ─────────────────────────────────────────────

procedure TResponseBuilderTests.Pooled_ContentMatchesNonPooled;
// P-4: The pool-backed variant must produce byte-identical output to the
// heap-allocated variant for the same inputs.
var
  LBody:      TBytes;
  LNonPooled: TBytes;
  LPooled:    TBytes;
  LActualLen: Integer;
  LPooledStr: string;
  LNonPoolStr: string;
begin
  LBody      := TEncoding.UTF8.GetBytes('hello pooled');
  LNonPooled := BuildHTTPResponse(200, 'text/plain', LBody, True, [], False, 'Test/1.0');
  LPooled    := BuildHTTPResponsePooled(200, 'text/plain', LBody, True, [],
    False, 'Test/1.0', LActualLen);
  try
    SetLength(LPooledStr, LActualLen);
    Move(LPooled[0], LPooledStr[1], LActualLen);
    LNonPoolStr := TEncoding.ASCII.GetString(LNonPooled);
    // Compare as raw strings to catch byte-level differences
    Assert.AreEqual(LNonPoolStr,
      TEncoding.ASCII.GetString(Copy(LPooled, 0, LActualLen)),
      'Pooled response content must be identical to non-pooled response');
  finally
    TBufferPool.Release(LPooled);
  end;
end;

procedure TResponseBuilderTests.Pooled_ActualLen_EqualsNonPooledLength;
// P-4: AActualLen out-parameter must equal the byte count produced by the
// non-pooled variant for the same inputs.
var
  LBody:      TBytes;
  LNonPooled: TBytes;
  LPooled:    TBytes;
  LActualLen: Integer;
begin
  LBody      := TEncoding.UTF8.GetBytes('length check');
  LNonPooled := BuildHTTPResponse(201, 'application/json', LBody, False,
    [], True, '');
  LPooled := BuildHTTPResponsePooled(201, 'application/json', LBody, False,
    [], True, '', LActualLen);
  try
    Assert.AreEqual(Integer(Length(LNonPooled)), LActualLen,
      'AActualLen must equal length of non-pooled response');
    Assert.IsTrue(Integer(Length(LPooled)) >= LActualLen,
      'Pool buffer must be at least as large as AActualLen');
  finally
    TBufferPool.Release(LPooled);
  end;
end;

procedure TResponseBuilderTests.Pooled_Release_DoesNotCrash;
// P-4: TBufferPool.Release on a pooled buffer must not raise or corrupt memory.
var
  LBody:     TBytes;
  LPooled:   TBytes;
  LActualLen: Integer;
begin
  LBody   := TEncoding.UTF8.GetBytes('release test');
  LPooled := BuildHTTPResponsePooled(200, 'text/plain', LBody, True, [],
    False, '', LActualLen);
  // If Release crashes, the unhandled exception will fail this test automatically.
  TBufferPool.Release(LPooled);
  Assert.IsTrue(True, 'TBufferPool.Release on a pooled buffer must not raise');
end;

initialization
  TDUnitX.RegisterTestFixture(TResponseBuilderTests);

end.
