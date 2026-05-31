unit Poseidon.Tests.HTTP1Parser;

// DUnitX unit tests for Poseidon.Net.HTTP1.Parser.
//
// All tests operate on raw TBytes buffers — no network, no server.
//
// Coverage:
//   ParseHTTP1Request — complete request, incomplete, bad request, chunked body,
//                       query string, HTTP/1.0 vs 1.1, custom headers,
//                       request-smuggling rejection (S-4), header max size.
//   DecodeHTTP1Chunked — single chunk, multiple chunks, last chunk,
//                        incomplete, malformed hex, oversized chunk.

interface

uses
  System.SysUtils,
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  THTTP1ParseRequestTests = class
  private
    function MakeReq(const AText: string): TBytes;
  public
    [Test] procedure Get_Root_ParsesCorrectly;
    [Test] procedure Post_WithJsonBody_ParsesBodyAndHeaders;
    [Test] procedure Get_WithQueryString_ParsesQueryString;
    [Test] procedure HTTP10_KeepAliveIsFalse;
    [Test] procedure HTTP11_KeepAliveIsTrue;
    [Test] procedure ConnectionClose_OverridesHTTP11KeepAlive;
    [Test] procedure ConnectionKeepAlive_SetsKeepAlive;
    [Test] procedure IncompleteHeaders_ReturnsFalseNotBad;
    [Test] procedure IncompleteBody_ReturnsFalseNotBad;
    [Test] procedure MalformedRequestLine_ReturnsBadRequest;
    [Test] procedure HeaderMaxSizeExceeded_ReturnsBadRequest;
    [Test] procedure MultipleHeaders_AllParsed;
    [Test] procedure ContentLength_BodyConsumed;
    [Test] procedure Smuggling_CLAndChunked_ReturnsBadRequest;
    [Test] procedure AccumBufShifted_AfterParse;
    [Test] procedure PipelinedRequests_OnlyFirstConsumed;
  end;

  [TestFixture]
  TDecodeHTTP1ChunkedTests = class
  public
    [Test] procedure SingleChunk_DecodesCorrectly;
    [Test] procedure MultipleChunks_Concatenated;
    [Test] procedure LastChunkZero_SignalsEnd;
    [Test] procedure Incomplete_ReturnsFalseNotMalformed;
    [Test] procedure MalformedHex_ReturnsMalformed;
    [Test] procedure ChunkSizeLineTooLong_ReturnsMalformed;
    [Test] procedure OversizedChunk_ReturnsMalformed;
    [Test] procedure ChunkWithExtension_ExtensionIgnored;
  end;
  {$M-}

implementation

uses
  System.Classes,
  System.Generics.Collections,
  Poseidon.Net.HTTP1.Parser;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

procedure CheckInt(AExpected, AActual: Integer; const AMsg: string = '');
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

function THTTP1ParseRequestTests.MakeReq(const AText: string): TBytes;
begin
  Result := TEncoding.ASCII.GetBytes(AText);
end;

// ---------------------------------------------------------------------------
// ParseHTTP1Request tests
// ---------------------------------------------------------------------------

procedure THTTP1ParseRequestTests.Get_Root_ParsesCorrectly;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
  LResult:   Boolean;
begin
  LBuf    := MakeReq('GET / HTTP/1.1'#13#10'Host: localhost'#13#10#13#10);
  LResult := ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad);

  Assert.IsTrue(LResult);
  Assert.IsFalse(LBad);
  Assert.AreEqual('GET',  LMethod);
  Assert.AreEqual('/',    LPath);
  Assert.AreEqual('',     LQS);
  Assert.IsTrue(LKeep);
  CheckInt(0, Length(LBody));
  CheckInt(Length(LBuf), LConsumed);
end;

procedure THTTP1ParseRequestTests.Post_WithJsonBody_ParsesBodyAndHeaders;
const
  LBodyStr = '{"name":"Alice"}';
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
  LRaw:      string;
begin
  LRaw := 'POST /users HTTP/1.1'#13#10 +
    'Content-Type: application/json'#13#10 +
    'Content-Length: ' + IntToStr(Length(LBodyStr)) + #13#10 +
    #13#10 + LBodyStr;
  LBuf := MakeReq(LRaw);

  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));

  Assert.AreEqual('POST',  LMethod);
  Assert.AreEqual('/users', LPath);
  Assert.AreEqual(LBodyStr, TEncoding.UTF8.GetString(LBody));
end;

procedure THTTP1ParseRequestTests.Get_WithQueryString_ParsesQueryString;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  LBuf := MakeReq('GET /search?q=hello&page=2 HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.AreEqual('/search', LPath);
  Assert.AreEqual('q=hello&page=2', LQS);
end;

procedure THTTP1ParseRequestTests.HTTP10_KeepAliveIsFalse;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  LBuf := MakeReq('GET / HTTP/1.0'#13#10'Host: x'#13#10#13#10);
  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsFalse(LKeep);
end;

procedure THTTP1ParseRequestTests.HTTP11_KeepAliveIsTrue;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  LBuf := MakeReq('GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsTrue(LKeep);
end;

procedure THTTP1ParseRequestTests.ConnectionClose_OverridesHTTP11KeepAlive;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  LBuf := MakeReq('GET / HTTP/1.1'#13#10'Connection: close'#13#10'Host: x'#13#10#13#10);
  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsFalse(LKeep);
end;

procedure THTTP1ParseRequestTests.ConnectionKeepAlive_SetsKeepAlive;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  LBuf := MakeReq('GET / HTTP/1.0'#13#10'Connection: keep-alive'#13#10'Host: x'#13#10#13#10);
  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsTrue(LKeep);
end;

procedure THTTP1ParseRequestTests.IncompleteHeaders_ReturnsFalseNotBad;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  // Headers not yet terminated — wait for more data
  LBuf := MakeReq('GET / HTTP/1.1'#13#10'Host: x'#13#10);
  Assert.IsFalse(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsFalse(LBad);
end;

procedure THTTP1ParseRequestTests.IncompleteBody_ReturnsFalseNotBad;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  // Content-Length says 10 bytes but only 3 present
  LBuf := MakeReq('POST / HTTP/1.1'#13#10'Content-Length: 10'#13#10#13#10'abc');
  Assert.IsFalse(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsFalse(LBad);
end;

procedure THTTP1ParseRequestTests.MalformedRequestLine_ReturnsBadRequest;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  // No space in request line → bad request
  LBuf := MakeReq('GETNOCRLF'#13#10#13#10);
  Assert.IsFalse(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsTrue(LBad);
end;

procedure THTTP1ParseRequestTests.HeaderMaxSizeExceeded_ReturnsBadRequest;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
  LHdrBlock: string;
  I:         Integer;
begin
  // Build a very large header block (2 KB) but allow only 512 bytes
  LHdrBlock := 'GET / HTTP/1.1'#13#10;
  for I := 1 to 20 do
    LHdrBlock := LHdrBlock + 'X-Padding-Header-' + IntToStr(I) + ': ' +
      StringOfChar('a', 80) + #13#10;
  LHdrBlock := LHdrBlock + #13#10;  // Note: no CRLFCRLF within 512 bytes
  LBuf := TEncoding.ASCII.GetBytes(LHdrBlock);

  Assert.IsFalse(ParseHTTP1Request(LBuf, Length(LBuf),
    512, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.IsTrue(LBad);
end;

procedure THTTP1ParseRequestTests.MultipleHeaders_AllParsed;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
  LFound:    Boolean;
  I:         Integer;
begin
  LBuf := MakeReq(
    'GET /ping HTTP/1.1'#13#10 +
    'Host: localhost'#13#10 +
    'Accept: application/json'#13#10 +
    'X-Custom: myvalue'#13#10 +
    #13#10);

  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));

  CheckInt(3, Length(LHeaders));
  LFound := False;
  for I := 0 to High(LHeaders) do
    if (LHeaders[I].Key = 'X-Custom') and (LHeaders[I].Value = 'myvalue') then
      LFound := True;
  Assert.IsTrue(LFound, 'X-Custom header not found');
end;

procedure THTTP1ParseRequestTests.ContentLength_BodyConsumed;
const
  LBodyText = 'hello world';
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  LBuf := MakeReq(
    'POST /echo HTTP/1.1'#13#10 +
    'Content-Length: ' + IntToStr(Length(LBodyText)) + #13#10 +
    #13#10 + LBodyText);

  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.AreEqual(LBodyText, TEncoding.ASCII.GetString(LBody));
end;

procedure THTTP1ParseRequestTests.Smuggling_CLAndChunked_ReturnsBadRequest;
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
begin
  // RFC 7230 §3.3.3: both CL and chunked TE → reject
  LBuf := MakeReq(
    'POST / HTTP/1.1'#13#10 +
    'Content-Length: 5'#13#10 +
    'Transfer-Encoding: chunked'#13#10 +
    #13#10 +
    '5'#13#10'hello'#13#10'0'#13#10#13#10);

  ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad);
  Assert.IsTrue(LBad);
end;

procedure THTTP1ParseRequestTests.AccumBufShifted_AfterParse;
// After consuming one complete request, LConsumed should equal the
// exact byte count of that request so the caller can shift the buffer.
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
  LReq:      string;
begin
  LReq := 'GET /ping HTTP/1.1'#13#10'Host: x'#13#10#13#10;
  LBuf := MakeReq(LReq);
  ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad);
  CheckInt(Length(LBuf), LConsumed);
end;

procedure THTTP1ParseRequestTests.PipelinedRequests_OnlyFirstConsumed;
// Two back-to-back requests in the buffer — parser must only parse one.
var
  LBuf:      TBytes;
  LMethod, LPath, LQS: string;
  LHeaders:  TArray<TPair<string,string>>;
  LBody:     TBytes;
  LKeep:     Boolean;
  LConsumed: Integer;
  LBad:      Boolean;
  LReq1, LReq2, LBoth: string;
begin
  LReq1  := 'GET /first HTTP/1.1'#13#10'Host: x'#13#10#13#10;
  LReq2  := 'GET /second HTTP/1.1'#13#10'Host: x'#13#10#13#10;
  LBoth  := LReq1 + LReq2;
  LBuf   := MakeReq(LBoth);

  Assert.IsTrue(ParseHTTP1Request(LBuf, Length(LBuf), 65536, 8388608,
    LMethod, LPath, LQS, LHeaders, LBody, LKeep, LConsumed, LBad));
  Assert.AreEqual('/first', LPath);
  CheckInt(Length(MakeReq(LReq1)), LConsumed);
end;

// ---------------------------------------------------------------------------
// DecodeHTTP1Chunked tests
// ---------------------------------------------------------------------------

procedure TDecodeHTTP1ChunkedTests.SingleChunk_DecodesCorrectly;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
begin
  // "5\r\nhello\r\n0\r\n\r\n"
  LRaw := TEncoding.ASCII.GetBytes('5'#13#10'hello'#13#10'0'#13#10#13#10);
  Assert.IsTrue(DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 8388608,
    LBody, LConsumed, LMal));
  Assert.IsFalse(LMal);
  Assert.AreEqual('hello', TEncoding.ASCII.GetString(LBody));
end;

procedure TDecodeHTTP1ChunkedTests.MultipleChunks_Concatenated;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
begin
  LRaw := TEncoding.ASCII.GetBytes(
    '5'#13#10'hello'#13#10 +
    '6'#13#10' world'#13#10 +
    '0'#13#10#13#10);
  Assert.IsTrue(DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 8388608,
    LBody, LConsumed, LMal));
  Assert.AreEqual('hello world', TEncoding.ASCII.GetString(LBody));
end;

procedure TDecodeHTTP1ChunkedTests.LastChunkZero_SignalsEnd;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
begin
  LRaw := TEncoding.ASCII.GetBytes('0'#13#10#13#10);
  Assert.IsTrue(DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 8388608,
    LBody, LConsumed, LMal));
  CheckInt(0, Length(LBody));
end;

procedure TDecodeHTTP1ChunkedTests.Incomplete_ReturnsFalseNotMalformed;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
begin
  // Only chunk size line present, no data yet
  LRaw := TEncoding.ASCII.GetBytes('5'#13#10);
  Assert.IsFalse(DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 8388608,
    LBody, LConsumed, LMal));
  Assert.IsFalse(LMal);
end;

procedure TDecodeHTTP1ChunkedTests.MalformedHex_ReturnsMalformed;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
begin
  LRaw := TEncoding.ASCII.GetBytes('ZZ'#13#10'data'#13#10'0'#13#10#13#10);
  Assert.IsFalse(DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 8388608,
    LBody, LConsumed, LMal));
  Assert.IsTrue(LMal);
end;

procedure TDecodeHTTP1ChunkedTests.ChunkSizeLineTooLong_ReturnsMalformed;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
  LLine:   string;
begin
  // Chunk size line > 16 chars → malformed
  LLine := StringOfChar('f', 17) + #13#10;
  LRaw  := TEncoding.ASCII.GetBytes(LLine);
  Assert.IsFalse(DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 8388608,
    LBody, LConsumed, LMal));
  Assert.IsTrue(LMal);
end;

procedure TDecodeHTTP1ChunkedTests.OversizedChunk_ReturnsMalformed;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
begin
  // Chunk claims 1 MB but limit is 1 KB
  LRaw := TEncoding.ASCII.GetBytes('100000'#13#10);
  DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 1024,
    LBody, LConsumed, LMal);
  Assert.IsTrue(LMal);
end;

procedure TDecodeHTTP1ChunkedTests.ChunkWithExtension_ExtensionIgnored;
var
  LRaw:    TBytes;
  LBody:   TBytes;
  LConsumed: Integer;
  LMal:    Boolean;
begin
  // "5;ext=value\r\nhello\r\n0\r\n\r\n" — extension after semicolon is ignored
  LRaw := TEncoding.ASCII.GetBytes('5;ext=value'#13#10'hello'#13#10'0'#13#10#13#10);
  Assert.IsTrue(DecodeHTTP1Chunked(@LRaw[0], Length(LRaw), 8388608,
    LBody, LConsumed, LMal));
  Assert.AreEqual('hello', TEncoding.ASCII.GetString(LBody));
end;

initialization
  TDUnitX.RegisterTestFixture(THTTP1ParseRequestTests);
  TDUnitX.RegisterTestFixture(TDecodeHTTP1ChunkedTests);

end.
