unit Poseidon.Tests.Middleware.RateLimit;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TRateLimitMiddlewareTests = class
  public
    [Test]
    procedure FirstRequestPasses;
    [Test]
    procedure AddsRateLimitHeaders;
    [Test]
    procedure ExceedingLimitRaisesException;
    [Test]
    procedure UsesXForwardedForIfPresent;
    [Test]
    procedure DistinctKeysBeyondCap_Refused;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.RateLimit,
  Poseidon.Exception;

procedure TRateLimitMiddlewareTests.FirstRequestPasses;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := RateLimitMiddleware(10, 60);
  LCtx := TContextBuilder.New.RemoteAddr('1.1.1.1').Build;
  LCalled := False;
  LMw(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TRateLimitMiddlewareTests.AddsRateLimitHeaders;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := RateLimitMiddleware(100, 60);
  LCtx := TContextBuilder.New.RemoteAddr('2.2.2.2').Build;
  LMw(LCtx, procedure begin end);
  Assert.AreEqual('100', GetExtraHeader(LCtx, 'X-RateLimit-Limit'));
  Assert.AreEqual('99', GetExtraHeader(LCtx, 'X-RateLimit-Remaining'));
end;

procedure TRateLimitMiddlewareTests.ExceedingLimitRaisesException;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  I: Integer;
  LRaised: Boolean;
begin
  LMw := RateLimitMiddleware(3, 60);
  LRaised := False;
  for I := 1 to 5 do
  begin
    LCtx := TContextBuilder.New.RemoteAddr('3.3.3.3').Build;
    try
      LMw(LCtx, procedure begin end);
    except
      on E: EPoseidonException do
        LRaised := True;
    end;
  end;
  Assert.IsTrue(LRaised);
end;

procedure TRateLimitMiddlewareTests.UsesXForwardedForIfPresent;
var
  LCtx1, LCtx2: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
begin
  LMw := RateLimitMiddleware(100, 60);
  LCtx1 := TContextBuilder.New
    .RemoteAddr('127.0.0.1')
    .Header('X-Forwarded-For', '10.0.0.1, 192.168.1.1')
    .Build;
  LMw(LCtx1, procedure begin end);

  LCtx2 := TContextBuilder.New
    .RemoteAddr('127.0.0.1')
    .Header('X-Forwarded-For', '10.0.0.1')
    .Build;
  LMw(LCtx2, procedure begin end);

  Assert.AreEqual('98', GetExtraHeader(LCtx2, 'X-RateLimit-Remaining'));
end;

// #209 regression: an unbounded counter map is a memory-DoS — a distinct-key
// flood (IPv6 rotation / spoofed XFF) inserts one live entry per request. With
// the map capped at 5 tracked keys, the 6th distinct source must be refused
// (429) rather than growing the map.
procedure TRateLimitMiddlewareTests.DistinctKeysBeyondCap_Refused;
var
  LCtx: TNativeRequestContext;
  LMw: TNativeMiddlewareFunc;
  I: Integer;
  LRaised: Boolean;
begin
  LMw := RateLimitMiddleware(100, 60, 'Too Many Requests', False, nil, 5);
  for I := 1 to 5 do
  begin
    LCtx := TContextBuilder.New.RemoteAddr('10.0.0.' + IntToStr(I)).Build;
    LMw(LCtx, procedure begin end);  // 5 distinct keys fill the capped map
  end;

  LRaised := False;
  LCtx := TContextBuilder.New.RemoteAddr('10.0.0.6').Build;  // 6th distinct key
  try
    LMw(LCtx, procedure begin end);
  except
    on E: EPoseidonException do
      LRaised := True;
  end;
  Assert.IsTrue(LRaised, '6th distinct key beyond the cap must be refused (429)');
end;

initialization
  TDUnitX.RegisterTestFixture(TRateLimitMiddlewareTests);

end.
