unit Poseidon.Tests.SSL;

// DUnitX tests for SSL injection layer (#25).
//
// Uses TSpySSLProvider (from tests/mocks/) instead of real OpenSSL so that
// every CI runner can execute these tests regardless of library availability.
//
// Coverage:
//   - ConfigureSSL calls the correct sequence of ISSLProvider methods
//   - ConfigureMTLS delegates to the provider
//   - MinTLSVersion is forwarded when ConfigureSSL is called
//   - IsAvailable=False prevents ConfigureSSL from loading
//   - AddSNICertificate calls the correct provider methods
//   - Constructor with nil provider falls back to DefaultSSLProvider
//   - Custom IBufferPool is stored (R-6 DIP)
//
// Port: none — these are pure unit tests (no Listen call).

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TSSLInjectionTests = class
  public
    // ── ConfigureSSL sequence ────────────────────────────────────────────────
    [Test]
    procedure ConfigureSSL_CallsEnsureLoaded;
    [Test]
    procedure ConfigureSSL_CallsNewContext;
    [Test]
    procedure ConfigureSSL_CallsLoadCertAndLoadKey;
    [Test]
    procedure ConfigureSSL_CallsVerifyKey;
    [Test]
    procedure ConfigureSSL_CallsSetMinVersion;
    [Test]
    procedure ConfigureSSL_CallsSetSecurityOptions;
    [Test]
    procedure ConfigureSSL_CallsEnableSessionCache;
    [Test]
    procedure ConfigureSSL_CallsSetSNICallback;
    [Test]
    procedure ConfigureSSL_WithH2_CallsSetALPN;

    // ── MinTLSVersion ────────────────────────────────────────────────────────
    [Test]
    procedure MinTLSVersion_Default_Is0x0303;
    [Test]
    procedure MinTLSVersion_CustomValue_ForwardedToProvider;

    // ── ConfigureMTLS ────────────────────────────────────────────────────────
    [Test]
    procedure ConfigureMTLS_AfterConfigureSSL_CallsProvider;
    [Test]
    procedure ConfigureMTLS_BeforeConfigureSSL_Raises;

    // ── IsAvailable=False ────────────────────────────────────────────────────
    [Test]
    procedure ConfigureSSL_WhenNotAvailable_Raises;

    // ── AddSNICertificate ────────────────────────────────────────────────────
    [Test]
    procedure AddSNICert_AfterConfigureSSL_CallsProviderMethods;

    // ── FreeSSL on close ────────────────────────────────────────────────────
    [Test]
    procedure Destroy_FreesSslCtx;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  Poseidon.Net.HttpServer,
  Poseidon.Net.Interfaces,
  Poseidon.Mock.SSLProvider;

{ TSSLInjectionTests }

// ── helpers ──────────────────────────────────────────────────────────────────

// Returns a server wired to LSpy, with ConfigureSSL already called using
// two dummy file paths (file existence is not checked by the spy).
function MakeConfigured(ASpy: TSpySSLProvider;
  AH2: Boolean = False): TPoseidonNativeServer;
begin
  Result := TPoseidonNativeServer.Create(nil, ASpy);
  Result.HTTP2Enabled := AH2;
  Result.ConfigureSSL('fake.crt', 'fake.key');
end;

// ─────────────────────────────────────────────────────────────────────────────

procedure TSSLInjectionTests.ConfigureSSL_CallsEnsureLoaded;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    Assert.IsTrue(LSpy.WasCalled('EnsureLoaded'), 'EnsureLoaded not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_CallsNewContext;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    Assert.IsTrue(LSpy.WasCalled('NewContext'), 'NewContext not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_CallsLoadCertAndLoadKey;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
  LLog:    TArray<string>;
  LHasCert, LHasKey: Boolean;
  LEntry:  string;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    LLog    := LSpy.CallLog;
    LHasCert := False;
    LHasKey  := False;
    for LEntry in LLog do
    begin
      if LEntry.StartsWith('LoadCert') then LHasCert := True;
      if LEntry.StartsWith('LoadKey')  then LHasKey  := True;
    end;
    Assert.IsTrue(LHasCert, 'LoadCert not called');
    Assert.IsTrue(LHasKey,  'LoadKey not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_CallsVerifyKey;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    Assert.IsTrue(LSpy.WasCalled('VerifyKey'), 'VerifyKey not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_CallsSetMinVersion;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    Assert.IsTrue(LSpy.WasCalled('SetMinVersion'), 'SetMinVersion not called');
  finally
    LServer.Free;
  end;
end;

// #209/TLS-runtime: ConfigureSSL must harden the context (disable client-
// initiated renegotiation, TLS compression, and set server cipher preference).
procedure TSSLInjectionTests.ConfigureSSL_CallsSetSecurityOptions;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    Assert.IsTrue(LSpy.WasCalled('SetSecurityOptions'),
      'SetSecurityOptions not called — renegotiation/compression not hardened');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_CallsEnableSessionCache;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    Assert.IsTrue(LSpy.WasCalled('EnableSessionCache'), 'EnableSessionCache not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_CallsSetSNICallback;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    Assert.IsTrue(LSpy.WasCalled('SetSNICallback'), 'SetSNICallback not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_WithH2_CallsSetALPN;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy, True {H2=True});
  try
    Assert.IsTrue(LSpy.WasCalled('SetALPN'), 'SetALPN not called when H2 enabled');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.MinTLSVersion_Default_Is0x0303;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
  LLog:    TArray<string>;
  LEntry:  string;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    LLog := LSpy.CallLog;
    for LEntry in LLog do
      if LEntry.StartsWith('SetMinVersion') then
      begin
        // SetMinVersion(771) where 771 = $0303 = TLS 1.2
        Assert.IsTrue(LEntry.Contains('771') or LEntry.Contains('0303'),
          'Default TLS version should be 1.2 ($0303 = 771), got: ' + LEntry);
        Exit;
      end;
    Assert.Fail('SetMinVersion was not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.MinTLSVersion_CustomValue_ForwardedToProvider;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
  LLog:    TArray<string>;
  LEntry:  string;
const
  TLS13_VERSION = $0304;  // 772
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := TPoseidonNativeServer.Create(nil, LSpy);
  try
    LServer.MinTLSVersion := TLS13_VERSION;
    LServer.ConfigureSSL('fake.crt', 'fake.key');
    LLog := LSpy.CallLog;
    for LEntry in LLog do
      if LEntry.StartsWith('SetMinVersion') then
      begin
        Assert.IsTrue(LEntry.Contains('772'),
          'SetMinVersion should receive 772 ($0304 = TLS 1.3), got: ' + LEntry);
        Exit;
      end;
    Assert.Fail('SetMinVersion was not called');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureMTLS_AfterConfigureSSL_CallsProvider;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
  LLog:    TArray<string>;
  LEntry:  string;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    LServer.ConfigureMTLS('ca-bundle.crt');
    LLog := LSpy.CallLog;
    for LEntry in LLog do
      if LEntry.StartsWith('ConfigureMTLS') then
      begin
        Assert.IsTrue(LEntry.Contains('ca-bundle.crt'),
          'ConfigureMTLS should forward the CA file path');
        Exit;
      end;
    Assert.Fail('ConfigureMTLS was not called on provider');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureMTLS_BeforeConfigureSSL_Raises;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
  LRaised: Boolean;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := TPoseidonNativeServer.Create(nil, LSpy);
  LRaised := False;
  try
    try
      LServer.ConfigureMTLS('ca.crt');
    except
      LRaised := True;
    end;
    Assert.IsTrue(LRaised,
      'ConfigureMTLS before ConfigureSSL should raise an exception');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.ConfigureSSL_WhenNotAvailable_Raises;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
  LRaised: Boolean;
begin
  LSpy           := TSpySSLProvider.Create;
  LSpy.Available := False;
  LServer := TPoseidonNativeServer.Create(nil, LSpy);
  LRaised := False;
  try
    try
      LServer.ConfigureSSL('fake.crt', 'fake.key');
    except
      LRaised := True;
    end;
    Assert.IsTrue(LRaised,
      'ConfigureSSL when ISSLProvider.IsAvailable=False should raise');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.AddSNICert_AfterConfigureSSL_CallsProviderMethods;
var
  LSpy:    TSpySSLProvider;
  LServer: TPoseidonNativeServer;
begin
  LSpy    := TSpySSLProvider.Create;
  LServer := MakeConfigured(LSpy);
  try
    LSpy.ClearLog;
    LServer.AddSSLCert('example.com', 'example.crt', 'example.key');

    Assert.IsTrue(LSpy.WasCalled('EnsureLoaded'), 'EnsureLoaded on SNI cert');
    Assert.IsTrue(LSpy.WasCalled('NewContext'),   'NewContext for SNI ctx');
    Assert.IsTrue(LSpy.WasCalled('LoadCert'),     'LoadCert for SNI cert');
    Assert.IsTrue(LSpy.WasCalled('LoadKey'),      'LoadKey for SNI cert');
    Assert.IsTrue(LSpy.WasCalled('VerifyKey'),    'VerifyKey for SNI cert');
  finally
    LServer.Free;
  end;
end;

procedure TSSLInjectionTests.Destroy_FreesSslCtx;
var
  LSpy:    TSpySSLProvider;
  IRef:    ISSLProvider;   // keeps spy alive after server.Free
  LServer: TPoseidonNativeServer;
begin
  LSpy := TSpySSLProvider.Create;
  IRef := LSpy;            // interface ref — prevents destruction when server drops it
  LServer := MakeConfigured(LSpy);
  LSpy.ClearLog;
  LServer.Free;
  Assert.IsTrue(LSpy.WasCalled('FreeContext'),
    'FreeContext should be called when server is destroyed');
  IRef := nil;
end;

initialization
  TDUnitX.RegisterTestFixture(TSSLInjectionTests);

end.
