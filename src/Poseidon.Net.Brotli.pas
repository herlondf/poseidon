unit Poseidon.Net.Brotli;

// Lazy-load Brotli encoder/decoder for Poseidon.
// Loads libbrotlienc at runtime — no compile-time dependency.
// When the library is absent, IsAvailable returns False and compression is skipped.
//
// Encoder: BrotliEncoderCompress  — used by the server for response compression.
// Decoder: BrotliDecoderDecompress — loaded from libbrotlidec; used in tests only.

interface

uses
  System.SysUtils,
  System.SyncObjs;

type
  EPoseidonBrotli = class(Exception);

  TPoseidonBrotli = class
  private
    class var FLock:    TCriticalSection;
    class var FLibEnc:  NativeUInt;
    class var FLibDec:  NativeUInt;
    class var FInitDone: Boolean;

    // BrotliEncoderCompress(quality, lgwin, mode, input_size, input_buf,
    //   encoded_size*, encoded_buf): BROTLI_BOOL (1 = success)
    class var FEncoderCompress: function(
      quality, lgwin, mode: Integer;
      input_size: NativeUInt; input_buffer: Pointer;
      encoded_size: PNativeUInt; encoded_buffer: Pointer): Integer; cdecl;

    // BrotliDecoderDecompress(encoded_size, encoded_buf,
    //   decoded_size*, decoded_buf): BrotliDecoderResult (1 = success)
    class var FDecoderDecompress: function(
      encoded_size: NativeUInt; encoded_buffer: Pointer;
      decoded_size: PNativeUInt; decoded_buffer: Pointer): Integer; cdecl;

    class function TryLoadLib(const AName: string): NativeUInt;
    class function TryGetProc(ALib: NativeUInt; const AName: string): Pointer;
    class procedure EnsureInit;
    class constructor Create;
    class destructor  Destroy;
  public
    // True if the Brotli encoder library is available at runtime.
    class function IsAvailable: Boolean;
    // True if the Brotli decoder library is also available (needed for tests).
    class function IsDecoderAvailable: Boolean;

    // Compress AInput using Brotli. AQuality: 0 (fastest) .. 11 (best). Default 6.
    // Raises EPoseidonBrotli when the encoder is not available.
    class function Compress(const AInput: TBytes; AQuality: Integer = 6): TBytes;

    // Decompress Brotli-compressed AInput.
    // Raises EPoseidonBrotli when the decoder is not available or decompression fails.
    class function Decompress(const AInput: TBytes): TBytes;
  end;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows;
{$ELSE}
  Posix.Dlfcn;
{$ENDIF}

const
  BROTLI_DEFAULT_LGWIN = 22;   // ~4 MB window; valid for quality 0-11
  BROTLI_MODE_GENERIC  = 0;    // generic data; 1=text, 2=font

class constructor TPoseidonBrotli.Create;
begin
  FLock     := TCriticalSection.Create;
  FLibEnc   := 0;
  FLibDec   := 0;
  FInitDone := False;
end;

class destructor TPoseidonBrotli.Destroy;
begin
{$IFDEF MSWINDOWS}
  if FLibEnc <> 0 then FreeLibrary(FLibEnc);
  if (FLibDec <> 0) and (FLibDec <> FLibEnc) then FreeLibrary(FLibDec);
{$ELSE}
  if FLibEnc <> 0 then dlclose(Pointer(FLibEnc));
  if (FLibDec <> 0) and (FLibDec <> FLibEnc) then dlclose(Pointer(FLibDec));
{$ENDIF}
  FLock.Free;
end;

class function TPoseidonBrotli.TryLoadLib(const AName: string): NativeUInt;
begin
{$IFDEF MSWINDOWS}
  Result := LoadLibrary(PChar(AName));
{$ELSE}
  Result := NativeUInt(dlopen(MarshaledAString(AnsiString(AName)),
    RTLD_LAZY or RTLD_GLOBAL));
{$ENDIF}
end;

class function TPoseidonBrotli.TryGetProc(ALib: NativeUInt;
  const AName: string): Pointer;
begin
  if ALib = 0 then Exit(nil);
{$IFDEF MSWINDOWS}
  Result := GetProcAddress(ALib, PChar(AName));
{$ELSE}
  Result := dlsym(Pointer(ALib), MarshaledAString(AnsiString(AName)));
{$ENDIF}
end;

class procedure TPoseidonBrotli.EnsureInit;
var
  LLib: NativeUInt;
begin
  if FInitDone then Exit;
  FLock.Enter;
  try
    if FInitDone then Exit;

    // --- Encoder ---
    // Try combined lib first, then dedicated encoder lib
{$IFDEF MSWINDOWS}
    LLib := TryLoadLib('brotli.dll');
    if LLib = 0 then LLib := TryLoadLib('brotlienc.dll');
{$ELSE}
    LLib := TryLoadLib('libbrotli.so.1');
    if LLib = 0 then LLib := TryLoadLib('libbrotlienc.so.1');
    if LLib = 0 then LLib := TryLoadLib('libbrotlienc.so');
{$ENDIF}
    if LLib <> 0 then
    begin
      @FEncoderCompress := TryGetProc(LLib, 'BrotliEncoderCompress');
      if @FEncoderCompress <> nil then
        FLibEnc := LLib
      else
      begin
{$IFDEF MSWINDOWS}
        FreeLibrary(LLib);
{$ELSE}
        dlclose(Pointer(LLib));
{$ENDIF}
      end;
    end;

    // --- Decoder ---
    // First check if the already-loaded encoder lib also exports the decoder
    if FLibEnc <> 0 then
      @FDecoderDecompress := TryGetProc(FLibEnc, 'BrotliDecoderDecompress');

    if @FDecoderDecompress = nil then
    begin
      // Try a separate decoder library
{$IFDEF MSWINDOWS}
      LLib := TryLoadLib('brotlidec.dll');
{$ELSE}
      LLib := TryLoadLib('libbrotlidec.so.1');
      if LLib = 0 then LLib := TryLoadLib('libbrotlidec.so');
{$ENDIF}
      if LLib <> 0 then
      begin
        @FDecoderDecompress := TryGetProc(LLib, 'BrotliDecoderDecompress');
        if @FDecoderDecompress <> nil then
          FLibDec := LLib
        else
        begin
{$IFDEF MSWINDOWS}
          FreeLibrary(LLib);
{$ELSE}
          dlclose(Pointer(LLib));
{$ENDIF}
        end;
      end;
    end;

    FInitDone := True;
  finally
    FLock.Leave;
  end;
end;

class function TPoseidonBrotli.IsAvailable: Boolean;
begin
  EnsureInit;
  Result := @FEncoderCompress <> nil;
end;

class function TPoseidonBrotli.IsDecoderAvailable: Boolean;
begin
  EnsureInit;
  Result := @FDecoderDecompress <> nil;
end;

class function TPoseidonBrotli.Compress(const AInput: TBytes;
  AQuality: Integer): TBytes;
var
  LMaxOut: NativeUInt;
  LOutLen: NativeUInt;
begin
  EnsureInit;
  if @FEncoderCompress = nil then
    raise EPoseidonBrotli.Create('Brotli encoder library not available');
  if AInput = nil then
    raise EPoseidonBrotli.Create('Brotli.Compress: AInput is nil');

  // BrotliEncoderMaxCompressedSize gives a safe upper bound; approximate: input + 1KB
  LMaxOut := Length(AInput) + Length(AInput) div 4 + 1024;
  SetLength(Result, LMaxOut);
  LOutLen := LMaxOut;

  if FEncoderCompress(AQuality, BROTLI_DEFAULT_LGWIN, BROTLI_MODE_GENERIC,
       Length(AInput), @AInput[0],
       @LOutLen, @Result[0]) = 0 then
    raise EPoseidonBrotli.Create('Brotli compression failed');

  SetLength(Result, LOutLen);
end;

class function TPoseidonBrotli.Decompress(const AInput: TBytes): TBytes;
var
  LBufSize: NativeUInt;
  LOutLen:  NativeUInt;
begin
  EnsureInit;
  if @FDecoderDecompress = nil then
    raise EPoseidonBrotli.Create('Brotli decoder library not available');
  if AInput = nil then
    raise EPoseidonBrotli.Create('Brotli.Decompress: AInput is nil');

  // Allocate initial output buffer; expand if needed (rare for test data)
  LBufSize := Length(AInput) * 8 + 4096;
  SetLength(Result, LBufSize);
  LOutLen := LBufSize;

  if FDecoderDecompress(Length(AInput), @AInput[0],
       @LOutLen, @Result[0]) = 0 then
  begin
    // Retry with a much larger buffer (for highly compressed inputs)
    LBufSize := Length(AInput) * 32 + 65536;
    SetLength(Result, LBufSize);
    LOutLen := LBufSize;
    if FDecoderDecompress(Length(AInput), @AInput[0],
         @LOutLen, @Result[0]) = 0 then
      raise EPoseidonBrotli.Create('Brotli decompression failed');
  end;

  SetLength(Result, LOutLen);
end;

end.
