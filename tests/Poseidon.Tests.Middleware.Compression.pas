unit Poseidon.Tests.Middleware.Compression;

interface

uses
  DUnitX.TestFramework,
  Poseidon.Native.Types,
  Poseidon.Mock.Context;

type
  [TestFixture]
  TCompressionMiddlewareTests = class
  public
    [Test]
    procedure CompressesLargeJSONBody;
    [Test]
    procedure SkipsSmallBody;
    [Test]
    procedure SkipsWithoutAcceptEncoding;
    [Test]
    procedure SkipsNonCompressibleType;
    [Test]
    procedure AddsContentEncodingHeader;
    [Test]
    procedure AddsVaryHeader;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Middleware.Compression;

function MakeLargeJSON: string;
var
  I: Integer;
begin
  Result := '{"data":"';
  for I := 1 to 200 do
    Result := Result + 'abcdefghij';
  Result := Result + '"}';
end;

procedure TCompressionMiddlewareTests.CompressesLargeJSONBody;
var
  LCtx: TNativeRequestContext;
  LOrigSize: Integer;
  LBody: string;
begin
  LBody := MakeLargeJSON;
  LCtx := TContextBuilder.New
    .Header('Accept-Encoding', 'gzip, deflate')
    .Build;
  LOrigSize := Length(TEncoding.UTF8.GetBytes(LBody));

  CompressionMiddleware(100)(LCtx,
    procedure
    begin
      LCtx.Status := 200;
      LCtx.ContentType := 'application/json';
      LCtx.Body := TEncoding.UTF8.GetBytes(LBody);
    end);

  Assert.IsTrue(Length(LCtx.Body) < LOrigSize, 'Compressed should be smaller');
end;

procedure TCompressionMiddlewareTests.SkipsSmallBody;
var
  LCtx: TNativeRequestContext;
  LOrigBody: TBytes;
begin
  LCtx := TContextBuilder.New
    .Header('Accept-Encoding', 'gzip')
    .Build;
  LOrigBody := TEncoding.UTF8.GetBytes('{"ok":true}');

  CompressionMiddleware(860)(LCtx,
    procedure
    begin
      LCtx.ContentType := 'application/json';
      LCtx.Body := LOrigBody;
    end);

  Assert.AreEqual(Length(LOrigBody), Length(LCtx.Body));
end;

procedure TCompressionMiddlewareTests.SkipsWithoutAcceptEncoding;
var
  LCtx: TNativeRequestContext;
  LBody: string;
  LOrigSize: Integer;
begin
  LBody := MakeLargeJSON;
  LCtx := TContextBuilder.New.Build;
  LOrigSize := Length(TEncoding.UTF8.GetBytes(LBody));

  CompressionMiddleware(100)(LCtx,
    procedure
    begin
      LCtx.ContentType := 'application/json';
      LCtx.Body := TEncoding.UTF8.GetBytes(LBody);
    end);

  Assert.AreEqual(LOrigSize, Length(LCtx.Body));
end;

procedure TCompressionMiddlewareTests.SkipsNonCompressibleType;
var
  LCtx: TNativeRequestContext;
  LBody: TBytes;
begin
  SetLength(LBody, 2000);
  LCtx := TContextBuilder.New
    .Header('Accept-Encoding', 'gzip')
    .Build;

  CompressionMiddleware(100)(LCtx,
    procedure
    begin
      LCtx.ContentType := 'image/png';
      LCtx.Body := LBody;
    end);

  Assert.AreEqual(2000, Length(LCtx.Body));
end;

procedure TCompressionMiddlewareTests.AddsContentEncodingHeader;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New
    .Header('Accept-Encoding', 'gzip')
    .Build;

  CompressionMiddleware(10)(LCtx,
    procedure
    begin
      LCtx.ContentType := 'application/json';
      LCtx.Body := TEncoding.UTF8.GetBytes(MakeLargeJSON);
    end);

  Assert.AreEqual('gzip', GetExtraHeader(LCtx, 'Content-Encoding'));
end;

procedure TCompressionMiddlewareTests.AddsVaryHeader;
var
  LCtx: TNativeRequestContext;
begin
  LCtx := TContextBuilder.New
    .Header('Accept-Encoding', 'gzip')
    .Build;

  CompressionMiddleware(10)(LCtx,
    procedure
    begin
      LCtx.ContentType := 'text/html';
      LCtx.Body := TEncoding.UTF8.GetBytes(MakeLargeJSON);
    end);

  Assert.AreEqual('Accept-Encoding', GetExtraHeader(LCtx, 'Vary'));
end;

initialization
  TDUnitX.RegisterTestFixture(TCompressionMiddlewareTests);

end.
