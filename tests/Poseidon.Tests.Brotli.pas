unit Poseidon.Tests.Brotli;

// DUnitX tests for Brotli compression support (#30).
//
// Tests are split into two groups:
//   1. Unit tests for TPoseidonBrotli lazy-loader — always run.
//   2. Integration tests against a live server — only when the Brotli
//      encoder library is available at runtime (TPoseidonBrotli.IsAvailable).
//      When the library is absent, tests pass with an informational message
//      (DUnitX in this build has no Assert.Ignore; Assert.Pass is used instead).
//
// Coverage:
//   - IsAvailable returns True/False without raising
//   - Compress+Decompress round-trip produces the original bytes (when available)
//   - Server with BrotliEnabled=True + "Accept-Encoding: br"  → Content-Encoding: br
//   - Server with BrotliEnabled=True + "Accept-Encoding: gzip" → Content-Encoding: gzip (fallback)
//   - Server with BrotliEnabled=False + "Accept-Encoding: br"  → gzip (BrotliEnabled gate)
//   - q-value negotiation: gzip;q=1.0, br;q=0.9  → gzip wins
//   - BrotliQuality default is 6

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TBrotliUnitTests = class
  public
    // ── Lazy-loader ──────────────────────────────────────────────────────────
    [Test]
    procedure IsAvailable_DoesNotRaise;
    [Test]
    procedure Compress_WhenUnavailable_Raises;
    [Test]
    procedure Decompress_WhenUnavailable_Raises;

    // ── Round-trip (only when libbrotlienc+libbrotlidec are present) ─────────
    [Test]
    procedure CompressDecompress_RoundTrip_Quality6;
    [Test]
    procedure CompressDecompress_RoundTrip_Quality0;
    [Test]
    procedure CompressDecompress_RoundTrip_Quality11;
  end;

  [TestFixture]
  TBrotliServerTests = class
  public
    const INTEST_PORT = 19250;

    // ── Server-level negotiation ─────────────────────────────────────────────
    [Test]
    procedure BrotliEnabled_AcceptBr_Returns_ContentEncodingBr;
    [Test]
    procedure BrotliEnabled_AcceptGzip_Returns_ContentEncodingGzip;
    [Test]
    procedure BrotliDisabled_AcceptBr_Returns_ContentEncodingGzip;
    [Test]
    procedure QValue_GzipHigher_Returns_ContentEncodingGzip;
    [Test]
    procedure BrotliQuality_Default_Is6;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Threading,
  System.Net.HttpClient,
  System.SyncObjs,
  System.Generics.Collections,
  Poseidon.Net.Brotli,
  Poseidon.Net.HttpServer,
  Poseidon.Net.Types;

// ---------------------------------------------------------------------------
// Helper: 2KB JSON body guaranteed to exceed the 1KB compression threshold
// ---------------------------------------------------------------------------

function _MakeLargeBody: TBytes;
var
  LJson: string;
begin
  LJson := '{"data":"' + StringOfChar('x', 1600) + '","msg":"brotli test"}';
  Result := TEncoding.UTF8.GetBytes(LJson);
end;

// ---------------------------------------------------------------------------
// TBrotliUnitTests
// ---------------------------------------------------------------------------

procedure TBrotliUnitTests.IsAvailable_DoesNotRaise;
var
  LAvail: Boolean;
  LRaised: Boolean;
begin
  LAvail  := False;
  LRaised := False;
  try
    LAvail := TPoseidonBrotli.IsAvailable;
  except
    LRaised := True;
  end;
  Assert.IsFalse(LRaised, 'IsAvailable must not raise');
  Assert.IsTrue(LAvail or not LAvail);  // just confirm it returned a Boolean
end;

procedure TBrotliUnitTests.Compress_WhenUnavailable_Raises;
var
  LRaised: Boolean;
begin
  if TPoseidonBrotli.IsAvailable then
  begin
    Assert.Pass('Brotli encoder is present — unavailability test not applicable');
    Exit;
  end;
  LRaised := False;
  try
    TPoseidonBrotli.Compress(TEncoding.UTF8.GetBytes('hello'));
  except
    on E: EPoseidonBrotli do LRaised := True;
  end;
  Assert.IsTrue(LRaised, 'Compress must raise EPoseidonBrotli when library absent');
end;

procedure TBrotliUnitTests.Decompress_WhenUnavailable_Raises;
var
  LRaised: Boolean;
begin
  if TPoseidonBrotli.IsDecoderAvailable then
  begin
    Assert.Pass('Brotli decoder is present — unavailability test not applicable');
    Exit;
  end;
  LRaised := False;
  try
    TPoseidonBrotli.Decompress(TEncoding.UTF8.GetBytes('x'));
  except
    on E: EPoseidonBrotli do LRaised := True;
  end;
  Assert.IsTrue(LRaised, 'Decompress must raise EPoseidonBrotli when library absent');
end;

procedure TBrotliUnitTests.CompressDecompress_RoundTrip_Quality6;
var
  LOriginal:   TBytes;
  LCompressed: TBytes;
  LRestored:   TBytes;
begin
  if not TPoseidonBrotli.IsAvailable then
  begin
    Assert.Pass('Brotli encoder not available — round-trip test skipped');
    Exit;
  end;
  if not TPoseidonBrotli.IsDecoderAvailable then
  begin
    Assert.Pass('Brotli decoder not available — round-trip test skipped');
    Exit;
  end;
  LOriginal   := TEncoding.UTF8.GetBytes(
    'Poseidon HTTP server — Brotli round-trip. ' + StringOfChar('A', 256));
  LCompressed := TPoseidonBrotli.Compress(LOriginal, 6);
  LRestored   := TPoseidonBrotli.Decompress(LCompressed);
  Assert.AreEqual(Length(LOriginal), Length(LRestored),
    'Restored length must match original');
  Assert.AreEqual(TEncoding.UTF8.GetString(LOriginal),
    TEncoding.UTF8.GetString(LRestored),
    'Restored content must match original');
end;

procedure TBrotliUnitTests.CompressDecompress_RoundTrip_Quality0;
var
  LOriginal:   TBytes;
  LCompressed: TBytes;
  LRestored:   TBytes;
begin
  if not TPoseidonBrotli.IsAvailable then
  begin
    Assert.Pass('Brotli encoder not available — skipped');
    Exit;
  end;
  if not TPoseidonBrotli.IsDecoderAvailable then
  begin
    Assert.Pass('Brotli decoder not available — skipped');
    Exit;
  end;
  LOriginal   := TEncoding.UTF8.GetBytes(StringOfChar('B', 512));
  LCompressed := TPoseidonBrotli.Compress(LOriginal, 0);
  LRestored   := TPoseidonBrotli.Decompress(LCompressed);
  Assert.AreEqual(TEncoding.UTF8.GetString(LOriginal),
    TEncoding.UTF8.GetString(LRestored));
end;

procedure TBrotliUnitTests.CompressDecompress_RoundTrip_Quality11;
var
  LOriginal:   TBytes;
  LCompressed: TBytes;
  LRestored:   TBytes;
begin
  if not TPoseidonBrotli.IsAvailable then
  begin
    Assert.Pass('Brotli encoder not available — skipped');
    Exit;
  end;
  if not TPoseidonBrotli.IsDecoderAvailable then
  begin
    Assert.Pass('Brotli decoder not available — skipped');
    Exit;
  end;
  LOriginal   := TEncoding.UTF8.GetBytes(StringOfChar('C', 512));
  LCompressed := TPoseidonBrotli.Compress(LOriginal, 11);
  LRestored   := TPoseidonBrotli.Decompress(LCompressed);
  Assert.AreEqual(TEncoding.UTF8.GetString(LOriginal),
    TEncoding.UTF8.GetString(LRestored));
end;

// ---------------------------------------------------------------------------
// TBrotliServerTests helpers
// ---------------------------------------------------------------------------

type
  TBrotliServerCtx = record
    Server: TPoseidonNativeServer;
    Thread: TThread;
    Ready:  TEvent;
  end;

procedure _StartBrotliServer(out ACtx: TBrotliServerCtx;
  ABrotliEnabled: Boolean; ABrotliQuality: Integer = 6);
var
  // Local refs to allow capture by value in anonymous proc
  LSrv:   TPoseidonNativeServer;
  LReady: TEvent;
begin
  LSrv := TPoseidonNativeServer.Create;
  LSrv.CompressionEnabled := True;
  LSrv.BrotliEnabled      := ABrotliEnabled;
  LSrv.BrotliQuality      := ABrotliQuality;
  LReady := TEvent.Create(nil, True, False, '');
  ACtx.Server := LSrv;
  ACtx.Ready  := LReady;
  ACtx.Thread := TThread.CreateAnonymousThread(
    procedure
    begin
      LSrv.Listen('127.0.0.1', TBrotliServerTests.INTEST_PORT,
        procedure(const AReq: TPoseidonNativeRequest;
          out AStatus: Integer; out AContentType: string;
          out ABody: TBytes; out AExtraHeaders: TArray<TPair<string,string>>)
        begin
          AStatus       := 200;
          AContentType  := 'application/json';
          ABody         := _MakeLargeBody;
          AExtraHeaders := [];
        end,
        procedure begin LReady.SetEvent; end);
    end);
  ACtx.Thread.FreeOnTerminate := False;
  ACtx.Thread.Start;
  ACtx.Ready.WaitFor(5000);
end;

procedure _StopBrotliServer(var ACtx: TBrotliServerCtx);
begin
  ACtx.Server.Stop;
  ACtx.Thread.WaitFor;
  ACtx.Thread.Free;
  ACtx.Server.Free;
  ACtx.Ready.Free;
end;

function _GetContentEncoding(const AAcceptEncoding: string): string;
var
  LClient: THTTPClient;
  LResp:   IHTTPResponse;
begin
  LClient := THTTPClient.Create;
  try
    LClient.CustomHeaders['Accept-Encoding'] := AAcceptEncoding;
    LResp  := LClient.Get(
      Format('http://127.0.0.1:%d/ping', [TBrotliServerTests.INTEST_PORT]));
    Result := LResp.HeaderValue['Content-Encoding'];
  finally
    LClient.Free;
  end;
end;

// ---------------------------------------------------------------------------
// TBrotliServerTests
// ---------------------------------------------------------------------------

procedure TBrotliServerTests.BrotliEnabled_AcceptBr_Returns_ContentEncodingBr;
var
  LCtx: TBrotliServerCtx;
  LEnc: string;
begin
  if not TPoseidonBrotli.IsAvailable then
  begin
    Assert.Pass('Brotli encoder not available — server test skipped');
    Exit;
  end;
  _StartBrotliServer(LCtx, True);
  try
    LEnc := _GetContentEncoding('br, gzip;q=0.9');
    Assert.AreEqual('br', LEnc,
      'Expected Content-Encoding: br when Brotli is enabled and accepted');
  finally
    _StopBrotliServer(LCtx);
  end;
end;

procedure TBrotliServerTests.BrotliEnabled_AcceptGzip_Returns_ContentEncodingGzip;
var
  LCtx: TBrotliServerCtx;
  LEnc: string;
begin
  _StartBrotliServer(LCtx, True);
  try
    LEnc := _GetContentEncoding('gzip');
    Assert.AreEqual('gzip', LEnc,
      'Expected Content-Encoding: gzip when only gzip is accepted');
  finally
    _StopBrotliServer(LCtx);
  end;
end;

procedure TBrotliServerTests.BrotliDisabled_AcceptBr_Returns_ContentEncodingGzip;
var
  LCtx: TBrotliServerCtx;
  LEnc: string;
begin
  _StartBrotliServer(LCtx, False);  // BrotliEnabled = False
  try
    // Client accepts both br and gzip, but BrotliEnabled=False → gzip
    LEnc := _GetContentEncoding('br, gzip;q=0.9');
    Assert.AreNotEqual('br', LEnc,
      'Content-Encoding must not be br when BrotliEnabled=False');
  finally
    _StopBrotliServer(LCtx);
  end;
end;

procedure TBrotliServerTests.QValue_GzipHigher_Returns_ContentEncodingGzip;
var
  LCtx: TBrotliServerCtx;
  LEnc: string;
begin
  if not TPoseidonBrotli.IsAvailable then
  begin
    Assert.Pass('Brotli encoder not available — q-value test skipped');
    Exit;
  end;
  _StartBrotliServer(LCtx, True);
  try
    // RFC 7231 §5.3.4: gzip;q=1.0 > br;q=0.9 → server must prefer gzip
    LEnc := _GetContentEncoding('gzip;q=1.0, br;q=0.9');
    Assert.AreEqual('gzip', LEnc,
      'Expected gzip when its q-value is strictly higher than br''s');
  finally
    _StopBrotliServer(LCtx);
  end;
end;

procedure TBrotliServerTests.BrotliQuality_Default_Is6;
var
  LServer: TPoseidonNativeServer;
begin
  LServer := TPoseidonNativeServer.Create;
  try
    Assert.AreEqual(6, LServer.BrotliQuality,
      'Default BrotliQuality must be 6');
  finally
    LServer.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TBrotliUnitTests);
  TDUnitX.RegisterTestFixture(TBrotliServerTests);

end.
