unit Poseidon.Tests.Middleware.Cache;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TCacheMiddlewareTests = class
  public
    [Test]
    procedure FirstRequestIsCacheMiss;
    [Test]
    procedure SecondRequestIsCacheHit;
    [Test]
    procedure IfNoneMatchReturns304;
    [Test]
    procedure NonGetRequestSkipsCache;
    [Test]
    procedure ETagHeaderPresent;
    [Test]
    procedure DifferentPathsDifferentEntries;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Cache;

procedure TCacheMiddlewareTests.FirstRequestIsCacheMiss;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := CacheMiddleware(60);
  LCtx := TContextBuilder.New.Path('/data').Build;
  LMw(LCtx, procedure begin
    LCtx.Status := 200;
    LCtx.ContentType := 'application/json';
    LCtx.Body := TEncoding.UTF8.GetBytes('{"ok":true}');
  end);
  Assert.AreEqual(200, LCtx.Status);
  Assert.AreEqual('MISS', GetExtraHeader(LCtx, 'X-Cache'));
end;

procedure TCacheMiddlewareTests.SecondRequestIsCacheHit;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCallCount: Integer;
begin
  LMw := CacheMiddleware(60);
  LCallCount := 0;

  LCtx := TContextBuilder.New.Path('/data').Build;
  LMw(LCtx, procedure begin
    Inc(LCallCount);
    LCtx.Status := 200;
    LCtx.Body := TEncoding.UTF8.GetBytes('hello');
  end);

  LCtx := TContextBuilder.New.Path('/data').Build;
  LMw(LCtx, procedure begin Inc(LCallCount); end);

  Assert.AreEqual(200, LCtx.Status);
  Assert.AreEqual('HIT', GetExtraHeader(LCtx, 'X-Cache'));
  Assert.AreEqual(1, LCallCount);
end;

procedure TCacheMiddlewareTests.IfNoneMatchReturns304;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LETag: string;
begin
  LMw := CacheMiddleware(60);

  LCtx := TContextBuilder.New.Path('/data').Build;
  LMw(LCtx, procedure begin
    LCtx.Status := 200;
    LCtx.Body := TEncoding.UTF8.GetBytes('test');
  end);
  LETag := GetExtraHeader(LCtx, 'ETag');

  LCtx := TContextBuilder.New
    .Path('/data')
    .Header('If-None-Match', LETag)
    .Build;
  LMw(LCtx, procedure begin end);

  Assert.AreEqual(304, LCtx.Status);
  Assert.IsTrue(LCtx.Handled);
end;

procedure TCacheMiddlewareTests.NonGetRequestSkipsCache;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  LCalled: Boolean;
begin
  LMw := CacheMiddleware(60);
  LCtx := TContextBuilder.New.Method('POST').Path('/data').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
  Assert.AreEqual('', GetExtraHeader(LCtx, 'X-Cache'));
end;

procedure TCacheMiddlewareTests.ETagHeaderPresent;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := CacheMiddleware(60);
  LCtx := TContextBuilder.New.Path('/data').Build;
  LMw(LCtx, procedure begin
    LCtx.Status := 200;
    LCtx.Body := TEncoding.UTF8.GetBytes('body');
  end);
  Assert.IsNotEmpty(GetExtraHeader(LCtx, 'ETag'));
end;

procedure TCacheMiddlewareTests.DifferentPathsDifferentEntries;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := CacheMiddleware(60);

  LCtx := TContextBuilder.New.Path('/a').Build;
  LMw(LCtx, procedure begin
    LCtx.Status := 200;
    LCtx.Body := TEncoding.UTF8.GetBytes('aaa');
  end);

  LCtx := TContextBuilder.New.Path('/b').Build;
  LMw(LCtx, procedure begin
    LCtx.Status := 200;
    LCtx.Body := TEncoding.UTF8.GetBytes('bbb');
  end);
  Assert.AreEqual('MISS', GetExtraHeader(LCtx, 'X-Cache'));
end;

initialization
  TDUnitX.RegisterTestFixture(TCacheMiddlewareTests);

end.
