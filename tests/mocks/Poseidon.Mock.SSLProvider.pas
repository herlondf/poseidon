unit Poseidon.Mock.SSLProvider;

// TSpySSLProvider — test double for ISSLProvider (#25).
//
// Records every method call and exposes them via CallLog: TArray<string>.
// Key configurable fields control return values so tests can exercise
// specific server behaviours without a real OpenSSL library.
//
// Usage:
//   var LSpy := TSpySSLProvider.Create;
//   LSpy.HandshakeResult := 1;          // 1 = success, -1 = error
//   LSpy.HandshakeErrorCode := 0;       // SSL_ERROR_NONE
//   var LServer := TPoseidonNativeServer.Create(nil, LSpy, nil);
//   LServer.ConfigureSSL('cert.crt', 'cert.key');  // calls recorded
//   Assert.Contains(LSpy.CallLog, 'EnsureLoaded');
//
// Pointer tokens: every allocation returns a small unique integer cast
// to Pointer so callers can verify they receive what they passed in.

interface

uses
  System.SysUtils,
  System.Math,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.Interfaces;

type
  TSpySSLProvider = class(TInterfacedObject, ISSLProvider)
  private
    FLog:              TList<string>;
    FNextPtr:          NativeUInt;   // monotonically increasing fake pointer
    function _Alloc(const AName: string): Pointer;
    procedure _Log(const AMsg: string);
  public
    // -----------------------------------------------------------------------
    // Configurable return values
    // -----------------------------------------------------------------------
    Available:          Boolean;       // IsAvailable result (default True)
    HandshakeResult:    Integer;       // DoHandshake return (default 1 = done)
    HandshakeError:     Integer;       // GetError return when handshake fails
    // When HandshakeResult < 0 and NeedIOCount > 0, DoHandshake returns -1 for
    // the first NeedIOCount calls, then returns 1 on the next call.
    NeedIOCount:        Integer;
    SelectedProtocol:   string;        // GetSelectedProtocol result (default '')
    Servername:         string;        // GetServername result (default '')
    SSLReadData:        TBytes;        // data returned by SSLRead

    constructor Create;
    destructor  Destroy; override;

    // -----------------------------------------------------------------------
    // Inspection
    // -----------------------------------------------------------------------
    function CallLog: TArray<string>;
    function WasCalled(const AMethod: string): Boolean;
    procedure ClearLog;

    // -----------------------------------------------------------------------
    // ISSLProvider
    // -----------------------------------------------------------------------
    function  IsAvailable: Boolean;
    procedure EnsureLoaded;
    function  NewContext: Pointer;
    procedure FreeContext(ACtx: Pointer);
    procedure LoadCert(ACtx: Pointer; const AFile: string);
    procedure LoadKey(ACtx: Pointer; const AFile: string);
    procedure VerifyKey(ACtx: Pointer);
    procedure SetMinVersion(ACtx: Pointer; AVersion: Integer);
    procedure EnableSessionCache(ACtx: Pointer);
    procedure SetSNICallback(ACtx: Pointer; ACallback: Pointer; AArg: Pointer);
    procedure SetALPN(ACtx: Pointer; AServer: TObject);
    procedure ConfigureMTLS(ACtx: Pointer; const ACAFile: string);
    procedure SetCTXOnSSL(ASSL: Pointer; ACtx: Pointer);
    function  NewSSL(ACtx: Pointer): Pointer;
    procedure SetupServerBIOs(ASSL: Pointer; out AReadBIO, AWriteBIO: Pointer);
    procedure FreeSSL(ASSL: Pointer);
    function  GetSelectedProtocol(ASSL: Pointer): string;
    function  BIOPending(ABIO: Pointer): Integer;
    function  BIORead(ABIO: Pointer; ABuf: Pointer; ALen: Integer): Integer;
    function  BIOWrite(ABIO: Pointer; ABuf: Pointer; ALen: Integer): Integer;
    function  SSLRead(ASSL: Pointer; ABuf: Pointer; ALen: Integer): Integer;
    function  SSLWrite(ASSL: Pointer; const ABuf: Pointer; ALen: Integer): Integer;
    function  DoHandshake(ASSL: Pointer): Integer;
    function  GetError(ASSL: Pointer; AResult: Integer): Integer;
    function  GetServername(ASSL: Pointer): string;
  end;

implementation

{ TSpySSLProvider }

constructor TSpySSLProvider.Create;
begin
  inherited Create;
  FLog             := TList<string>.Create;
  FNextPtr         := $A000;   // arbitrary non-nil base
  Available        := True;
  HandshakeResult  := 1;       // immediate success
  HandshakeError   := 0;       // SSL_ERROR_NONE
  NeedIOCount      := 0;
  SelectedProtocol := '';
  Servername       := '';
end;

destructor TSpySSLProvider.Destroy;
begin
  FLog.Free;
  inherited Destroy;
end;

function TSpySSLProvider._Alloc(const AName: string): Pointer;
begin
  Inc(FNextPtr);
  _Log(AName + '=' + IntToHex(FNextPtr, 8));
  Result := Pointer(FNextPtr);
end;

procedure TSpySSLProvider._Log(const AMsg: string);
begin
  FLog.Add(AMsg);
end;

function TSpySSLProvider.CallLog: TArray<string>;
begin
  Result := FLog.ToArray;
end;

function TSpySSLProvider.WasCalled(const AMethod: string): Boolean;
var
  LEntry: string;
begin
  for LEntry in FLog do
    if LEntry.StartsWith(AMethod) then Exit(True);
  Result := False;
end;

procedure TSpySSLProvider.ClearLog;
begin
  FLog.Clear;
end;

// -----------------------------------------------------------------------
// ISSLProvider implementation
// -----------------------------------------------------------------------

function TSpySSLProvider.IsAvailable: Boolean;
begin
  _Log('IsAvailable');
  Result := Available;
end;

procedure TSpySSLProvider.EnsureLoaded;
begin
  _Log('EnsureLoaded');
  if not Available then
    raise Exception.Create('FakeSSL: not available');
end;

function TSpySSLProvider.NewContext: Pointer;
begin
  Result := _Alloc('NewContext');
end;

procedure TSpySSLProvider.FreeContext(ACtx: Pointer);
begin
  _Log('FreeContext(' + IntToHex(NativeUInt(ACtx), 8) + ')');
end;

procedure TSpySSLProvider.LoadCert(ACtx: Pointer; const AFile: string);
begin
  _Log('LoadCert(' + AFile + ')');
end;

procedure TSpySSLProvider.LoadKey(ACtx: Pointer; const AFile: string);
begin
  _Log('LoadKey(' + AFile + ')');
end;

procedure TSpySSLProvider.VerifyKey(ACtx: Pointer);
begin
  _Log('VerifyKey');
end;

procedure TSpySSLProvider.SetMinVersion(ACtx: Pointer; AVersion: Integer);
begin
  _Log('SetMinVersion(' + IntToStr(AVersion) + ')');
end;

procedure TSpySSLProvider.EnableSessionCache(ACtx: Pointer);
begin
  _Log('EnableSessionCache');
end;

procedure TSpySSLProvider.SetSNICallback(ACtx: Pointer; ACallback: Pointer;
  AArg: Pointer);
begin
  _Log('SetSNICallback');
end;

procedure TSpySSLProvider.SetALPN(ACtx: Pointer; AServer: TObject);
begin
  _Log('SetALPN');
end;

procedure TSpySSLProvider.ConfigureMTLS(ACtx: Pointer; const ACAFile: string);
begin
  _Log('ConfigureMTLS(' + ACAFile + ')');
end;

procedure TSpySSLProvider.SetCTXOnSSL(ASSL: Pointer; ACtx: Pointer);
begin
  _Log('SetCTXOnSSL');
end;

function TSpySSLProvider.NewSSL(ACtx: Pointer): Pointer;
begin
  Result := _Alloc('NewSSL');
end;

procedure TSpySSLProvider.SetupServerBIOs(ASSL: Pointer;
  out AReadBIO, AWriteBIO: Pointer);
begin
  AReadBIO  := _Alloc('SetupServerBIOs.ReadBIO');
  AWriteBIO := _Alloc('SetupServerBIOs.WriteBIO');
end;

procedure TSpySSLProvider.FreeSSL(ASSL: Pointer);
begin
  _Log('FreeSSL(' + IntToHex(NativeUInt(ASSL), 8) + ')');
end;

function TSpySSLProvider.GetSelectedProtocol(ASSL: Pointer): string;
begin
  _Log('GetSelectedProtocol');
  Result := SelectedProtocol;
end;

function TSpySSLProvider.BIOPending(ABIO: Pointer): Integer;
begin
  _Log('BIOPending');
  Result := 0;  // no outgoing data in stub
end;

function TSpySSLProvider.BIORead(ABIO: Pointer; ABuf: Pointer;
  ALen: Integer): Integer;
begin
  _Log('BIORead');
  Result := 0;
end;

function TSpySSLProvider.BIOWrite(ABIO: Pointer; ABuf: Pointer;
  ALen: Integer): Integer;
begin
  _Log('BIOWrite(' + IntToStr(ALen) + ')');
  Result := ALen;  // consume all bytes
end;

function TSpySSLProvider.SSLRead(ASSL: Pointer; ABuf: Pointer;
  ALen: Integer): Integer;
var
  LCopy: Integer;
begin
  _Log('SSLRead');
  if Length(SSLReadData) = 0 then
  begin
    Result := -1;   // no data — simulate SSL_ERROR_WANT_READ
    Exit;
  end;
  LCopy := Min(ALen, Length(SSLReadData));
  Move(SSLReadData[0], ABuf^, LCopy);
  Result := LCopy;
  SSLReadData := Copy(SSLReadData, LCopy, MaxInt);
end;

function TSpySSLProvider.SSLWrite(ASSL: Pointer; const ABuf: Pointer;
  ALen: Integer): Integer;
begin
  _Log('SSLWrite(' + IntToStr(ALen) + ')');
  Result := ALen;  // pretend all bytes were written
end;

function TSpySSLProvider.DoHandshake(ASSL: Pointer): Integer;
begin
  if NeedIOCount > 0 then
  begin
    Dec(NeedIOCount);
    _Log('DoHandshake=WANT_IO');
    Result := -1;  // SSL_ERROR_WANT_READ / WANT_WRITE
  end
  else
  begin
    _Log('DoHandshake=OK');
    Result := HandshakeResult;
  end;
end;

function TSpySSLProvider.GetError(ASSL: Pointer; AResult: Integer): Integer;
begin
  _Log('GetError(' + IntToStr(AResult) + ')');
  Result := HandshakeError;
end;

function TSpySSLProvider.GetServername(ASSL: Pointer): string;
begin
  _Log('GetServername');
  Result := Servername;
end;

end.
