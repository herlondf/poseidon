unit Poseidon.Net.Interfaces;

// R-6: Dependency-Inversion contracts for TPoseidonNativeServer.
//
// Defines two injectable interfaces that decouple the server from its
// concrete dependencies. Each interface has a default implementation backed
// by the real class; passing nil to the server constructor selects the default.
//
// Interfaces:
//   IBufferPool   — acquire/release pooled TBytes buffers
//   ISSLProvider  — create/configure SSL_CTX and SSL objects
//
// Default implementations (returned by Default* functions):
//   TDefaultBufferPool   — wraps TBufferPool class methods
//   TDefaultSSLProvider  — wraps TPoseidonSSL class methods

interface

uses
  System.SysUtils,
  Poseidon.Net.Types;

type
  // -----------------------------------------------------------------------
  // IBufferPool — acquire / release memory-pooled byte arrays
  // -----------------------------------------------------------------------
  IBufferPool = interface
    ['{A1B2C3D4-E5F6-4A5B-8C9D-0E1F2A3B4C5D}']
    function  Acquire(ASize: Integer = 0): TBytes;
    procedure Release(var ABuf: TBytes);
  end;

  // -----------------------------------------------------------------------
  // ISSLProvider — SSL_CTX and SSL object lifecycle / configuration
  // -----------------------------------------------------------------------
  ISSLProvider = interface
    ['{C3D4E5F6-A7B8-4C5D-0E1F-2A3B4C5D6E7F}']
    // Returns True when OpenSSL shared libraries are loaded and usable.
    function  IsAvailable: Boolean;

    // Ensure the library is loaded; raises if unavailable.
    procedure EnsureLoaded;

    // SSL_CTX lifecycle
    function  NewContext: Pointer;                    // SSL_CTX_new
    procedure FreeContext(ACtx: Pointer);             // SSL_CTX_free

    // Certificate / key loading
    procedure LoadCert(ACtx: Pointer; const AFile: string);
    procedure LoadKey(ACtx: Pointer; const AFile: string);
    procedure VerifyKey(ACtx: Pointer);

    // Protocol settings
    procedure SetMinVersion(ACtx: Pointer; AVersion: Integer);
    procedure EnableSessionCache(ACtx: Pointer);

    // SNI + ALPN
    procedure SetSNICallback(ACtx: Pointer; ACallback: Pointer; AArg: Pointer);
    procedure SetALPN(ACtx: Pointer; AServer: TObject);
    procedure ConfigureMTLS(ACtx: Pointer; const ACAFile: string);
    procedure SetCTXOnSSL(ASSL: Pointer; ACtx: Pointer); // SSL_set_SSL_CTX (SNI switch)

    // SSL object lifecycle
    function  NewSSL(ACtx: Pointer): Pointer;            // SSL_new
    procedure SetupServerBIOs(ASSL: Pointer; out AReadBIO, AWriteBIO: Pointer);
    procedure FreeSSL(ASSL: Pointer);                    // SSL_free
    function  GetSelectedProtocol(ASSL: Pointer): string; // ALPN

    // BIO I/O
    function  BIOPending(ABIO: Pointer): Integer;
    function  BIORead(ABIO: Pointer; ABuf: Pointer; ALen: Integer): Integer;
    function  BIOWrite(ABIO: Pointer; ABuf: Pointer; ALen: Integer): Integer;

    // SSL I/O
    function  SSLRead(ASSL: Pointer; ABuf: Pointer; ALen: Integer): Integer;
    function  SSLWrite(ASSL: Pointer; const ABuf: Pointer; ALen: Integer): Integer;

    // Handshake
    function  DoHandshake(ASSL: Pointer): Integer;
    function  GetError(ASSL: Pointer; AResult: Integer): Integer;

    // SNI helper
    function  GetServername(ASSL: Pointer): string;
  end;

// ---------------------------------------------------------------------------
// Default-implementation factory functions (singletons)
// ---------------------------------------------------------------------------

function DefaultBufferPool: IBufferPool;
function DefaultSSLProvider: ISSLProvider;

implementation

uses
  System.Classes,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.SSL;

// ===========================================================================
// TDefaultBufferPool
// ===========================================================================

type
  TDefaultBufferPool = class(TInterfacedObject, IBufferPool)
  public
    function  Acquire(ASize: Integer = 0): TBytes;
    procedure Release(var ABuf: TBytes);
  end;

function TDefaultBufferPool.Acquire(ASize: Integer): TBytes;
begin
  Result := TBufferPool.Acquire(ASize);
end;

procedure TDefaultBufferPool.Release(var ABuf: TBytes);
begin
  TBufferPool.Release(ABuf);
end;

// ===========================================================================
// TDefaultSSLProvider
// ===========================================================================

type
  TDefaultSSLProvider = class(TInterfacedObject, ISSLProvider)
  public
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

function TDefaultSSLProvider.IsAvailable: Boolean;
begin
  Result := TPoseidonSSL.IsAvailable;
end;

procedure TDefaultSSLProvider.EnsureLoaded;
begin
  TPoseidonSSL.EnsureLoaded;
end;

function TDefaultSSLProvider.NewContext: Pointer;
begin
  Result := TPoseidonSSL.CTX_New;
end;

procedure TDefaultSSLProvider.FreeContext(ACtx: Pointer);
begin
  TPoseidonSSL.CTX_Free(ACtx);
end;

procedure TDefaultSSLProvider.LoadCert(ACtx: Pointer; const AFile: string);
begin
  TPoseidonSSL.CTX_LoadCert(ACtx, AFile);
end;

procedure TDefaultSSLProvider.LoadKey(ACtx: Pointer; const AFile: string);
begin
  TPoseidonSSL.CTX_LoadKey(ACtx, AFile);
end;

procedure TDefaultSSLProvider.VerifyKey(ACtx: Pointer);
begin
  TPoseidonSSL.CTX_VerifyKey(ACtx);
end;

procedure TDefaultSSLProvider.SetMinVersion(ACtx: Pointer; AVersion: Integer);
begin
  TPoseidonSSL.CTX_SetMinVersion(ACtx, AVersion);
end;

procedure TDefaultSSLProvider.EnableSessionCache(ACtx: Pointer);
begin
  TPoseidonSSL.CTX_EnableSessionCache(ACtx);
end;

procedure TDefaultSSLProvider.SetSNICallback(ACtx: Pointer;
  ACallback: Pointer; AArg: Pointer);
begin
  TPoseidonSSL.CTX_SetSNICallback(ACtx, ACallback, AArg);
end;

procedure TDefaultSSLProvider.SetALPN(ACtx: Pointer; AServer: TObject);
begin
  TPoseidonSSL.CTX_SetALPN(ACtx, AServer);
end;

procedure TDefaultSSLProvider.ConfigureMTLS(ACtx: Pointer;
  const ACAFile: string);
begin
  TPoseidonSSL.CTX_ConfigureMTLS(ACtx, ACAFile);
end;

procedure TDefaultSSLProvider.SetCTXOnSSL(ASSL: Pointer; ACtx: Pointer);
begin
  TPoseidonSSL.SSL_SetCTX(ASSL, ACtx);
end;

function TDefaultSSLProvider.NewSSL(ACtx: Pointer): Pointer;
begin
  Result := TPoseidonSSL.New_SSL(ACtx);
end;

procedure TDefaultSSLProvider.SetupServerBIOs(ASSL: Pointer;
  out AReadBIO, AWriteBIO: Pointer);
begin
  TPoseidonSSL.Setup_Server(ASSL, AReadBIO, AWriteBIO);
end;

procedure TDefaultSSLProvider.FreeSSL(ASSL: Pointer);
begin
  TPoseidonSSL.Free_SSL(ASSL);
end;

function TDefaultSSLProvider.GetSelectedProtocol(ASSL: Pointer): string;
begin
  Result := TPoseidonSSL.SSL_GetSelectedProtocol(ASSL);
end;

function TDefaultSSLProvider.BIOPending(ABIO: Pointer): Integer;
begin
  Result := TPoseidonSSL.BIO_Pending(ABIO);
end;

function TDefaultSSLProvider.BIORead(ABIO: Pointer; ABuf: Pointer;
  ALen: Integer): Integer;
begin
  Result := TPoseidonSSL.BIO_Read(ABIO, ABuf, ALen);
end;

function TDefaultSSLProvider.BIOWrite(ABIO: Pointer; ABuf: Pointer;
  ALen: Integer): Integer;
begin
  Result := TPoseidonSSL.BIO_Write(ABIO, ABuf, ALen);
end;

function TDefaultSSLProvider.SSLRead(ASSL: Pointer; ABuf: Pointer;
  ALen: Integer): Integer;
begin
  Result := TPoseidonSSL.SSL_Read(ASSL, ABuf, ALen);
end;

function TDefaultSSLProvider.SSLWrite(ASSL: Pointer; const ABuf: Pointer;
  ALen: Integer): Integer;
begin
  Result := TPoseidonSSL.SSL_Write(ASSL, ABuf, ALen);
end;

function TDefaultSSLProvider.DoHandshake(ASSL: Pointer): Integer;
begin
  Result := TPoseidonSSL.Do_Handshake(ASSL);
end;

function TDefaultSSLProvider.GetError(ASSL: Pointer; AResult: Integer): Integer;
begin
  Result := TPoseidonSSL.Get_Error(ASSL, AResult);
end;

function TDefaultSSLProvider.GetServername(ASSL: Pointer): string;
begin
  Result := TPoseidonSSL.SSL_GetServername(ASSL);
end;

// ===========================================================================
// Singleton factories (lazy-init, not thread-safe at init time — acceptable
// since the first call is typically from the main thread at server startup)
// ===========================================================================

var
  GBufferPool:  IBufferPool;
  GSSLProvider: ISSLProvider;

function DefaultBufferPool: IBufferPool;
begin
  if GBufferPool = nil then
    GBufferPool := TDefaultBufferPool.Create;
  Result := GBufferPool;
end;

function DefaultSSLProvider: ISSLProvider;
begin
  if GSSLProvider = nil then
    GSSLProvider := TDefaultSSLProvider.Create;
  Result := GSSLProvider;
end;

initialization
  GBufferPool  := nil;
  GSSLProvider := nil;

finalization
  GBufferPool  := nil;
  GSSLProvider := nil;

end.
