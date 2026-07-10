unit Poseidon.Net.SSL.Manager;

// TSSLManager — SSL/TLS configuration: context creation, SNI, mTLS.
//
// Extracted from TPoseidonNativeServer. Owns FSSLCtx, FCertCtxByHost,
// FSSLEnabled, FMinTLSVersion. Runtime SSL I/O (_EncryptAndSend,
// _ProcessRecvSSL) remains in the server as transport-layer concerns.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Net.Interfaces;

const
  SSL_TLSEXT_ERR_OK    = 0;
  SSL_TLSEXT_ERR_NOACK = 3;

type
  TSSLManager = class
  private
    FSSLProvider: ISSLProvider;
    FSSLCtx: Pointer;
    FCertCtxByHost: TDictionary<string, Pointer>;
    FSSLEnabled: Boolean;
    FMinTLSVersion: Integer;
    FH2Enabled: Boolean;   // replicated onto per-host SNI contexts (#M8 ALPN)
    FServerRef: Pointer;   // ALPN callback arg for per-host contexts
    FCAFile: string;       // mTLS CA; '' = no mTLS. Replicated per-host (#M7)
  public
    constructor Create(ASSLProvider: ISSLProvider);
    destructor Destroy; override;

    procedure ConfigureSSL(const ACertFile, AKeyFile: string;
      AH2Enabled: Boolean; AServerRef: Pointer);
    procedure ConfigureMTLS(const ACAFile: string);
    procedure AddSSLCert(const AHostName, ACertFile, AKeyFile: string);

    // Create a new SSL handle for a connection
    function NewSSL: Pointer;
    procedure FreeSSL(AHandle: Pointer);
    procedure SetupServerBIOs(AHandle: Pointer; out AReadBio, AWriteBio: Pointer);

    property SSLCtx: Pointer read FSSLCtx;
    property SSLEnabled: Boolean read FSSLEnabled;
    property MinTLSVersion: Integer read FMinTLSVersion write FMinTLSVersion;
    property SSLProvider: ISSLProvider read FSSLProvider;
    property CertCtxByHost: TDictionary<string, Pointer> read FCertCtxByHost;
  end;

// SNI callback — used as SSL_CTX callback. AArg = TSSLManager instance.
function SSLManagerSNICallback(ASSL: Pointer; AD: PInteger; AArg: Pointer): Integer; cdecl;

implementation

function SSLManagerSNICallback(ASSL: Pointer; AD: PInteger; AArg: Pointer): Integer; cdecl;
var
  LMgr: TSSLManager;
  LHost: string;
  LCtx: Pointer;
begin
  Result := SSL_TLSEXT_ERR_NOACK;
  if AArg = nil then Exit;
  LMgr := TSSLManager(AArg);
  if LMgr.FCertCtxByHost = nil then Exit;
  LHost := LowerCase(LMgr.FSSLProvider.GetServername(ASSL));
  if LHost = '' then Exit;
  if LMgr.FCertCtxByHost.TryGetValue(LHost, LCtx) and (LCtx <> nil) then
  begin
    LMgr.FSSLProvider.SetCTXOnSSL(ASSL, LCtx);
    Result := SSL_TLSEXT_ERR_OK;
  end;
end;

constructor TSSLManager.Create(ASSLProvider: ISSLProvider);
begin
  inherited Create;
  FSSLProvider := ASSLProvider;
  FSSLCtx := nil;
  FCertCtxByHost := nil;
  FSSLEnabled := False;
  FMinTLSVersion := $0303;  // TLS 1.2
  FH2Enabled := False;
  FServerRef := nil;
  FCAFile := '';
end;

destructor TSSLManager.Destroy;
var
  LPair: TPair<string, Pointer>;
begin
  if FCertCtxByHost <> nil then
  begin
    for LPair in FCertCtxByHost do
      if LPair.Value <> nil then FSSLProvider.FreeContext(LPair.Value);
    FreeAndNil(FCertCtxByHost);
  end;
  if FSSLCtx <> nil then
  begin
    FSSLProvider.FreeContext(FSSLCtx);
    FSSLCtx := nil;
  end;
  inherited Destroy;
end;

procedure TSSLManager.ConfigureSSL(const ACertFile, AKeyFile: string;
  AH2Enabled: Boolean; AServerRef: Pointer);
begin
  if FSSLCtx <> nil then
  begin
    FSSLProvider.FreeContext(FSSLCtx);
    FSSLCtx := nil;
  end;
  FSSLProvider.EnsureLoaded;
  FSSLCtx := FSSLProvider.NewContext;
  FSSLProvider.LoadCert(FSSLCtx, ACertFile);
  FSSLProvider.LoadKey(FSSLCtx, AKeyFile);
  FSSLProvider.VerifyKey(FSSLCtx);
  FSSLProvider.SetMinVersion(FSSLCtx, FMinTLSVersion);
  FSSLProvider.EnableSessionCache(FSSLCtx);
  // SNI callback — uses Self (TSSLManager) as arg
  FSSLProvider.SetSNICallback(FSSLCtx, @SSLManagerSNICallback, Self);
  if AH2Enabled then
    FSSLProvider.SetALPN(FSSLCtx, AServerRef);
  // Remember for per-host SNI contexts (AddSSLCert replicates this setup).
  FH2Enabled := AH2Enabled;
  FServerRef := AServerRef;
  FSSLEnabled := True;
end;

procedure TSSLManager.ConfigureMTLS(const ACAFile: string);
var
  LPair: TPair<string, Pointer>;
begin
  if FSSLCtx = nil then
    raise Exception.Create('Call ConfigureSSL before ConfigureMTLS');
  FCAFile := ACAFile;
  FSSLProvider.ConfigureMTLS(FSSLCtx, ACAFile);
  // #M7: apply the same client-cert verification to every per-host SNI context
  // already registered (handles ConfigureMTLS being called after AddSSLCert).
  // Without this the switched per-host ctx has an empty store and SNI + mTLS
  // handshakes are rejected.
  if FCertCtxByHost <> nil then
    for LPair in FCertCtxByHost do
      if LPair.Value <> nil then
        FSSLProvider.ConfigureMTLS(LPair.Value, ACAFile);
end;

procedure TSSLManager.AddSSLCert(const AHostName, ACertFile, AKeyFile: string);
var
  LCtx: Pointer;
begin
  if FSSLCtx = nil then
    raise Exception.Create('Call ConfigureSSL first to set the default certificate');
  if FCertCtxByHost = nil then
    FCertCtxByHost := TDictionary<string, Pointer>.Create;

  FSSLProvider.EnsureLoaded;
  LCtx := FSSLProvider.NewContext;
  try
    FSSLProvider.LoadCert(LCtx, ACertFile);
    FSSLProvider.LoadKey(LCtx, AKeyFile);
    FSSLProvider.VerifyKey(LCtx);
    // #M8/#M7: replicate the default context's protocol setup — otherwise an
    // SNI-matched host silently loses ALPN (h2 -> HTTP/1.1 downgrade), the TLS
    // floor, and mTLS client-cert verification.
    FSSLProvider.SetMinVersion(LCtx, FMinTLSVersion);
    if FH2Enabled then
      FSSLProvider.SetALPN(LCtx, FServerRef);
    if FCAFile <> '' then
      FSSLProvider.ConfigureMTLS(LCtx, FCAFile);
  except
    FSSLProvider.FreeContext(LCtx);
    raise;
  end;

  if FCertCtxByHost.ContainsKey(LowerCase(AHostName)) then
    FSSLProvider.FreeContext(FCertCtxByHost[LowerCase(AHostName)]);
  FCertCtxByHost.AddOrSetValue(LowerCase(AHostName), LCtx);
end;

function TSSLManager.NewSSL: Pointer;
begin
  Result := FSSLProvider.NewSSL(FSSLCtx);
end;

procedure TSSLManager.FreeSSL(AHandle: Pointer);
begin
  FSSLProvider.FreeSSL(AHandle);
end;

procedure TSSLManager.SetupServerBIOs(AHandle: Pointer;
  out AReadBio, AWriteBio: Pointer);
begin
  FSSLProvider.SetupServerBIOs(AHandle, AReadBio, AWriteBio);
end;

end.
