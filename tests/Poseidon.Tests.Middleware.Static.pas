unit Poseidon.Tests.Middleware.Static;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TStaticMiddlewareTests = class
  private
    FTempDir: string;
  public
    [SetupFixture]
    procedure SetupFixture;
    [TeardownFixture]
    procedure TeardownFixture;
    [Test]
    procedure ServesExistingFile;
    [Test]
    procedure NonPrefixCallsNext;
    [Test]
    procedure MissingFileCallsNext;
    [Test]
    procedure PathTraversalReturns403;
    [Test]
    procedure SetsCorrectMimeType;
    [Test]
    procedure ETagHeaderPresent;
  end;

implementation

uses
  System.SysUtils,
  System.IOUtils,
  Poseidon.Middleware.Static;

procedure TStaticMiddlewareTests.SetupFixture;
begin
  FTempDir := TPath.Combine(TPath.GetTempPath, 'poseidon_static_test_' + IntToHex(Random(MaxInt), 8));
  TDirectory.CreateDirectory(FTempDir);
  TFile.WriteAllText(TPath.Combine(FTempDir, 'hello.txt'), 'Hello World');
  TFile.WriteAllText(TPath.Combine(FTempDir, 'style.css'), 'body { color: red; }');
end;

procedure TStaticMiddlewareTests.TeardownFixture;
begin
  if TDirectory.Exists(FTempDir) then
    TDirectory.Delete(FTempDir, True);
end;

procedure TStaticMiddlewareTests.ServesExistingFile;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := StaticMiddleware('/static', FTempDir, False);
  LCtx := TContextBuilder.New.Path('/static/hello.txt').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.AreEqual('Hello World', BodyAsString(LCtx));
  Assert.IsTrue(LCtx.Handled);
end;

procedure TStaticMiddlewareTests.NonPrefixCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LMw := StaticMiddleware('/static', FTempDir);
  LCtx := TContextBuilder.New.Path('/api/data').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
  Assert.IsFalse(LCtx.Handled);
end;

procedure TStaticMiddlewareTests.MissingFileCallsNext;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LMw := StaticMiddleware('/static', FTempDir);
  LCtx := TContextBuilder.New.Path('/static/nonexistent.txt').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TStaticMiddlewareTests.PathTraversalReturns403;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := StaticMiddleware('/static', FTempDir);
  LCtx := TContextBuilder.New.Path('/static/../../../etc/passwd').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(403, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TStaticMiddlewareTests.SetsCorrectMimeType;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := StaticMiddleware('/static', FTempDir, False);
  LCtx := TContextBuilder.New.Path('/static/style.css').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.IsTrue(LCtx.ContentType.Contains('text/css'));
end;

procedure TStaticMiddlewareTests.ETagHeaderPresent;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LETag: string;
begin
  LMw := StaticMiddleware('/static', FTempDir, False);
  LCtx := TContextBuilder.New.Path('/static/hello.txt').Build;
  LMw(LCtx, procedure begin end);
  LETag := GetExtraHeader(LCtx, 'ETag');
  Assert.IsNotEmpty(LETag);
end;

initialization
  TDUnitX.RegisterTestFixture(TStaticMiddlewareTests);

end.
