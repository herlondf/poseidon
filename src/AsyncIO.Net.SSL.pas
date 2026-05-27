unit AsyncIO.Net.SSL;

// Lazy OpenSSL DLL wrapper for AsyncIO Native provider.
// Loads libssl + libcrypto on first ConfigureSSL call (no compile-time dependency).
// Uses memory BIOs so IOCP/epoll recv/send remain async.

interface

uses
  System.SysUtils,
  System.SyncObjs;

const
  SSL_ERROR_NONE        = 0;
  SSL_ERROR_SSL         = 1;
  SSL_ERROR_WANT_READ   = 2;
  SSL_ERROR_WANT_WRITE  = 3;
  SSL_ERROR_SYSCALL     = 5;
  SSL_ERROR_ZERO_RETURN = 6;
  SSL_FILETYPE_PEM      = 1;
  BIO_CTRL_PENDING      = 10;

  // SNI (Server Name Indication)
  SSL_CTRL_SET_TLSEXT_SERVERNAME_CB  = 53;
  SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG = 54;
  TLSEXT_NAMETYPE_host_name          = 0;
  SSL_TLSEXT_ERR_OK                  = 0;
  SSL_TLSEXT_ERR_ALERT_WARNING       = 1;
  SSL_TLSEXT_ERR_ALERT_FATAL         = 2;
  SSL_TLSEXT_ERR_NOACK               = 3;

type
  EAsyncIOSSL = class(Exception);

  TFn_method      = function: Pointer; cdecl;
  TFn_ctx_new     = function(meth: Pointer): Pointer; cdecl;
  TFn_ctx_free    = procedure(ctx: Pointer); cdecl;
  TFn_ctx_file    = function(ctx: Pointer; const f: PAnsiChar; t: Integer): Integer; cdecl;
  TFn_ctx_chkkey  = function(ctx: Pointer): Integer; cdecl;
  TFn_ssl_new     = function(ctx: Pointer): Pointer; cdecl;
  TFn_ssl_free    = procedure(ssl: Pointer); cdecl;
  TFn_ssl_state   = procedure(ssl: Pointer); cdecl;
  TFn_ssl_hands   = function(ssl: Pointer): Integer; cdecl;
  TFn_ssl_rw      = function(ssl, buf: Pointer; num: Integer): Integer; cdecl;
  TFn_ssl_err     = function(ssl: Pointer; ret: Integer): Integer; cdecl;
  TFn_ssl_pend    = function(ssl: Pointer): Integer; cdecl;
  TFn_ssl_setbio  = procedure(ssl, rbio, wbio: Pointer); cdecl;
  TFn_bio_smem    = function: Pointer; cdecl;
  TFn_bio_new     = function(t: Pointer): Pointer; cdecl;
  TFn_bio_rw      = function(bio, data: Pointer; dlen: Integer): Integer; cdecl;
  TFn_bio_ctrl    = function(bio: Pointer; cmd, larg: Integer; parg: Pointer): Integer; cdecl;
  TFn_ctx_ctrl    = function(ctx: Pointer; cmd: Integer; larg: NativeInt; parg: Pointer): NativeInt; cdecl;
  TFn_ctx_cbctrl  = function(ctx: Pointer; cmd: Integer; cb: Pointer): NativeInt; cdecl;
  TFn_ssl_getname = function(ssl: Pointer; nametype: Integer): PAnsiChar; cdecl;
  TFn_ssl_setctx  = function(ssl, ctx: Pointer): Pointer; cdecl;
  TFn_err_get         = function: NativeUInt; cdecl;
  TFn_err_str         = function(e: NativeUInt; buf: PAnsiChar): PAnsiChar; cdecl;
  TFn_ctx_alpn_cb     = procedure(ctx: Pointer; cb: Pointer; arg: Pointer); cdecl;
  TFn_ssl_get0_alpn   = procedure(ssl: Pointer; dataptr: Pointer; lenptr: Pointer); cdecl;

  TAsyncIOLibHandle = NativeUInt;

  TAsyncIOSSL = class
  private
    class var FLock:      TCriticalSection;
    class var FLoaded:    Boolean;
    class var FLibSSL:    TAsyncIOLibHandle;
    class var FLibCrypto: TAsyncIOLibHandle;

    class var f_TLS_server_method:            TFn_method;
    class var f_SSL_CTX_new:                  TFn_ctx_new;
    class var f_SSL_CTX_free:                 TFn_ctx_free;
    class var f_SSL_CTX_use_certificate_file: TFn_ctx_file;
    class var f_SSL_CTX_use_PrivateKey_file:  TFn_ctx_file;
    class var f_SSL_CTX_check_private_key:    TFn_ctx_chkkey;
    class var f_SSL_new:                      TFn_ssl_new;
    class var f_SSL_free:                     TFn_ssl_free;
    class var f_SSL_set_accept_state:         TFn_ssl_state;
    class var f_SSL_do_handshake:             TFn_ssl_hands;
    class var f_SSL_read:                     TFn_ssl_rw;
    class var f_SSL_write:                    TFn_ssl_rw;
    class var f_SSL_get_error:                TFn_ssl_err;
    class var f_SSL_pending:                  TFn_ssl_pend;
    class var f_SSL_set_bio:                  TFn_ssl_setbio;
    class var f_BIO_s_mem:                    TFn_bio_smem;
    class var f_BIO_new:                      TFn_bio_new;
    class var f_BIO_write:                    TFn_bio_rw;
    class var f_BIO_read:                     TFn_bio_rw;
    class var f_BIO_ctrl:                     TFn_bio_ctrl;
    class var f_SSL_CTX_ctrl:                 TFn_ctx_ctrl;
    class var f_SSL_CTX_callback_ctrl:        TFn_ctx_cbctrl;
    class var f_SSL_get_servername:           TFn_ssl_getname;
    class var f_SSL_set_SSL_CTX:              TFn_ssl_setctx;
    class var f_ERR_get_error:                TFn_err_get;
    class var f_ERR_error_string:             TFn_err_str;
    class var f_SSL_CTX_set_alpn_select_cb:   TFn_ctx_alpn_cb;
    class var f_SSL_get0_alpn_selected:       TFn_ssl_get0_alpn;

    class function  TryLoadLib(const AName: string): TAsyncIOLibHandle;
    class function  RequireProc(ALib: TAsyncIOLibHandle; const AName: string): Pointer;
    class procedure DoLoad;
    class constructor Create;
    class destructor  Destroy;
  public
    class procedure EnsureLoaded;
    class function  IsAvailable: Boolean;
    class function  LastError: string;

    class function  CTX_New: Pointer;
    class procedure CTX_Free(ACtx: Pointer);
    class procedure CTX_LoadCert(ACtx: Pointer; const AFile: string);
    class procedure CTX_LoadKey(ACtx: Pointer; const AFile: string);
    class procedure CTX_VerifyKey(ACtx: Pointer);

    class function  New_SSL(ACtx: Pointer): Pointer;
    class procedure Setup_Server(ASSL: Pointer; out AReadBIO, AWriteBIO: Pointer);
    class procedure Free_SSL(ASSL: Pointer);

    class function  Do_Handshake(ASSL: Pointer): Integer; inline;
    class function  Get_Error(ASSL: Pointer; ARet: Integer): Integer; inline;
    class function  SSL_Read(ASSL, ABuf: Pointer; ALen: Integer): Integer; inline;
    class function  SSL_Write(ASSL: Pointer; const ABuf: Pointer; ALen: Integer): Integer; inline;
    class function  SSL_Pending(ASSL: Pointer): Integer; inline;
    class function  BIO_Write(ABIO, ABuf: Pointer; ALen: Integer): Integer; inline;
    class function  BIO_Read(ABIO, ABuf: Pointer; ALen: Integer): Integer; inline;
    class function  BIO_Pending(ABIO: Pointer): Integer; inline;

    // SNI (Server Name Indication) — multi-cert support
    class procedure CTX_SetSNICallback(ACtx, ACallback, AArg: Pointer); static;
    class function  SSL_GetServername(ASSL: Pointer): string; static;
    class procedure SSL_SetCTX(ASSL, ACtx: Pointer); static;

    // ALPN — HTTP/2 protocol negotiation (OpenSSL 1.0.2+)
    class procedure CTX_SetALPN(ACtx: Pointer; AArg: Pointer); static;
    class function  SSL_GetSelectedProtocol(ASSL: Pointer): string; static;
  end;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows;
{$ELSE}
  Posix.Dlfcn;
{$ENDIF}

class constructor TAsyncIOSSL.Create;
begin
  FLock      := TCriticalSection.Create;
  FLoaded    := False;
  FLibSSL    := 0;
  FLibCrypto := 0;
end;

class destructor TAsyncIOSSL.Destroy;
begin
  FLoaded := False;
{$IFDEF MSWINDOWS}
  if FLibSSL <> 0    then FreeLibrary(FLibSSL);
  if FLibCrypto <> 0 then FreeLibrary(FLibCrypto);
{$ELSE}
  if FLibSSL <> 0    then dlclose(FLibSSL);
  if FLibCrypto <> 0 then dlclose(FLibCrypto);
{$ENDIF}
  FLock.Free;
end;

class function TAsyncIOSSL.TryLoadLib(const AName: string): TAsyncIOLibHandle;
begin
{$IFDEF MSWINDOWS}
  Result := LoadLibrary(PChar(AName));
{$ELSE}
  Result := dlopen(MarshaledAString(AnsiString(AName)), RTLD_LAZY or RTLD_GLOBAL);
{$ENDIF}
end;

class function TAsyncIOSSL.RequireProc(ALib: TAsyncIOLibHandle;
  const AName: string): Pointer;
begin
{$IFDEF MSWINDOWS}
  Result := GetProcAddress(ALib, PChar(AName));
{$ELSE}
  Result := dlsym(ALib, MarshaledAString(AnsiString(AName)));
{$ENDIF}
  if Result = nil then
    raise EAsyncIOSSL.CreateFmt('OpenSSL: missing symbol "%s"', [AName]);
end;

class procedure TAsyncIOSSL.DoLoad;
var
  LInit: procedure; cdecl;
begin
{$IFDEF MSWINDOWS}
  FLibSSL := TryLoadLib('libssl-3-x64.dll');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl-3.dll');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl-1_1-x64.dll');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl.dll');
  if FLibSSL = 0 then
    raise EAsyncIOSSL.Create(
      'OpenSSL libssl not found. Install OpenSSL 3.x or 1.1.x and ensure DLLs are in PATH.');

  FLibCrypto := TryLoadLib('libcrypto-3-x64.dll');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto-3.dll');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto-1_1-x64.dll');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto.dll');
  if FLibCrypto = 0 then
    raise EAsyncIOSSL.Create('OpenSSL libcrypto not found.');
{$ELSE}
  FLibSSL := TryLoadLib('libssl.so.3');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl.so.1.1');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl.so');
  if FLibSSL = 0 then
    raise EAsyncIOSSL.Create(
      'OpenSSL libssl not found. Install libssl-dev (apt install libssl-dev).');

  FLibCrypto := TryLoadLib('libcrypto.so.3');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto.so.1.1');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto.so');
  if FLibCrypto = 0 then
    raise EAsyncIOSSL.Create('OpenSSL libcrypto not found.');
{$ENDIF}

{$IFDEF MSWINDOWS}
  @LInit := GetProcAddress(FLibSSL, 'SSL_library_init');
{$ELSE}
  @LInit := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_library_init')));
{$ENDIF}
  if @LInit <> nil then LInit;

  @f_TLS_server_method             := RequireProc(FLibSSL, 'TLS_server_method');
  @f_SSL_CTX_new                   := RequireProc(FLibSSL, 'SSL_CTX_new');
  @f_SSL_CTX_free                  := RequireProc(FLibSSL, 'SSL_CTX_free');
  @f_SSL_CTX_use_certificate_file  := RequireProc(FLibSSL, 'SSL_CTX_use_certificate_file');
  @f_SSL_CTX_use_PrivateKey_file   := RequireProc(FLibSSL, 'SSL_CTX_use_PrivateKey_file');
  @f_SSL_CTX_check_private_key     := RequireProc(FLibSSL, 'SSL_CTX_check_private_key');
  @f_SSL_new                       := RequireProc(FLibSSL, 'SSL_new');
  @f_SSL_free                      := RequireProc(FLibSSL, 'SSL_free');
  @f_SSL_set_accept_state          := RequireProc(FLibSSL, 'SSL_set_accept_state');
  @f_SSL_do_handshake              := RequireProc(FLibSSL, 'SSL_do_handshake');
  @f_SSL_read                      := RequireProc(FLibSSL, 'SSL_read');
  @f_SSL_write                     := RequireProc(FLibSSL, 'SSL_write');
  @f_SSL_get_error                 := RequireProc(FLibSSL, 'SSL_get_error');
  @f_SSL_pending                   := RequireProc(FLibSSL, 'SSL_pending');
  @f_SSL_set_bio                   := RequireProc(FLibSSL, 'SSL_set_bio');
  @f_BIO_s_mem                     := RequireProc(FLibCrypto, 'BIO_s_mem');
  @f_BIO_new                       := RequireProc(FLibCrypto, 'BIO_new');
  @f_BIO_write                     := RequireProc(FLibCrypto, 'BIO_write');
  @f_BIO_read                      := RequireProc(FLibCrypto, 'BIO_read');
  @f_BIO_ctrl                      := RequireProc(FLibCrypto, 'BIO_ctrl');
  @f_SSL_CTX_ctrl                  := RequireProc(FLibSSL,    'SSL_CTX_ctrl');
  @f_SSL_CTX_callback_ctrl         := RequireProc(FLibSSL,    'SSL_CTX_callback_ctrl');
  @f_SSL_get_servername            := RequireProc(FLibSSL,    'SSL_get_servername');
  @f_SSL_set_SSL_CTX               := RequireProc(FLibSSL,    'SSL_set_SSL_CTX');
  @f_ERR_get_error                 := RequireProc(FLibCrypto, 'ERR_get_error');
  @f_ERR_error_string              := RequireProc(FLibCrypto, 'ERR_error_string');

  // ALPN — optional, requires OpenSSL 1.0.2+
{$IFDEF MSWINDOWS}
  @f_SSL_CTX_set_alpn_select_cb := GetProcAddress(FLibSSL, 'SSL_CTX_set_alpn_select_cb');
  @f_SSL_get0_alpn_selected     := GetProcAddress(FLibSSL, 'SSL_get0_alpn_selected');
{$ELSE}
  @f_SSL_CTX_set_alpn_select_cb := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_CTX_set_alpn_select_cb')));
  @f_SSL_get0_alpn_selected     := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_get0_alpn_selected')));
{$ENDIF}

  FLoaded := True;
end;

class procedure TAsyncIOSSL.EnsureLoaded;
begin
  if FLoaded then Exit;
  FLock.Enter;
  try
    if not FLoaded then DoLoad;
  finally
    FLock.Leave;
  end;
end;

class function TAsyncIOSSL.IsAvailable: Boolean;
begin
  if not FLoaded then
    try EnsureLoaded except Result := False; Exit; end;
  Result := FLoaded;
end;

class function TAsyncIOSSL.LastError: string;
var
  LCode: NativeUInt;
  LBuf:  array[0..255] of AnsiChar;
begin
  Result := '';
  if not FLoaded then Exit;
  LCode := f_ERR_get_error;
  if LCode = 0 then Exit;
  FillChar(LBuf, SizeOf(LBuf), 0);
  Result := string(f_ERR_error_string(LCode, @LBuf[0]));
end;

class function TAsyncIOSSL.CTX_New: Pointer;
begin
  EnsureLoaded;
  Result := f_SSL_CTX_new(f_TLS_server_method);
  if Result = nil then
    raise EAsyncIOSSL.Create('SSL_CTX_new failed: ' + LastError);
end;

class procedure TAsyncIOSSL.CTX_Free(ACtx: Pointer);
begin
  if (ACtx <> nil) and FLoaded then f_SSL_CTX_free(ACtx);
end;

class procedure TAsyncIOSSL.CTX_LoadCert(ACtx: Pointer; const AFile: string);
begin
  if f_SSL_CTX_use_certificate_file(ACtx, PAnsiChar(AnsiString(AFile)),
       SSL_FILETYPE_PEM) <> 1 then
    raise EAsyncIOSSL.Create('SSL_CTX_use_certificate_file failed: ' + LastError);
end;

class procedure TAsyncIOSSL.CTX_LoadKey(ACtx: Pointer; const AFile: string);
begin
  if f_SSL_CTX_use_PrivateKey_file(ACtx, PAnsiChar(AnsiString(AFile)),
       SSL_FILETYPE_PEM) <> 1 then
    raise EAsyncIOSSL.Create('SSL_CTX_use_PrivateKey_file failed: ' + LastError);
end;

class procedure TAsyncIOSSL.CTX_VerifyKey(ACtx: Pointer);
begin
  if f_SSL_CTX_check_private_key(ACtx) <> 1 then
    raise EAsyncIOSSL.Create('SSL key/cert mismatch: ' + LastError);
end;

class function TAsyncIOSSL.New_SSL(ACtx: Pointer): Pointer;
begin
  Result := f_SSL_new(ACtx);
  if Result = nil then
    raise EAsyncIOSSL.Create('SSL_new failed: ' + LastError);
end;

class procedure TAsyncIOSSL.Setup_Server(ASSL: Pointer; out AReadBIO, AWriteBIO: Pointer);
var
  LType: Pointer;
begin
  LType     := f_BIO_s_mem;
  AReadBIO  := f_BIO_new(LType);
  AWriteBIO := f_BIO_new(LType);
  if (AReadBIO = nil) or (AWriteBIO = nil) then
    raise EAsyncIOSSL.Create('BIO_new failed');
  f_SSL_set_bio(ASSL, AReadBIO, AWriteBIO);
  f_SSL_set_accept_state(ASSL);
end;

class procedure TAsyncIOSSL.Free_SSL(ASSL: Pointer);
begin
  if (ASSL <> nil) and FLoaded then f_SSL_free(ASSL);
end;

class function TAsyncIOSSL.Do_Handshake(ASSL: Pointer): Integer;
begin Result := f_SSL_do_handshake(ASSL); end;

class function TAsyncIOSSL.Get_Error(ASSL: Pointer; ARet: Integer): Integer;
begin Result := f_SSL_get_error(ASSL, ARet); end;

class function TAsyncIOSSL.SSL_Read(ASSL, ABuf: Pointer; ALen: Integer): Integer;
begin Result := f_SSL_read(ASSL, ABuf, ALen); end;

class function TAsyncIOSSL.SSL_Write(ASSL: Pointer; const ABuf: Pointer; ALen: Integer): Integer;
begin Result := f_SSL_write(ASSL, ABuf, ALen); end;

class function TAsyncIOSSL.SSL_Pending(ASSL: Pointer): Integer;
begin Result := f_SSL_pending(ASSL); end;

class function TAsyncIOSSL.BIO_Write(ABIO, ABuf: Pointer; ALen: Integer): Integer;
begin Result := f_BIO_write(ABIO, ABuf, ALen); end;

class function TAsyncIOSSL.BIO_Read(ABIO, ABuf: Pointer; ALen: Integer): Integer;
begin Result := f_BIO_read(ABIO, ABuf, ALen); end;

class function TAsyncIOSSL.BIO_Pending(ABIO: Pointer): Integer;
begin Result := f_BIO_ctrl(ABIO, BIO_CTRL_PENDING, 0, nil); end;

class procedure TAsyncIOSSL.CTX_SetSNICallback(ACtx, ACallback, AArg: Pointer);
begin
  f_SSL_CTX_callback_ctrl(ACtx, SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, ACallback);
  f_SSL_CTX_ctrl(ACtx, SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG, 0, AArg);
end;

class function TAsyncIOSSL.SSL_GetServername(ASSL: Pointer): string;
var
  P: PAnsiChar;
begin
  P := f_SSL_get_servername(ASSL, TLSEXT_NAMETYPE_host_name);
  if P = nil then
    Result := ''
  else
    Result := string(AnsiString(P));
end;

class procedure TAsyncIOSSL.SSL_SetCTX(ASSL, ACtx: Pointer);
begin
  f_SSL_set_SSL_CTX(ASSL, ACtx);
end;

// ---------------------------------------------------------------------------
// ALPN select callback — always prefers "h2" over "http/1.1"
// ---------------------------------------------------------------------------

function AsyncIOALPNSelectCallback(ASSL: Pointer; AOutPP, AOutlenP: Pointer;
  AIn: PByte; AInLen: Cardinal; AArg: Pointer): Integer; cdecl;
var
  I: Cardinal;
  L: Byte;
begin
  Result := SSL_TLSEXT_ERR_NOACK;
  // First pass: look for "h2"
  I := 0;
  while I < AInLen do
  begin
    L := AIn[I];
    Inc(I);
    if (L = 2) and (I + 1 < AInLen)
      and (AIn[I] = Ord('h')) and (AIn[I + 1] = Ord('2')) then
    begin
      PPointer(AOutPP)^  := @AIn[I];
      PByte(AOutlenP)^   := L;
      Result := SSL_TLSEXT_ERR_OK;
      Exit;
    end;
    Inc(I, L);
  end;
  // Fallback: accept whatever the client listed first
  if AInLen > 0 then
  begin
    L := AIn[0];
    if L > 0 then
    begin
      PPointer(AOutPP)^ := @AIn[1];
      PByte(AOutlenP)^  := L;
      Result := SSL_TLSEXT_ERR_OK;
    end;
  end;
end;

class procedure TAsyncIOSSL.CTX_SetALPN(ACtx: Pointer; AArg: Pointer);
begin
  if not FLoaded then Exit;
  if not Assigned(f_SSL_CTX_set_alpn_select_cb) then Exit;
  f_SSL_CTX_set_alpn_select_cb(ACtx, @AsyncIOALPNSelectCallback, AArg);
end;

class function TAsyncIOSSL.SSL_GetSelectedProtocol(ASSL: Pointer): string;
var
  LData: PByte;
  LLen:  Cardinal;
  LBuf:  AnsiString;
begin
  Result := '';
  if not FLoaded or not Assigned(f_SSL_get0_alpn_selected) then Exit;
  LData := nil;
  LLen  := 0;
  f_SSL_get0_alpn_selected(ASSL, @LData, @LLen);
  if (LData <> nil) and (LLen > 0) then
  begin
    SetLength(LBuf, LLen);
    Move(LData^, LBuf[1], LLen);
    Result := string(LBuf);
  end;
end;

end.
