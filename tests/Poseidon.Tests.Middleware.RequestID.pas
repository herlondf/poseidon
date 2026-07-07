unit Poseidon.Tests.Middleware.RequestID;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TRequestIDMiddlewareTests = class
  public
    [Test]
    procedure GeneratesIDWhenMissing;
    [Test]
    procedure PreservesExistingID;
    [Test]
    procedure GeneratedIDIsNotEmpty;
    [Test]
    procedure CallsNext;
  end;

implementation

uses
  Poseidon.Middleware.RequestID;

procedure TRequestIDMiddlewareTests.GeneratesIDWhenMissing;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Build;
  RequestIDMiddleware(LCtx, procedure begin end);
  Assert.IsTrue(GetExtraHeader(LCtx, 'X-Request-ID') <> '');
end;

procedure TRequestIDMiddlewareTests.PreservesExistingID;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New.Header('X-Request-ID', 'my-custom-id').Build;
  RequestIDMiddleware(LCtx, procedure begin end);
  Assert.AreEqual('my-custom-id', GetExtraHeader(LCtx, 'X-Request-ID'));
end;

procedure TRequestIDMiddlewareTests.GeneratedIDIsNotEmpty;
var
  LCtx: TNativeRequestContext;
  LID: string;
begin
  LCtx := TContextBuilder.New.Build;
  RequestIDMiddleware(LCtx, procedure begin end);
  LID := GetExtraHeader(LCtx, 'X-Request-ID');
  Assert.IsTrue(Length(LID) > 10);
end;

procedure TRequestIDMiddlewareTests.CallsNext;
var
  LCtx: TNativeRequestContext;
  LCalled: Boolean;
begin
  LCtx := TContextBuilder.New.Build;
  LCalled := False;
  RequestIDMiddleware(LCtx, procedure begin LCalled := True; end);
  Assert.IsTrue(LCalled);
end;

initialization
  TDUnitX.RegisterTestFixture(TRequestIDMiddlewareTests);

end.
