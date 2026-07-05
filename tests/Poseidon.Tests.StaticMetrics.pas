unit Poseidon.Tests.StaticMetrics;

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TMetricsTests = class
  public
    [Test] procedure MetricsEndpoint_Returns200WithPrometheusText;
    [Test] procedure MetricsEndpoint_CountsRequests;
    [Test] procedure NonMetricsPath_CallsNext;
  end;

  [TestFixture]
  TStaticTests = class
  private
    FTempDir: string;
  public
    [Setup]    procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure ExistingFile_Returns200;
    [Test] procedure MissingFile_CallsNext;
    [Test] procedure DirectoryTraversal_Returns403;
    [Test] procedure ETag_Returns304WhenMatched;
    [Test] procedure CorrectMimeType_ForJS;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Poseidon.Callback,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Middleware.Metrics,
  Poseidon.Middleware.Static,
  Poseidon.Mock.WebRequest,
  Poseidon.Mock.WebResponse;

{ TMetricsTests }

procedure TMetricsTests.MetricsEndpoint_Returns200WithPrometheusText;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/metrics');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  LMiddleware := TPoseidonMiddlewareMetrics.New('/metrics');
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.AreEqual(200, LMockRes.SentStatusCode);
    Assert.IsTrue(LMockRes.SentContent.Contains('poseidon_requests_total'),
      'Response should be Prometheus text');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TMetricsTests.MetricsEndpoint_CountsRequests;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
  LContent:    string;
begin
  LMiddleware := TPoseidonMiddlewareMetrics.New('/metrics');

  // Send a tracked request first
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/api/ping');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  try
    LMiddleware(LReq, LRes, LNext);
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;

  // Now fetch metrics
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/metrics');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  try
    LMiddleware(LReq, LRes, LNext);
    LContent := LMockRes.SentContent;
    Assert.IsTrue(LContent.Contains('/api/ping'),
      'Metrics should contain the tracked path');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TMetricsTests.NonMetricsPath_CallsNext;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/api/users');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareMetrics.New('/metrics');
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsTrue(LNextCalled, 'Next should be called for non-metrics paths');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

{ TStaticTests }

procedure TStaticTests.Setup;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath,
    'poseidon_static_test_' + GUIDToString(TGUID.NewGuid).Replace('{','').Replace('}','').Substring(0, 8));
  TDirectory.CreateDirectory(FTempDir);
  TFile.WriteAllText(TPath.Combine(FTempDir, 'app.js'),
    'console.log("hello");', TEncoding.UTF8);
  TFile.WriteAllText(TPath.Combine(FTempDir, 'index.html'),
    '<html></html>', TEncoding.UTF8);
end;

procedure TStaticTests.TearDown;
begin
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TStaticTests.ExistingFile_Returns200;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/static/app.js');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareStatic.New('/static', FTempDir, False);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsFalse(LNextCalled, 'Next should not be called for existing file');
    Assert.AreEqual(200, LMockRes.SentStatusCode);
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TStaticTests.MissingFile_CallsNext;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/static/notfound.png');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareStatic.New('/static', FTempDir, False);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsTrue(LNextCalled, 'Next should be called when file not found');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TStaticTests.DirectoryTraversal_Returns403;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LNextCalled: Boolean;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/static/../../etc/passwd');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNextCalled := False;
  LNext := procedure begin LNextCalled := True; end;
  LMiddleware := TPoseidonMiddlewareStatic.New('/static', FTempDir, False);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsFalse(LNextCalled, 'Next should not be called on traversal attempt');
    Assert.AreEqual(403, LMockRes.SentStatusCode);
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TStaticTests.ETag_Returns304WhenMatched;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
  LETag:       string;
begin
  LMiddleware := TPoseidonMiddlewareStatic.New('/static', FTempDir, False);

  // First request to get the ETag
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/static/app.js');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  try
    LMiddleware(LReq, LRes, LNext);
    LETag := LMockRes.SentHeaders.Values['ETag'];
    Assert.IsFalse(LETag.IsEmpty, 'First response should have ETag');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;

  // Second request with If-None-Match
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/static/app.js');
  LMockReq.AddHeader('If-None-Match', LETag);
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.AreEqual(304, LMockRes.SentStatusCode, 'Should return 304 when ETag matches');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

procedure TStaticTests.CorrectMimeType_ForJS;
var
  LMockReq:    TMockWebRequest;
  LMockRes:    TMockWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LMiddleware: TPoseidonCallback;
  LNext:       TNextProc;
begin
  LMockReq := TMockWebRequest.Create;
  LMockReq.SetPathInfo('/static/app.js');
  LMockRes := TMockWebResponse.Create(LMockReq);
  LReq := TPoseidonRequest.Create(LMockReq);
  LRes := TPoseidonResponse.Create(LMockRes);
  LNext := procedure begin end;
  LMiddleware := TPoseidonMiddlewareStatic.New('/static', FTempDir, False);
  try
    LMiddleware(LReq, LRes, LNext);
    Assert.IsTrue(
      LMockRes.SentHeaders.Values['Content-Type'].Contains('javascript'),
      'Content-Type should be application/javascript');
  finally
    LRes.Free; LReq.Free; LMockRes.Free; LMockReq.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TMetricsTests);
  TDUnitX.RegisterTestFixture(TStaticTests);

end.
