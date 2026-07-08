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
  System.SyncObjs
{$IFDEF MSWINDOWS}
  , Winapi.Windows
{$ENDIF}
  ;

type
  EPoseidonBrotli = class(Exception);

  TPoseidonBrotli = class
  private
    class var FLock: TCriticalSection;
    class var FLibEnc: NativeUInt;
    class var FLibDec: NativeUInt;
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

// Windows: LoadLibrary/FreeLibrary/GetProcAddress come from Winapi.Windows.
// Linux:   System.SysUtils exposes them as cross-platform wrappers.
// Both paths avoid Pointer<->NativeUInt casts that dcclinux64 rejects (E2010).

const
  BROTLI_DEFAULT_LGWIN = 22;   // ~4 MB window; valid for quality 0-11
  BROTLI_MODE_GENERIC = 0; // generic data; 1=text, 2=font
  CCompressOverheadDiv = 4;
  CCompressOverheadBase = 1024;
  CDecompressInitFactor = 8;
  CDecompressInitBase = 4096;
  CDecompressRetryFactor = 32;
  CDecompressRetryBase = 65536;

class constructor TPoseidonBrotli.Create;
begin
  FLock := TCriticalSection.Create;
  FLibEnc := 0;
  FLibDec := 0;
  FInitDone := False;
end;

class destructor TPoseidonBrotli.Destroy;
begin
  if FLibEnc <> 0 then FreeLibrary(FLibEnc);
  if (FLibDec <> 0) and (FLibDec <> FLibEnc) then FreeLibrary(FLibDec);
  FLock.Free;
end;

class function TPoseidonBrotli.TryLoadLib(const AName: string): NativeUInt;
begin
  Result := LoadLibrary(PChar(AName));
end;

class function TPoseidonBrotli.TryGetProc(ALib: NativeUInt;
  const AName: string): Pointer;
begin
  if ALib = 0 then Exit(nil);
  Result := GetProcAddress(ALib, PChar(AName));
end;

class procedure TPoseidonBrotli.EnsureInit;
var
  LLib: NativeUInt;
begin
  if FInitDone then Exit;
  FLock.Enter;
  try
    if FInitDone then Exit;

    // Encoder: try combined lib first, then dedicated encoder lib
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
        FreeLibrary(LLib);
    end;

    // Decoder: check if encoder lib also exports the decoder
    if FLibEnc <> 0 then
      @FDecoderDecompress := TryGetProc(FLibEnc, 'BrotliDecoderDecompress');

    if @FDecoderDecompress = nil then
    begin
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
          FreeLibrary(LLib);
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

  LMaxOut := Length(AInput) + Length(AInput) div CCompressOverheadDiv + CCompressOverheadBase;
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
  LOutLen: NativeUInt;
begin
  EnsureInit;
  if @FDecoderDecompress = nil then
    raise EPoseidonBrotli.Create('Brotli decoder library not available');
  if AInput = nil then
    raise EPoseidonBrotli.Create('Brotli.Decompress: AInput is nil');

  LBufSize := Length(AInput) * CDecompressInitFactor + CDecompressInitBase;
  SetLength(Result, LBufSize);
  LOutLen := LBufSize;

  if FDecoderDecompress(Length(AInput), @AInput[0],
       @LOutLen, @Result[0]) = 0 then
  begin
    LBufSize := Length(AInput) * CDecompressRetryFactor + CDecompressRetryBase;
    SetLength(Result, LBufSize);
    LOutLen := LBufSize;
    if FDecoderDecompress(Length(AInput), @AInput[0],
         @LOutLen, @Result[0]) = 0 then
      raise EPoseidonBrotli.Create('Brotli decompression failed');
  end;

  SetLength(Result, LOutLen);
end;

end.
