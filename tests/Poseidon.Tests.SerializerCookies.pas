unit Poseidon.Tests.SerializerCookies;

interface

uses
  DUnitX.TestFramework;

type
  TUserDTO = class
    Id:     Integer;
    Name:   string;
    Email:  string;
    Active: Boolean;
  end;

  TNestedAddressDTO = class
    Street: string;
    City:   string;
    Zip:    Integer;
  end;

  TUserWithAddressDTO = class
    Id:      Integer;
    Name:    string;
    Address: TNestedAddressDTO;
    destructor Destroy; override;
  end;

  TEdgeCasesDTO = class
    Quote:   string;
    Newline: string;
    Backslash: string;
    Big:     Int64;
    Ratio:   Double;
  end;

  [TestFixture]
  TSerializerTests = class
  public
    [Test] procedure FlatObject_ProducesValidJSON;
    [Test] procedure NestedObject_SerializesRecursively;
    [Test] procedure NilObject_ReturnsNullLiteral;
    [Test] procedure StringEscaping_QuotesAndControlChars;
    [Test] procedure CacheHit_SecondCallReusesCompiledWriter;
  end;

  [TestFixture]
  TCookieTests = class
  public
    [Test] procedure Parse_SingleCookie;
    [Test] procedure Parse_MultipleCookies;
    [Test] procedure Parse_EmptyHeader_EmptyJar;
    [Test] procedure Parse_TrimsWhitespace;
    [Test] procedure Build_DefaultOptions;
    [Test] procedure Build_AllOptions;
    [Test] procedure SignAndVerify_Roundtrip;
    [Test] procedure Verify_RejectsTamperedSignature;
    [Test] procedure Verify_RejectsWrongSecret;
    [Test] procedure Verify_RejectsMalformedInput;
  end;

implementation

uses
  System.SysUtils,
  System.JSON,
  Poseidon.Serializer.AOT,
  Poseidon.Cookies;

{ TUserWithAddressDTO }

destructor TUserWithAddressDTO.Destroy;
begin
  Address.Free;
  inherited;
end;

{ TSerializerTests }

procedure TSerializerTests.FlatObject_ProducesValidJSON;
var
  LDto:  TUserDTO;
  LJson: string;
  LObj:  TJSONObject;
begin
  LDto := TUserDTO.Create;
  try
    LDto.Id     := 42;
    LDto.Name   := 'Alice';
    LDto.Email  := 'a@b.com';
    LDto.Active := True;
    LJson := TPoseidonSerializer.ToJson(LDto);
  finally
    LDto.Free;
  end;

  // Round-trip through TJSONObject to assert structural correctness.
  LObj := TJSONObject.ParseJSONValue(LJson) as TJSONObject;
  try
    Assert.IsNotNull(LObj, 'Output is not parseable JSON: ' + LJson);
    Assert.AreEqual(42, (LObj.GetValue('Id') as TJSONNumber).AsInt);
    Assert.AreEqual('Alice', LObj.GetValue('Name').Value);
    Assert.AreEqual('a@b.com', LObj.GetValue('Email').Value);
    Assert.IsTrue((LObj.GetValue('Active') as TJSONBool).AsBoolean);
  finally
    LObj.Free;
  end;
end;

procedure TSerializerTests.NestedObject_SerializesRecursively;
var
  LDto:  TUserWithAddressDTO;
  LJson: string;
  LObj:  TJSONObject;
  LAddr: TJSONObject;
begin
  LDto := TUserWithAddressDTO.Create;
  try
    LDto.Id           := 1;
    LDto.Name         := 'Bob';
    LDto.Address      := TNestedAddressDTO.Create;
    LDto.Address.Street := 'Rua A';
    LDto.Address.City   := 'Recife';
    LDto.Address.Zip    := 50000;
    LJson := TPoseidonSerializer.ToJson(LDto);
  finally
    LDto.Free;
  end;

  LObj := TJSONObject.ParseJSONValue(LJson) as TJSONObject;
  try
    Assert.IsNotNull(LObj);
    LAddr := LObj.GetValue('Address') as TJSONObject;
    Assert.IsNotNull(LAddr, 'Nested Address missing');
    Assert.AreEqual('Recife', LAddr.GetValue('City').Value);
    Assert.AreEqual(50000, (LAddr.GetValue('Zip') as TJSONNumber).AsInt);
  finally
    LObj.Free;
  end;
end;

procedure TSerializerTests.NilObject_ReturnsNullLiteral;
begin
  Assert.AreEqual('null', TPoseidonSerializer.ToJson(nil));
end;

procedure TSerializerTests.StringEscaping_QuotesAndControlChars;
var
  LDto:  TEdgeCasesDTO;
  LJson: string;
  LObj:  TJSONObject;
begin
  LDto := TEdgeCasesDTO.Create;
  try
    LDto.Quote     := 'a"b';
    LDto.Newline   := 'line1' + #10 + 'line2';
    LDto.Backslash := 'a\b';
    LDto.Big       := 1234567890123;
    LDto.Ratio     := 3.14;
    LJson := TPoseidonSerializer.ToJson(LDto);
  finally
    LDto.Free;
  end;

  // Parse back to verify escaping is interpretable by a real JSON parser.
  LObj := TJSONObject.ParseJSONValue(LJson) as TJSONObject;
  try
    Assert.IsNotNull(LObj, 'Escaped JSON unparseable: ' + LJson);
    Assert.AreEqual('a"b',                  LObj.GetValue('Quote').Value);
    Assert.AreEqual('line1' + #10 + 'line2', LObj.GetValue('Newline').Value);
    Assert.AreEqual('a\b',                  LObj.GetValue('Backslash').Value);
    Assert.AreEqual(Int64(1234567890123),
      (LObj.GetValue('Big') as TJSONNumber).AsInt64);
  finally
    LObj.Free;
  end;
end;

procedure TSerializerTests.CacheHit_SecondCallReusesCompiledWriter;
var
  LDto: TUserDTO;
  LA, LB: string;
begin
  // The cache is internal; we verify behaviorally that repeated calls produce
  // identical, valid output without raising.
  LDto := TUserDTO.Create;
  try
    LDto.Id := 7; LDto.Name := 'x'; LDto.Email := 'y'; LDto.Active := False;
    LA := TPoseidonSerializer.ToJson(LDto);
    LB := TPoseidonSerializer.ToJson(LDto);
    Assert.AreEqual(LA, LB);
  finally
    LDto.Free;
  end;
end;

{ TCookieTests }

procedure TCookieTests.Parse_SingleCookie;
var
  LJar: TCookieJar;
begin
  LJar := TCookieJar.Create;
  try
    LJar.Parse('session=abc123');
    Assert.IsTrue(LJar.Has('session'));
    Assert.AreEqual('abc123', LJar.Get('session'));
    Assert.AreEqual(1, LJar.Count);
  finally
    LJar.Free;
  end;
end;

procedure TCookieTests.Parse_MultipleCookies;
var
  LJar: TCookieJar;
begin
  LJar := TCookieJar.Create;
  try
    LJar.Parse('a=1; b=2; c=hello');
    Assert.AreEqual(3, LJar.Count);
    Assert.AreEqual('1',     LJar.Get('a'));
    Assert.AreEqual('2',     LJar.Get('b'));
    Assert.AreEqual('hello', LJar.Get('c'));
  finally
    LJar.Free;
  end;
end;

procedure TCookieTests.Parse_EmptyHeader_EmptyJar;
var
  LJar: TCookieJar;
begin
  LJar := TCookieJar.Create;
  try
    LJar.Parse('');
    Assert.AreEqual(0, LJar.Count);
    Assert.IsFalse(LJar.Has('any'));
    Assert.AreEqual('fallback', LJar.Get('missing', 'fallback'));
  finally
    LJar.Free;
  end;
end;

procedure TCookieTests.Parse_TrimsWhitespace;
var
  LJar: TCookieJar;
begin
  LJar := TCookieJar.Create;
  try
    LJar.Parse('  name1 = value1 ;  name2= value2  ');
    Assert.AreEqual('value1', LJar.Get('name1'));
    Assert.AreEqual('value2', LJar.Get('name2'));
  finally
    LJar.Free;
  end;
end;

procedure TCookieTests.Build_DefaultOptions;
var
  LHdr: string;
begin
  LHdr := TCookieFormat.Build('foo', 'bar', TCookieOptions.Default);
  Assert.AreEqual('foo=bar; Path=/', LHdr);
end;

procedure TCookieTests.Build_AllOptions;
var
  LOpts: TCookieOptions;
  LHdr:  string;
begin
  LOpts := TCookieOptions.Default
    .WithPath('/api')
    .WithDomain('example.com')
    .WithMaxAge(3600)
    .AsHttpOnly
    .AsSecure
    .WithSameSite(csStrict);
  LHdr := TCookieFormat.Build('session', 'abc', LOpts);
  Assert.IsTrue(LHdr.StartsWith('session=abc'), 'Missing name=value: ' + LHdr);
  Assert.Contains(LHdr, 'Path=/api');
  Assert.Contains(LHdr, 'Domain=example.com');
  Assert.Contains(LHdr, 'Max-Age=3600');
  Assert.Contains(LHdr, 'HttpOnly');
  Assert.Contains(LHdr, 'Secure');
  Assert.Contains(LHdr, 'SameSite=Strict');
end;

procedure TCookieTests.SignAndVerify_Roundtrip;
var
  LSigned, LRecovered: string;
begin
  LSigned := TCookieFormat.Sign('user:42', 'my-secret');
  Assert.IsTrue(LSigned.Contains('.'), 'Signed value lacks separator: ' + LSigned);
  Assert.IsTrue(TCookieFormat.VerifySigned(LSigned, 'my-secret', LRecovered),
    'Verification of valid signature failed');
  Assert.AreEqual('user:42', LRecovered);
end;

procedure TCookieTests.Verify_RejectsTamperedSignature;
var
  LSigned, LRecovered: string;
begin
  LSigned := TCookieFormat.Sign('user:42', 'my-secret');
  // Flip last char of signature
  LSigned[Length(LSigned)] :=
    Char(Ord(LSigned[Length(LSigned)]) xor 1);
  Assert.IsFalse(TCookieFormat.VerifySigned(LSigned, 'my-secret', LRecovered));
  Assert.AreEqual('', LRecovered);
end;

procedure TCookieTests.Verify_RejectsWrongSecret;
var
  LSigned, LRecovered: string;
begin
  LSigned := TCookieFormat.Sign('user:42', 'right-secret');
  Assert.IsFalse(TCookieFormat.VerifySigned(LSigned, 'wrong-secret', LRecovered));
end;

procedure TCookieTests.Verify_RejectsMalformedInput;
var
  LRecovered: string;
begin
  Assert.IsFalse(TCookieFormat.VerifySigned('', 'secret', LRecovered));
  Assert.IsFalse(TCookieFormat.VerifySigned('no-dot-here', 'secret', LRecovered));
  Assert.IsFalse(TCookieFormat.VerifySigned('.empty-value', 'secret', LRecovered));
end;

initialization
  TDUnitX.RegisterTestFixture(TSerializerTests);
  TDUnitX.RegisterTestFixture(TCookieTests);

end.
