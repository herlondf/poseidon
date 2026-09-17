unit Poseidon.Net.SSL;

// Lazy OpenSSL DLL wrapper for Poseidon Native provider.
// Loads libssl + libcrypto on first ConfigureSSL call (no compile-time dependency).
// Uses memory BIOs so IOCP/epoll recv/send remain async.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  syncobjs;
  {$ELSE}
  System.SysUtils,
  System.SyncObjs;
  {$ENDIF}

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

  // mTLS - client certificate verification modes
  SSL_VERIFY_NONE                  = $00;
  SSL_VERIFY_PEER                  = $01;
  SSL_VERIFY_FAIL_IF_NO_PEER_CERT  = $02;

  // Minimum TLS protocol version (OpenSSL 1.1.0+)
  SSL_CTRL_SET_MIN_PROTO_VERSION   = 123;
  TLS1_2_VERSION                   = $0303;
  TLS1_3_VERSION                   = $0304;

  // TLS session cache (macros over SSL_CTX_ctrl)
  SSL_CTRL_SET_SESS_CACHE_SIZE     = 42;
  SSL_CTRL_SET_SESS_CACHE_MODE     = 44;
  SSL_SESS_CACHE_OFF               = $0000;
  SSL_SESS_CACHE_SERVER            = $0002;

  // #255 item 2: session-ticket key rotation callback - the classic
  // EVP_CIPHER_CTX/HMAC_CTX callback (SSL_CTX_set_tlsext_ticket_key_cb),
  // not the newer _evp_cb variant (which takes an EVP_MAC_CTX* instead of
  // HMAC_CTX* for the MAC side). Deprecated as of OpenSSL 3.0 but still
  // present/functional unless a build explicitly strips deprecated-3.0 API
  // (OPENSSL_NO_DEPRECATED_3_0) - kept for compatibility back to 1.0.x,
  // where only this variant exists. Confirmed against a real OpenSSL 3.x
  // ssl.h (Ubuntu 24.04, libssl-dev 3.0.13): 72, NOT 58 (58 is actually
  // SSL_CTRL_GET_TLSEXT_TICKET_KEYS, an unrelated control - an earlier
  // version of this code had the wrong constant, silently registered
  // nothing (SSL_CTX_callback_ctrl returned 0), and every "resumption" in
  // that state was OpenSSL's own built-in ticket key, not this callback at
  // all - caught only by checking the ctrl call's return value AND getting
  // a real header to check against).
  SSL_CTRL_SET_TLSEXT_TICKET_KEY_CB = 72;
  CTicketKeyNameLen  = 16;  // key_name[16] in the callback signature
  CTicketAESKeyLen   = 32;  // AES-256 key
  CTicketHMACKeyLen  = 32;  // HMAC-SHA256 key
  CTicketIVLen       = 16;  // AES-256-CBC IV (== EVP_MAX_IV_LENGTH here)

type
  EPoseidonSSL = class(Exception);

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
  // long BIO_ctrl(BIO*, int cmd, long larg, void* parg) - larg/return are `long`
  // (64-bit on Linux64); bind as NativeInt so a future cmd with a nonzero 64-bit
  // larg or return is not truncated.
  TFn_bio_ctrl    = function(bio: Pointer; cmd: Integer; larg: NativeInt; parg: Pointer): NativeInt; cdecl;
  TFn_ctx_ctrl    = function(ctx: Pointer; cmd: Integer; larg: NativeInt; parg: Pointer): NativeInt; cdecl;
  TFn_ctx_cbctrl  = function(ctx: Pointer; cmd: Integer; cb: Pointer): NativeInt; cdecl;
  // uint64_t SSL_CTX_set_options(SSL_CTX*, uint64_t) - a real function since
  // OpenSSL 1.1.0 (the old SSL_CTRL_OPTIONS ctrl was removed, so the ctrl path
  // would silently no-op). op/return are 64-bit - bind as NativeUInt.
  TFn_ctx_setopt  = function(ctx: Pointer; op: NativeUInt): NativeUInt; cdecl;
  TFn_ssl_getname = function(ssl: Pointer; nametype: Integer): PAnsiChar; cdecl;
  TFn_ssl_setctx  = function(ssl, ctx: Pointer): Pointer; cdecl;
  TFn_err_get         = function: NativeUInt; cdecl;
  TFn_err_str         = function(e: NativeUInt; buf: PAnsiChar): PAnsiChar; cdecl;
  TFn_err_clear       = procedure; cdecl;
  TFn_ctx_alpn_cb     = procedure(ctx: Pointer; cb: Pointer; arg: Pointer); cdecl;
  TFn_ssl_get0_alpn   = procedure(ssl: Pointer; dataptr: Pointer; lenptr: Pointer); cdecl;
  TFn_ctx_set_verify  = procedure(ctx: Pointer; mode: Integer; cb: Pointer); cdecl;
  TFn_ctx_load_verify = function(ctx: Pointer; cafile, capath: PAnsiChar): Integer; cdecl;
  // int SSL_CTX_set_cipher_list(SSL_CTX*, const char*) and
  // int SSL_CTX_set_ciphersuites(SSL_CTX*, const char*) - same signature,
  // one alias covers both (#255).
  TFn_ctx_set_str     = function(ctx: Pointer; const str: PAnsiChar): Integer; cdecl;

  // #255 item 2: session-ticket key rotation FFI surface.
  TFn_evp_cipher      = function: Pointer; cdecl;  // EVP_aes_256_cbc()
  TFn_evp_md          = function: Pointer; cdecl;  // EVP_sha256()
  // int EVP_EncryptInit_ex(EVP_CIPHER_CTX*, const EVP_CIPHER*, ENGINE*, const
  // unsigned char* key, const unsigned char* iv) - EVP_DecryptInit_ex is the
  // same signature.
  TFn_evp_cipherinit  = function(ctx, cipher, impl: Pointer;
    const key, iv: PByte): Integer; cdecl;
  // int HMAC_Init_ex(HMAC_CTX*, const void* key, int keylen, const EVP_MD*,
  // ENGINE*)
  TFn_hmac_init       = function(hctx: Pointer; const key: PByte; keylen: Integer;
    md, impl: Pointer): Integer; cdecl;
  // int RAND_bytes(unsigned char* buf, int num)
  TFn_rand_bytes      = function(buf: PByte; num: Integer): Integer; cdecl;
  // The classic (non-EVP) ticket key callback - stable across every OpenSSL
  // version since TLS session tickets were introduced.
  TFn_ticket_key_cb   = function(ASSL: Pointer; AKeyName: PByte; AIV: PByte;
    ACtx, AHCtx: Pointer; AEnc: Integer): Integer; cdecl;

  TPoseidonLibHandle = NativeUInt;

  TPoseidonSSL = class
  private
    class var FLock: TCriticalSection;
    class var FLoaded: Boolean;
    class var FLibSSL: TPoseidonLibHandle;
    class var FLibCrypto: TPoseidonLibHandle;

    class var f_TLS_server_method: TFn_method;
    class var f_SSL_CTX_new: TFn_ctx_new;
    class var f_SSL_CTX_free: TFn_ctx_free;
    class var f_SSL_CTX_use_certificate_file: TFn_ctx_file;
    class var f_SSL_CTX_use_PrivateKey_file: TFn_ctx_file;
    class var f_SSL_CTX_check_private_key: TFn_ctx_chkkey;
    class var f_SSL_new: TFn_ssl_new;
    class var f_SSL_free: TFn_ssl_free;
    class var f_SSL_set_accept_state: TFn_ssl_state;
    class var f_SSL_do_handshake: TFn_ssl_hands;
    class var f_SSL_read: TFn_ssl_rw;
    class var f_SSL_write: TFn_ssl_rw;
    class var f_SSL_get_error: TFn_ssl_err;
    class var f_SSL_pending: TFn_ssl_pend;
    class var f_SSL_set_bio: TFn_ssl_setbio;
    class var f_BIO_s_mem: TFn_bio_smem;
    class var f_BIO_new: TFn_bio_new;
    class var f_BIO_free: TFn_ssl_hands;  // int BIO_free(BIO*)
    class var f_BIO_write: TFn_bio_rw;
    class var f_BIO_read: TFn_bio_rw;
    class var f_BIO_ctrl: TFn_bio_ctrl;
    class var f_SSL_CTX_ctrl: TFn_ctx_ctrl;
    class var f_SSL_CTX_callback_ctrl: TFn_ctx_cbctrl;
    class var f_SSL_get_servername: TFn_ssl_getname;
    class var f_SSL_set_SSL_CTX: TFn_ssl_setctx;
    class var f_ERR_get_error: TFn_err_get;
    class var f_ERR_error_string: TFn_err_str;
    class var f_ERR_clear_error: TFn_err_clear;
    class var f_SSL_CTX_set_alpn_select_cb: TFn_ctx_alpn_cb;
    class var f_SSL_get0_alpn_selected: TFn_ssl_get0_alpn;
    class var f_SSL_CTX_set_verify: TFn_ctx_set_verify;
    class var f_SSL_CTX_load_verify_locations: TFn_ctx_load_verify;
    class var f_SSL_CTX_set_options: TFn_ctx_setopt;
    // #255: explicit cipher policy instead of "whatever the host's OpenSSL
    // package defaults to today". set_cipher_list is TLS<=1.2 only (its
    // OpenSSL "no-CBC/no-RC4" grammar rejects TLS 1.3 ciphersuite names);
    // set_ciphersuites is TLS 1.3's own separate, OpenSSL 1.1.1+-only API.
    class var f_SSL_CTX_set_cipher_list: TFn_ctx_set_str;
    class var f_SSL_CTX_set_ciphersuites: TFn_ctx_set_str;

    // #255 item 2
    class var f_EVP_aes_256_cbc: TFn_evp_cipher;
    class var f_EVP_sha256: TFn_evp_md;
    class var f_EVP_EncryptInit_ex: TFn_evp_cipherinit;
    class var f_EVP_DecryptInit_ex: TFn_evp_cipherinit;
    class var f_HMAC_Init_ex: TFn_hmac_init;
    class var f_RAND_bytes: TFn_rand_bytes;

    class var FTicketLock: TCriticalSection;
    class var FTicketKeyName: array[0..CTicketKeyNameLen - 1] of Byte;
    class var FTicketAESKey:  array[0..CTicketAESKeyLen - 1] of Byte;
    class var FTicketHMACKey: array[0..CTicketHMACKeyLen - 1] of Byte;
    class var FTicketPrevName:    array[0..CTicketKeyNameLen - 1] of Byte;
    class var FTicketPrevAESKey:  array[0..CTicketAESKeyLen - 1] of Byte;
    class var FTicketPrevHMACKey: array[0..CTicketHMACKeyLen - 1] of Byte;
    class var FTicketHasPrevKey: Boolean;
    class var FTicketRotationMs: UInt64;
    class var FTicketLastRotationTick: UInt64;
    class var FTicketCallbackCount: Int64;
    class var FTicketRotationCount: Int64;

    class procedure TicketKey_GenerateInto(AName, AAESKey, AHMACKey: PByte);
    class procedure TicketKey_MaybeRotate;

    class function  TryLoadLib(const AName: string): TPoseidonLibHandle;
    class function  RequireProc(ALib: TPoseidonLibHandle; const AName: string): Pointer;
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

    // SNI (Server Name Indication) - multi-cert support
    class procedure CTX_SetSNICallback(ACtx, ACallback, AArg: Pointer); static;
    class function  SSL_GetServername(ASSL: Pointer): string; static;
    class procedure SSL_SetCTX(ASSL, ACtx: Pointer); static;

    // ALPN - HTTP/2 protocol negotiation (OpenSSL 1.0.2+)
    class procedure CTX_SetALPN(ACtx: Pointer; AArg: Pointer); static;
    class function  SSL_GetSelectedProtocol(ASSL: Pointer): string; static;

    // mTLS - require client certificate signed by ACAFile (PEM CA bundle).
    // Call after CTX_New. Raises EPoseidonSSL when ACAFile cannot be loaded.
    class procedure CTX_ConfigureMTLS(ACtx: Pointer; const ACAFile: string);

    // Reject TLS handshakes below AMinVersion.
    // Use constants TLS1_2_VERSION ($0303) or TLS1_3_VERSION ($0304).
    // No-op when AMinVersion = 0 (library default - OpenSSL 3.x: TLS 1.2).
    class procedure CTX_SetMinVersion(ACtx: Pointer; AMinVersion: Integer);

    // Harden the context: disable client-initiated renegotiation (TLS 1.2
    // CPU-amplification DoS), disable TLS compression (CRIME), and prefer the
    // server's cipher order. No-op if SSL_CTX_set_options is unavailable.
    class procedure CTX_SetSecurityOptions(ACtx: Pointer);

    // Enable server-side TLS session cache to reduce handshake cost on
    // reconnections. ACacheSize is the max number of cached sessions (default 1024).
    class procedure CTX_EnableSessionCache(ACtx: Pointer; ACacheSize: Integer = 1024);

    // #255 item 2: rotate the AES-256-CBC + HMAC-SHA256 key pair used to
    // encrypt/decrypt TLS session tickets, on a timer (lazily checked inside
    // the callback, no background thread). A ticket issued under the
    // previous key still resumes successfully during exactly one rotation
    // interval of grace (the callback returns 2 = "valid, reissue"), then is
    // no longer accepted (server falls back to a full handshake, not an
    // error). Best-effort/no-op (logs nothing, just does not register) if
    // the required OpenSSL symbols are unavailable - callers should still
    // treat TLS as functional either way, this only affects forward-secrecy
    // posture under long uptimes, never correctness.
    class procedure CTX_EnableTicketKeyRotation(ACtx: Pointer;
      ARotationIntervalMs: UInt64 = 12 * 3600 * 1000);

    // Diagnostics only (#255) - lets a live test confirm the callback is
    // genuinely being invoked by real handshakes, not just registered.
    class function TicketKeyCallbackCount: Int64; static;
    class function TicketKeyRotationCount: Int64; static;
  end;

implementation

uses
{$IFDEF MSWINDOWS}
  {$IFDEF FPC}
  Classes, Poseidon.Compat.DynLib;
  {$ELSE}
  System.Classes, Winapi.Windows;
  {$ENDIF}
{$ELSE}
  {$IFDEF FPC}
  Classes, Poseidon.Compat.DynLib;
  {$ELSE}
  System.Classes, Posix.Dlfcn;
  {$ENDIF}
{$ENDIF}

class constructor TPoseidonSSL.Create;
begin
  FLock := TCriticalSection.Create;
  FTicketLock := TCriticalSection.Create;
  FLoaded := False;
  FLibSSL := 0;
  FLibCrypto := 0;
end;

class destructor TPoseidonSSL.Destroy;
begin
  FLoaded := False;
{$IFDEF MSWINDOWS}
  if FLibSSL <> 0    then FreeLibrary(FLibSSL);
  if FLibCrypto <> 0 then FreeLibrary(FLibCrypto);
{$ELSE}
  if FLibSSL <> 0    then dlclose(FLibSSL);
  if FLibCrypto <> 0 then dlclose(FLibCrypto);
{$ENDIF}
  FTicketLock.Free;
  FLock.Free;
end;

class function TPoseidonSSL.TryLoadLib(const AName: string): TPoseidonLibHandle;
begin
{$IFDEF MSWINDOWS}
  Result := LoadLibrary(PChar(AName));
{$ELSE}
  Result := dlopen(MarshaledAString(AnsiString(AName)), RTLD_LAZY or RTLD_GLOBAL);
{$ENDIF}
end;

class function TPoseidonSSL.RequireProc(ALib: TPoseidonLibHandle;
  const AName: string): Pointer;
begin
{$IFDEF MSWINDOWS}
  Result := GetProcAddress(ALib, PChar(AName));
{$ELSE}
  Result := dlsym(ALib, MarshaledAString(AnsiString(AName)));
{$ENDIF}
  if Result = nil then
    raise EPoseidonSSL.CreateFmt('OpenSSL: missing symbol "%s"', [AName]);
end;

class procedure TPoseidonSSL.DoLoad;
var
  LInit: procedure; cdecl;
begin
{$IFDEF MSWINDOWS}
  FLibSSL := TryLoadLib('libssl-3-x64.dll');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl-3.dll');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl-1_1-x64.dll');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl.dll');
  if FLibSSL = 0 then
    raise EPoseidonSSL.Create(
      'OpenSSL libssl not found. Install OpenSSL 3.x or 1.1.x and ensure DLLs are in PATH.');

  FLibCrypto := TryLoadLib('libcrypto-3-x64.dll');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto-3.dll');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto-1_1-x64.dll');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto.dll');
  if FLibCrypto = 0 then
    raise EPoseidonSSL.Create('OpenSSL libcrypto not found.');
{$ELSE}
  FLibSSL := TryLoadLib('libssl.so.3');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl.so.1.1');
  if FLibSSL = 0 then FLibSSL := TryLoadLib('libssl.so');
  if FLibSSL = 0 then
    raise EPoseidonSSL.Create(
      'OpenSSL libssl not found. Install libssl-dev (apt install libssl-dev).');

  FLibCrypto := TryLoadLib('libcrypto.so.3');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto.so.1.1');
  if FLibCrypto = 0 then FLibCrypto := TryLoadLib('libcrypto.so');
  if FLibCrypto = 0 then
    raise EPoseidonSSL.Create('OpenSSL libcrypto not found.');
{$ENDIF}

{$IFDEF MSWINDOWS}
  @LInit := GetProcAddress(FLibSSL, 'SSL_library_init');
{$ELSE}
  @LInit := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_library_init')));
{$ENDIF}
  if @LInit <> nil then LInit;

  @f_TLS_server_method := RequireProc(FLibSSL, 'TLS_server_method');
  @f_SSL_CTX_new := RequireProc(FLibSSL, 'SSL_CTX_new');
  @f_SSL_CTX_free := RequireProc(FLibSSL, 'SSL_CTX_free');
  @f_SSL_CTX_use_certificate_file := RequireProc(FLibSSL, 'SSL_CTX_use_certificate_file');
  @f_SSL_CTX_use_PrivateKey_file := RequireProc(FLibSSL, 'SSL_CTX_use_PrivateKey_file');
  @f_SSL_CTX_check_private_key := RequireProc(FLibSSL, 'SSL_CTX_check_private_key');
  @f_SSL_new := RequireProc(FLibSSL, 'SSL_new');
  @f_SSL_free := RequireProc(FLibSSL, 'SSL_free');
  @f_SSL_set_accept_state := RequireProc(FLibSSL, 'SSL_set_accept_state');
  @f_SSL_do_handshake := RequireProc(FLibSSL, 'SSL_do_handshake');
  @f_SSL_read := RequireProc(FLibSSL, 'SSL_read');
  @f_SSL_write := RequireProc(FLibSSL, 'SSL_write');
  @f_SSL_get_error := RequireProc(FLibSSL, 'SSL_get_error');
  @f_SSL_pending := RequireProc(FLibSSL, 'SSL_pending');
  @f_SSL_set_bio := RequireProc(FLibSSL, 'SSL_set_bio');
  @f_BIO_s_mem := RequireProc(FLibCrypto, 'BIO_s_mem');
  @f_BIO_new := RequireProc(FLibCrypto, 'BIO_new');
  @f_BIO_free := RequireProc(FLibCrypto, 'BIO_free');
  @f_BIO_write := RequireProc(FLibCrypto, 'BIO_write');
  @f_BIO_read := RequireProc(FLibCrypto, 'BIO_read');
  @f_BIO_ctrl := RequireProc(FLibCrypto, 'BIO_ctrl');
  @f_SSL_CTX_ctrl := RequireProc(FLibSSL, 'SSL_CTX_ctrl');
  @f_SSL_CTX_callback_ctrl := RequireProc(FLibSSL, 'SSL_CTX_callback_ctrl');
  @f_SSL_get_servername := RequireProc(FLibSSL, 'SSL_get_servername');
  @f_SSL_set_SSL_CTX := RequireProc(FLibSSL, 'SSL_set_SSL_CTX');
  @f_ERR_get_error := RequireProc(FLibCrypto, 'ERR_get_error');
  @f_ERR_error_string := RequireProc(FLibCrypto, 'ERR_error_string');
  @f_ERR_clear_error := RequireProc(FLibCrypto, 'ERR_clear_error');

  // ALPN - optional, requires OpenSSL 1.0.2+
{$IFDEF MSWINDOWS}
  @f_SSL_CTX_set_alpn_select_cb := GetProcAddress(FLibSSL, 'SSL_CTX_set_alpn_select_cb');
  @f_SSL_get0_alpn_selected     := GetProcAddress(FLibSSL, 'SSL_get0_alpn_selected');
{$ELSE}
  @f_SSL_CTX_set_alpn_select_cb := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_CTX_set_alpn_select_cb')));
  @f_SSL_get0_alpn_selected     := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_get0_alpn_selected')));
{$ENDIF}

  // Present in all OpenSSL versions; loaded as optional for safety
{$IFDEF MSWINDOWS}
  @f_SSL_CTX_set_verify            := GetProcAddress(FLibSSL, 'SSL_CTX_set_verify');
  @f_SSL_CTX_load_verify_locations := GetProcAddress(FLibSSL, 'SSL_CTX_load_verify_locations');
{$ELSE}
  @f_SSL_CTX_set_verify            := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_CTX_set_verify')));
  @f_SSL_CTX_load_verify_locations := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_CTX_load_verify_locations')));
{$ENDIF}

  // Real function since OpenSSL 1.1.0 (optional load for safety on older libs).
{$IFDEF MSWINDOWS}
  @f_SSL_CTX_set_options := GetProcAddress(FLibSSL, 'SSL_CTX_set_options');
{$ELSE}
  @f_SSL_CTX_set_options := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_CTX_set_options')));
{$ENDIF}

  // #255: set_cipher_list present since ~forever; set_ciphersuites only since
  // OpenSSL 1.1.1 (TLS 1.3). Both loaded as optional - CTX_SetSecurityOptions
  // guards each with Assigned() before calling.
{$IFDEF MSWINDOWS}
  @f_SSL_CTX_set_cipher_list  := GetProcAddress(FLibSSL, 'SSL_CTX_set_cipher_list');
  @f_SSL_CTX_set_ciphersuites := GetProcAddress(FLibSSL, 'SSL_CTX_set_ciphersuites');
{$ELSE}
  @f_SSL_CTX_set_cipher_list  := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_CTX_set_cipher_list')));
  @f_SSL_CTX_set_ciphersuites := dlsym(FLibSSL, MarshaledAString(AnsiString('SSL_CTX_set_ciphersuites')));
{$ENDIF}

  // #255 item 2: all from libcrypto, present in every OpenSSL version this
  // unit supports - loaded as optional anyway so a stripped/unusual build
  // degrades to "no ticket rotation" instead of failing TLS entirely.
{$IFDEF MSWINDOWS}
  @f_EVP_aes_256_cbc     := GetProcAddress(FLibCrypto, 'EVP_aes_256_cbc');
  @f_EVP_sha256          := GetProcAddress(FLibCrypto, 'EVP_sha256');
  @f_EVP_EncryptInit_ex  := GetProcAddress(FLibCrypto, 'EVP_EncryptInit_ex');
  @f_EVP_DecryptInit_ex  := GetProcAddress(FLibCrypto, 'EVP_DecryptInit_ex');
  @f_HMAC_Init_ex        := GetProcAddress(FLibCrypto, 'HMAC_Init_ex');
  @f_RAND_bytes          := GetProcAddress(FLibCrypto, 'RAND_bytes');
{$ELSE}
  @f_EVP_aes_256_cbc     := dlsym(FLibCrypto, MarshaledAString(AnsiString('EVP_aes_256_cbc')));
  @f_EVP_sha256          := dlsym(FLibCrypto, MarshaledAString(AnsiString('EVP_sha256')));
  @f_EVP_EncryptInit_ex  := dlsym(FLibCrypto, MarshaledAString(AnsiString('EVP_EncryptInit_ex')));
  @f_EVP_DecryptInit_ex  := dlsym(FLibCrypto, MarshaledAString(AnsiString('EVP_DecryptInit_ex')));
  @f_HMAC_Init_ex        := dlsym(FLibCrypto, MarshaledAString(AnsiString('HMAC_Init_ex')));
  @f_RAND_bytes          := dlsym(FLibCrypto, MarshaledAString(AnsiString('RAND_bytes')));
{$ENDIF}

  FLoaded := True;
end;

class procedure TPoseidonSSL.EnsureLoaded;
begin
  if FLoaded then Exit;
  FLock.Enter;
  try
    if not FLoaded then DoLoad;
  finally
    FLock.Leave;
  end;
end;

class function TPoseidonSSL.IsAvailable: Boolean;
begin
  if not FLoaded then
    try EnsureLoaded except Result := False; Exit; end;
  Result := FLoaded;
end;

class function TPoseidonSSL.LastError: string;
var
  LCode: NativeUInt;
  LBuf:  array[0..255] of AnsiChar;
begin
  Result := '';
  if not FLoaded then Exit;
  // Drain entire OpenSSL error queue - first error becomes the result,
  // remaining errors are consumed to prevent queue pollution.
  LCode := f_ERR_get_error;
  if LCode = 0 then Exit;
  FillChar(LBuf, SizeOf(LBuf), 0);
  Result := string(f_ERR_error_string(LCode, @LBuf[0]));
  while f_ERR_get_error <> 0 do ;
end;

class function TPoseidonSSL.CTX_New: Pointer;
begin
  EnsureLoaded;
  Result := f_SSL_CTX_new(f_TLS_server_method);
  if Result = nil then
    raise EPoseidonSSL.Create('SSL_CTX_new failed: ' + LastError);
end;

class procedure TPoseidonSSL.CTX_Free(ACtx: Pointer);
begin
  if (ACtx <> nil) and FLoaded then f_SSL_CTX_free(ACtx);
end;

class procedure TPoseidonSSL.CTX_LoadCert(ACtx: Pointer; const AFile: string);
begin
  if f_SSL_CTX_use_certificate_file(ACtx, PAnsiChar(AnsiString(AFile)),
       SSL_FILETYPE_PEM) <> 1 then
    raise EPoseidonSSL.Create('SSL_CTX_use_certificate_file failed: ' + LastError);
end;

class procedure TPoseidonSSL.CTX_LoadKey(ACtx: Pointer; const AFile: string);
begin
  if f_SSL_CTX_use_PrivateKey_file(ACtx, PAnsiChar(AnsiString(AFile)),
       SSL_FILETYPE_PEM) <> 1 then
    raise EPoseidonSSL.Create('SSL_CTX_use_PrivateKey_file failed: ' + LastError);
end;

class procedure TPoseidonSSL.CTX_VerifyKey(ACtx: Pointer);
begin
  if f_SSL_CTX_check_private_key(ACtx) <> 1 then
    raise EPoseidonSSL.Create('SSL key/cert mismatch: ' + LastError);
end;

class function TPoseidonSSL.New_SSL(ACtx: Pointer): Pointer;
begin
  Result := f_SSL_new(ACtx);
  if Result = nil then
    raise EPoseidonSSL.Create('SSL_new failed: ' + LastError);
end;

class procedure TPoseidonSSL.Setup_Server(ASSL: Pointer; out AReadBIO, AWriteBIO: Pointer);
var
  LType: Pointer;
begin
  LType     := f_BIO_s_mem;
  AReadBIO  := f_BIO_new(LType);
  AWriteBIO := f_BIO_new(LType);
  if (AReadBIO = nil) or (AWriteBIO = nil) then
  begin
    if AReadBIO <> nil then f_BIO_free(AReadBIO);
    if AWriteBIO <> nil then f_BIO_free(AWriteBIO);
    raise EPoseidonSSL.Create('BIO_new failed');
  end;
  f_SSL_set_bio(ASSL, AReadBIO, AWriteBIO);
  f_SSL_set_accept_state(ASSL);
end;

class procedure TPoseidonSSL.Free_SSL(ASSL: Pointer);
begin
  if (ASSL <> nil) and FLoaded then f_SSL_free(ASSL);
end;

// ERR_clear_error before each SSL op so a subsequent SSL_get_error classifies
// THIS op's result (SSL_ERROR_SSL vs SYSCALL) using a fresh error queue, not a
// stale entry left by an earlier op (OpenSSL man page requirement).
class function TPoseidonSSL.Do_Handshake(ASSL: Pointer): Integer;
begin f_ERR_clear_error; Result := f_SSL_do_handshake(ASSL); end;

class function TPoseidonSSL.Get_Error(ASSL: Pointer; ARet: Integer): Integer;
begin Result := f_SSL_get_error(ASSL, ARet); end;

class function TPoseidonSSL.SSL_Read(ASSL, ABuf: Pointer; ALen: Integer): Integer;
begin f_ERR_clear_error; Result := f_SSL_read(ASSL, ABuf, ALen); end;

class function TPoseidonSSL.SSL_Write(ASSL: Pointer; const ABuf: Pointer; ALen: Integer): Integer;
begin f_ERR_clear_error; Result := f_SSL_write(ASSL, ABuf, ALen); end;

class function TPoseidonSSL.SSL_Pending(ASSL: Pointer): Integer;
begin Result := f_SSL_pending(ASSL); end;

class function TPoseidonSSL.BIO_Write(ABIO, ABuf: Pointer; ALen: Integer): Integer;
begin Result := f_BIO_write(ABIO, ABuf, ALen); end;

class function TPoseidonSSL.BIO_Read(ABIO, ABuf: Pointer; ALen: Integer): Integer;
begin Result := f_BIO_read(ABIO, ABuf, ALen); end;

class function TPoseidonSSL.BIO_Pending(ABIO: Pointer): Integer;
begin Result := Integer(f_BIO_ctrl(ABIO, BIO_CTRL_PENDING, 0, nil)); end;

class procedure TPoseidonSSL.CTX_SetSNICallback(ACtx, ACallback, AArg: Pointer);
begin
  f_SSL_CTX_callback_ctrl(ACtx, SSL_CTRL_SET_TLSEXT_SERVERNAME_CB, ACallback);
  f_SSL_CTX_ctrl(ACtx, SSL_CTRL_SET_TLSEXT_SERVERNAME_ARG, 0, AArg);
end;

class function TPoseidonSSL.SSL_GetServername(ASSL: Pointer): string;
var
  P: PAnsiChar;
begin
  P := f_SSL_get_servername(ASSL, TLSEXT_NAMETYPE_host_name);
  if P = nil then
    Result := ''
  else
    Result := string(AnsiString(P));
end;

class procedure TPoseidonSSL.SSL_SetCTX(ASSL, ACtx: Pointer);
begin
  f_SSL_set_SSL_CTX(ASSL, ACtx);
end;

// ALPN select callback - always prefers "h2" over "http/1.1"

function PoseidonALPNSelectCallback(ASSL: Pointer; AOutPP, AOutlenP: Pointer;
  AIn: PByte; AInLen: Cardinal; AArg: Pointer): Integer; cdecl;
var
  I: Cardinal;
  L: Byte;
begin
  Result := SSL_TLSEXT_ERR_NOACK;
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
  // Second pass: "http/1.1" - the ONLY other protocol the server speaks. Never
  // select the client's first-listed protocol blindly (RFC 7301 §3.2): claiming
  // a protocol the server does not implement is a protocol-confusion bug. With no
  // overlap, leave Result = NOACK (no ALPN in ServerHello; the connection then
  // proceeds as plain HTTP/1.1).
  I := 0;
  while I < AInLen do
  begin
    L := AIn[I];
    Inc(I);
    if (L = 8) and (I + 7 < AInLen)
      and (AIn[I]   = Ord('h')) and (AIn[I+1] = Ord('t'))
      and (AIn[I+2] = Ord('t')) and (AIn[I+3] = Ord('p'))
      and (AIn[I+4] = Ord('/')) and (AIn[I+5] = Ord('1'))
      and (AIn[I+6] = Ord('.')) and (AIn[I+7] = Ord('1')) then
    begin
      PPointer(AOutPP)^ := @AIn[I];
      PByte(AOutlenP)^  := L;
      Result := SSL_TLSEXT_ERR_OK;
      Exit;
    end;
    Inc(I, L);
  end;
end;

class procedure TPoseidonSSL.CTX_SetALPN(ACtx: Pointer; AArg: Pointer);
begin
  if not FLoaded then Exit;
  if not Assigned(f_SSL_CTX_set_alpn_select_cb) then Exit;
  f_SSL_CTX_set_alpn_select_cb(ACtx, @PoseidonALPNSelectCallback, AArg);
end;

class function TPoseidonSSL.SSL_GetSelectedProtocol(ASSL: Pointer): string;
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

// mTLS - require client certificate

class procedure TPoseidonSSL.CTX_ConfigureMTLS(ACtx: Pointer; const ACAFile: string);
begin
  EnsureLoaded;
  if not Assigned(f_SSL_CTX_set_verify) then
    raise EPoseidonSSL.Create('mTLS: SSL_CTX_set_verify not available in this OpenSSL build');
  if not Assigned(f_SSL_CTX_load_verify_locations) then
    raise EPoseidonSSL.Create('mTLS: SSL_CTX_load_verify_locations not available in this OpenSSL build');
  if f_SSL_CTX_load_verify_locations(ACtx, PAnsiChar(AnsiString(ACAFile)), nil) <> 1 then
    raise EPoseidonSSL.Create('SSL_CTX_load_verify_locations failed: ' + LastError);
  f_SSL_CTX_set_verify(ACtx,
    SSL_VERIFY_PEER or SSL_VERIFY_FAIL_IF_NO_PEER_CERT, nil);
end;

// Minimum TLS version
// SSL_CTX_set_min_proto_version is a macro: SSL_CTX_ctrl(ctx, 123, version, NULL)

class procedure TPoseidonSSL.CTX_SetMinVersion(ACtx: Pointer; AMinVersion: Integer);
begin
  if AMinVersion = 0 then Exit;  // 0 = let OpenSSL use its own default
  f_SSL_CTX_ctrl(ACtx, SSL_CTRL_SET_MIN_PROTO_VERSION, AMinVersion, nil);
end;

// Security hardening options (SSL_CTX_set_options)

class procedure TPoseidonSSL.CTX_SetSecurityOptions(ACtx: Pointer);
const
  SSL_OP_NO_COMPRESSION           = NativeUInt($00020000);  // CRIME
  SSL_OP_CIPHER_SERVER_PREFERENCE = NativeUInt($00400000);
  SSL_OP_NO_RENEGOTIATION         = NativeUInt($40000000);  // TLS 1.2 reneg DoS
  // #255: explicit, curated, AEAD-only cipher policy - no CBC (Lucky13/
  // padding-oracle history), no RC4/3DES, no static-RSA key exchange (no
  // forward secrecy). Without this call the policy is silently whatever the
  // host's installed OpenSSL package defaults to, which can change across an
  // unrelated OS package update. TLS<=1.2 list is Mozilla's long-stable
  // "intermediate" cipher set; TLS 1.3 only ever offers AEAD suites by
  // protocol design (CBC/RC4 do not exist in TLS 1.3 at all), so this is
  // about being explicit/deterministic rather than closing an actual gap
  // there.
  CTLS12CipherList =
    'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:' +
    'ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:' +
    'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305';
  CTLS13CipherSuites =
    'TLS_AES_128_GCM_SHA256:TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256';
begin
  if Assigned(f_SSL_CTX_set_options) then
    f_SSL_CTX_set_options(ACtx,
      SSL_OP_NO_RENEGOTIATION or SSL_OP_NO_COMPRESSION or
      SSL_OP_CIPHER_SERVER_PREFERENCE);

  // Best-effort: an older OpenSSL missing set_ciphersuites (pre-1.1.1, no
  // TLS 1.3 support anyway) or rejecting this exact list should not prevent
  // the server from starting - it falls back to that OpenSSL's own default
  // policy for whichever call did not take effect.
  if Assigned(f_SSL_CTX_set_cipher_list) then
    f_SSL_CTX_set_cipher_list(ACtx, PAnsiChar(AnsiString(CTLS12CipherList)));
  if Assigned(f_SSL_CTX_set_ciphersuites) then
    f_SSL_CTX_set_ciphersuites(ACtx, PAnsiChar(AnsiString(CTLS13CipherSuites)));
end;

// TLS session resumption - reduces handshake RTT on reconnections
// SSL_CTX_set_session_cache_mode and SSL_CTX_sess_set_cache_size are macros
// over SSL_CTX_ctrl, so f_SSL_CTX_ctrl (already loaded) handles both.

class procedure TPoseidonSSL.CTX_EnableSessionCache(ACtx: Pointer; ACacheSize: Integer);
begin
  f_SSL_CTX_ctrl(ACtx, SSL_CTRL_SET_SESS_CACHE_MODE, SSL_SESS_CACHE_SERVER, nil);
  f_SSL_CTX_ctrl(ACtx, SSL_CTRL_SET_SESS_CACHE_SIZE, ACacheSize, nil);
end;

// #255 item 2 - TLS session-ticket key rotation
//
// Classic (non-EVP) SSL_CTX_set_tlsext_ticket_key_cb callback. OpenSSL calls
// this on every ticket ISSUE (AEnc=1, a fresh full or resumed handshake
// finishing) and every ticket PRESENT (AEnc=0, a client trying to resume).
// Contract (stable OpenSSL API, unchanged since ~0.9.8f):
//   AEnc=1: fill AKeyName[16] + AIV[16], init ACtx (cipher) + AHCtx (HMAC)
//           for ENCRYPT. Return 1 = ticket issued, 0 = skip issuing a ticket
//           this time (session still completes, just not resumable), -1 =
//           abort (never used here - always degrade to 0 instead).
//   AEnc=0: AKeyName[16] + AIV[16] are already filled in from the presented
//           ticket; init for DECRYPT. Return 1 = resumed with current key,
//           2 = resumed with the (still-valid, one rotation of grace)
//           previous key AND please reissue a fresh ticket now, 0 = ticket
//           unusable (unknown/expired key name) - safe fallback to a full
//           handshake, not an error.
// Every exit path other than a fully successful setup returns 0 - there is
// no scenario where this callback should abort a connection; worst case is
// simply "this handshake does not get ticket resumption."

function PoseidonTicketKeyCallback(ASSL: Pointer; AKeyName: PByte; AIV: PByte;
  ACtx, AHCtx: Pointer; AEnc: Integer): Integer; cdecl;
var
  LName:    array[0..CTicketKeyNameLen - 1] of Byte;
  LAESKey:  array[0..CTicketAESKeyLen - 1] of Byte;
  LHMACKey: array[0..CTicketHMACKeyLen - 1] of Byte;
  LUsePrev: Boolean;
begin
  Result := 0;
  try
    TInterlocked.Increment(TPoseidonSSL.FTicketCallbackCount);
    TPoseidonSSL.TicketKey_MaybeRotate;

    if AEnc = 1 then
    begin
      TPoseidonSSL.FTicketLock.Enter;
      try
        Move(TPoseidonSSL.FTicketKeyName[0], LName[0], CTicketKeyNameLen);
        Move(TPoseidonSSL.FTicketAESKey[0], LAESKey[0], CTicketAESKeyLen);
        Move(TPoseidonSSL.FTicketHMACKey[0], LHMACKey[0], CTicketHMACKeyLen);
      finally
        TPoseidonSSL.FTicketLock.Leave;
      end;

      if not Assigned(TPoseidonSSL.f_RAND_bytes) or
         not Assigned(TPoseidonSSL.f_EVP_EncryptInit_ex) or
         not Assigned(TPoseidonSSL.f_HMAC_Init_ex) then
        Exit(0);

      Move(LName[0], AKeyName^, CTicketKeyNameLen);
      if TPoseidonSSL.f_RAND_bytes(AIV, CTicketIVLen) <> 1 then Exit(0);
      if TPoseidonSSL.f_EVP_EncryptInit_ex(ACtx, TPoseidonSSL.f_EVP_aes_256_cbc(),
           nil, @LAESKey[0], AIV) <> 1 then Exit(0);
      if TPoseidonSSL.f_HMAC_Init_ex(AHCtx, @LHMACKey[0], CTicketHMACKeyLen,
           TPoseidonSSL.f_EVP_sha256(), nil) <> 1 then Exit(0);

      Result := 1;
    end
    else
    begin
      if not Assigned(TPoseidonSSL.f_EVP_DecryptInit_ex) or
         not Assigned(TPoseidonSSL.f_HMAC_Init_ex) then
        Exit(0);

      LUsePrev := False;
      TPoseidonSSL.FTicketLock.Enter;
      try
        if CompareMem(AKeyName, @TPoseidonSSL.FTicketKeyName[0], CTicketKeyNameLen) then
        begin
          Move(TPoseidonSSL.FTicketAESKey[0], LAESKey[0], CTicketAESKeyLen);
          Move(TPoseidonSSL.FTicketHMACKey[0], LHMACKey[0], CTicketHMACKeyLen);
        end
        else if TPoseidonSSL.FTicketHasPrevKey and
          CompareMem(AKeyName, @TPoseidonSSL.FTicketPrevName[0], CTicketKeyNameLen) then
        begin
          Move(TPoseidonSSL.FTicketPrevAESKey[0], LAESKey[0], CTicketAESKeyLen);
          Move(TPoseidonSSL.FTicketPrevHMACKey[0], LHMACKey[0], CTicketHMACKeyLen);
          LUsePrev := True;
        end
        else
          Exit(0);  // unknown key name - ticket cannot be honored, full handshake
      finally
        TPoseidonSSL.FTicketLock.Leave;
      end;

      if TPoseidonSSL.f_HMAC_Init_ex(AHCtx, @LHMACKey[0], CTicketHMACKeyLen,
           TPoseidonSSL.f_EVP_sha256(), nil) <> 1 then Exit(0);
      if TPoseidonSSL.f_EVP_DecryptInit_ex(ACtx, TPoseidonSSL.f_EVP_aes_256_cbc(),
           nil, @LAESKey[0], AIV) <> 1 then Exit(0);

      if LUsePrev then Result := 2 else Result := 1;
    end;
  except
    // Never let an exception cross back into OpenSSL's C call stack.
    Result := 0;
  end;
end;

class procedure TPoseidonSSL.TicketKey_GenerateInto(AName, AAESKey, AHMACKey: PByte);
begin
  if Assigned(f_RAND_bytes) then
  begin
    f_RAND_bytes(AName, CTicketKeyNameLen);
    f_RAND_bytes(AAESKey, CTicketAESKeyLen);
    f_RAND_bytes(AHMACKey, CTicketHMACKeyLen);
  end;
end;

// No lock required from the caller - checks the rotation tick first without
// the lock (cheap, the common "not due yet" case never blocks), only enters
// FTicketLock when a rotation actually needs to happen.
class procedure TPoseidonSSL.TicketKey_MaybeRotate;
var
  LNow: UInt64;
begin
  if FTicketRotationMs = 0 then Exit;  // rotation not enabled
  LNow := TThread.GetTickCount64;
  if LNow - FTicketLastRotationTick < FTicketRotationMs then Exit;

  FTicketLock.Enter;
  try
    // Re-check under the lock - another thread may have just rotated.
    if LNow - FTicketLastRotationTick < FTicketRotationMs then Exit;

    Move(FTicketKeyName[0], FTicketPrevName[0], CTicketKeyNameLen);
    Move(FTicketAESKey[0], FTicketPrevAESKey[0], CTicketAESKeyLen);
    Move(FTicketHMACKey[0], FTicketPrevHMACKey[0], CTicketHMACKeyLen);
    FTicketHasPrevKey := True;

    TicketKey_GenerateInto(@FTicketKeyName[0], @FTicketAESKey[0], @FTicketHMACKey[0]);
    FTicketLastRotationTick := LNow;
    TInterlocked.Increment(FTicketRotationCount);
  finally
    FTicketLock.Leave;
  end;
end;

class procedure TPoseidonSSL.CTX_EnableTicketKeyRotation(ACtx: Pointer;
  ARotationIntervalMs: UInt64);
begin
  EnsureLoaded;
  if not Assigned(f_RAND_bytes) or not Assigned(f_EVP_aes_256_cbc) or
     not Assigned(f_EVP_sha256) or not Assigned(f_EVP_EncryptInit_ex) or
     not Assigned(f_EVP_DecryptInit_ex) or not Assigned(f_HMAC_Init_ex) then
    Exit;  // best-effort - OpenSSL build missing a required symbol

  FTicketLock.Enter;
  try
    TicketKey_GenerateInto(@FTicketKeyName[0], @FTicketAESKey[0], @FTicketHMACKey[0]);
    FTicketHasPrevKey := False;
    FTicketLastRotationTick := TThread.GetTickCount64;
    FTicketRotationMs := ARotationIntervalMs;
  finally
    FTicketLock.Leave;
  end;

  // SSL_CTX_set_tlsext_ticket_key_cb is a macro over SSL_CTX_callback_ctrl.
  // Returns 0 if the control code is unsupported by this OpenSSL build -
  // in that case FTicketRotationMs stays set but the callback never fires,
  // so TicketKeyCallbackCount staying at 0 in a live test is the signal
  // this did not actually take effect.
  f_SSL_CTX_callback_ctrl(ACtx, SSL_CTRL_SET_TLSEXT_TICKET_KEY_CB,
    @PoseidonTicketKeyCallback);
end;

class function TPoseidonSSL.TicketKeyCallbackCount: Int64;
begin
  Result := TInterlocked.Read(FTicketCallbackCount);
end;

class function TPoseidonSSL.TicketKeyRotationCount: Int64;
begin
  Result := TInterlocked.Read(FTicketRotationCount);
end;

end.
