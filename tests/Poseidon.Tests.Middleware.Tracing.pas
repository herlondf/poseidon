unit Poseidon.Tests.Middleware.Tracing;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TTracingMiddlewareTests = class
  public
    [Test]
    procedure GeneratesValidTraceParentWhenMissing;
    [Test]
    procedure PreservesTraceIdFromValidIncoming;
    [Test]
    procedure MintsNewSpanIdEvenWithValidIncoming;
    [Test]
    procedure SampledFlagPreservedFromIncoming;
    [Test]
    procedure RejectsMalformedIncoming_GeneratesNewInstead;
    [Test]
    procedure RejectsAllZeroTraceId_GeneratesNewInstead;
    [Test]
    procedure RejectsAllZeroParentId_GeneratesNewInstead;
    [Test]
    procedure RejectsWrongVersion_GeneratesNewInstead;
    [Test]
    procedure RejectsWrongFieldCount_GeneratesNewInstead;
    [Test]
    procedure RejectsNonHexCharacters_GeneratesNewInstead;
    [Test]
    procedure CallsNext;
    [Test]
    procedure ExtractTraceParentIds_ValidHeader_ReturnsTraceAndSpanId;
    [Test]
    procedure ExtractTraceParentIds_InvalidHeader_ReturnsFalse;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Tracing;

function SplitTP(const ATraceParent: string): TArray<string>;
begin
  Result := ATraceParent.Split(['-']);
end;

procedure TTracingMiddlewareTests.GeneratesValidTraceParentWhenMissing;
var
  LCtx: TNativeRequestContext;
  LTP: string;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New.Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LTP := GetExtraHeader(LCtx, 'traceparent');
  LParts := SplitTP(LTP);
  Assert.AreEqual(4, Integer(Length(LParts)));
  Assert.AreEqual('00', LParts[0]);
  Assert.AreEqual(32, Integer(Length(LParts[1])));
  Assert.AreEqual(16, Integer(Length(LParts[2])));
  Assert.AreEqual(2, Integer(Length(LParts[3])));
  Assert.AreEqual('01', LParts[3], 'sampled by default when this hop originates the trace');
end;

procedure TTracingMiddlewareTests.PreservesTraceIdFromValidIncoming;
const
  CIncomingTraceId = 'aaaabbbbccccddddeeeeffff00001111';
var
  LCtx: TNativeRequestContext;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New
    .Header('traceparent', '00-' + CIncomingTraceId + '-1234567890abcdef-01')
    .Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LParts := SplitTP(GetExtraHeader(LCtx, 'traceparent'));
  Assert.AreEqual(CIncomingTraceId, LParts[1]);
end;

procedure TTracingMiddlewareTests.MintsNewSpanIdEvenWithValidIncoming;
const
  CIncomingParentId = '1234567890abcdef';
var
  LCtx: TNativeRequestContext;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New
    .Header('traceparent', '00-aaaabbbbccccddddeeeeffff00001111-' + CIncomingParentId + '-01')
    .Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LParts := SplitTP(GetExtraHeader(LCtx, 'traceparent'));
  Assert.AreNotEqual(CIncomingParentId, LParts[2],
    'this hop must mint its OWN span-id, not echo the caller''s parent-id');
end;

procedure TTracingMiddlewareTests.SampledFlagPreservedFromIncoming;
var
  LCtx: TNativeRequestContext;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New
    .Header('traceparent', '00-aaaabbbbccccddddeeeeffff00001111-1234567890abcdef-00')
    .Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LParts := SplitTP(GetExtraHeader(LCtx, 'traceparent'));
  Assert.AreEqual('00', LParts[3], 'not-sampled decision from upstream must be respected, not overridden');
end;

procedure TTracingMiddlewareTests.RejectsMalformedIncoming_GeneratesNewInstead;
var
  LCtx: TNativeRequestContext;
  LTP: string;
begin
  LCtx := TContextBuilder.New.Header('traceparent', 'not-a-real-traceparent-header').Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LTP := GetExtraHeader(LCtx, 'traceparent');
  Assert.AreEqual(4, Integer(Length(SplitTP(LTP))), 'still produces a well-formed traceparent, not garbage-in-garbage-out');
end;

procedure TTracingMiddlewareTests.RejectsAllZeroTraceId_GeneratesNewInstead;
var
  LCtx: TNativeRequestContext;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New
    .Header('traceparent', '00-00000000000000000000000000000000-1234567890abcdef-01')
    .Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LParts := SplitTP(GetExtraHeader(LCtx, 'traceparent'));
  Assert.AreNotEqual('00000000000000000000000000000000', LParts[1],
    'an all-zero trace-id is explicitly invalid per the W3C spec');
end;

procedure TTracingMiddlewareTests.RejectsAllZeroParentId_GeneratesNewInstead;
const
  CTraceId = 'aaaabbbbccccddddeeeeffff00001111';
var
  LCtx: TNativeRequestContext;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New
    .Header('traceparent', '00-' + CTraceId + '-0000000000000000-01')
    .Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LParts := SplitTP(GetExtraHeader(LCtx, 'traceparent'));
  // An all-zero PARENT-id is invalid too, so the whole header is rejected
  // and a fresh trace (different trace-id) is originated - not just a fresh
  // span-id grafted onto the same trace-id.
  Assert.AreNotEqual(CTraceId, LParts[1]);
end;

procedure TTracingMiddlewareTests.RejectsWrongVersion_GeneratesNewInstead;
const
  CTraceId = 'aaaabbbbccccddddeeeeffff00001111';
var
  LCtx: TNativeRequestContext;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New
    .Header('traceparent', 'ff-' + CTraceId + '-1234567890abcdef-01')
    .Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LParts := SplitTP(GetExtraHeader(LCtx, 'traceparent'));
  Assert.AreEqual('00', LParts[0]);
  Assert.AreNotEqual(CTraceId, LParts[1], 'version "ff" is reserved/invalid, must not be reused');
end;

procedure TTracingMiddlewareTests.RejectsWrongFieldCount_GeneratesNewInstead;
var
  LCtx: TNativeRequestContext;
  LTP: string;
begin
  LCtx := TContextBuilder.New.Header('traceparent', '00-aaaabbbbccccddddeeeeffff00001111-01').Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LTP := GetExtraHeader(LCtx, 'traceparent');
  Assert.AreEqual(4, Integer(Length(SplitTP(LTP))));
end;

procedure TTracingMiddlewareTests.RejectsNonHexCharacters_GeneratesNewInstead;
var
  LCtx: TNativeRequestContext;
  LParts: TArray<string>;
begin
  LCtx := TContextBuilder.New
    .Header('traceparent', '00-zzzzbbbbccccddddeeeeffff00001111-1234567890abcdef-01')
    .Build;
  TracingMiddleware()(LCtx, procedure begin end);
  LParts := SplitTP(GetExtraHeader(LCtx, 'traceparent'));
  Assert.AreNotEqual('zzzzbbbbccccddddeeeeffff00001111', LParts[1]);
end;

procedure TTracingMiddlewareTests.CallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  TracingMiddleware()(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

procedure TTracingMiddlewareTests.ExtractTraceParentIds_ValidHeader_ReturnsTraceAndSpanId;
var
  LTraceId, LSpanId: string;
  LOK: Boolean;
begin
  LOK := ExtractTraceParentIds(
    '00-aaaabbbbccccddddeeeeffff00001111-1234567890abcdef-01', LTraceId, LSpanId);
  Assert.IsTrue(LOK);
  Assert.AreEqual('aaaabbbbccccddddeeeeffff00001111', LTraceId);
  Assert.AreEqual('1234567890abcdef', LSpanId);
end;

procedure TTracingMiddlewareTests.ExtractTraceParentIds_InvalidHeader_ReturnsFalse;
var
  LTraceId, LSpanId: string;
begin
  Assert.IsFalse(ExtractTraceParentIds('garbage', LTraceId, LSpanId));
  Assert.IsFalse(ExtractTraceParentIds('', LTraceId, LSpanId));
end;

initialization
  TDUnitX.RegisterTestFixture(TTracingMiddlewareTests);

end.
