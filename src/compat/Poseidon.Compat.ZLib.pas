unit Poseidon.Compat.ZLib;

// Free Pascal ZLib compatibility for the WebSocket permessage-deflate codec
// (issue #5). It re-exports the small slice of System.ZLib that
// Poseidon.Net.WebSocket uses — the raw DEFLATE/INFLATE C API and
// TZDecompressionStream — under CLEAN names.
//
// Why a dedicated unit and not Poseidon.Compat: FPC's zbase/zinflate/zdeflate
// export the inflate state-machine enum whose members include COPY, LEN, DIST,
// TYPE, ... Pascal is case-insensitive, so `COPY` SHADOWS the RTL `Copy`
// function in any unit that pulls those units into scope. `uses` is NOT
// transitive, so isolating them here means consumers of THIS unit see only the
// clean names below and keep their own `Copy`. This unit itself is written to
// avoid every shadowed identifier.
//
// FPC-only: the whole body is guarded by {$IFDEF FPC}; under Delphi
// Poseidon.Net.WebSocket uses System.ZLib directly and never references this
// unit.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
{$ENDIF}

interface

{$IFDEF FPC}
uses
  Classes,
  zbase,
  zdeflate,
  zinflate;

type
  // Re-export the zlib stream record so callers can declare `LStrm: z_stream`.
  z_stream = zbase.z_stream;

const
  // Fixed by the zlib format/ABI — declared literally so a renamed constant in
  // a future FPC zbase cannot silently break the build.
  Z_NO_FLUSH            = 0;
  Z_SYNC_FLUSH          = 2;
  Z_OK                  = 0;
  Z_STREAM_END          = 1;
  Z_BUF_ERROR           = -5;
  Z_DEFLATED            = 8;
  Z_DEFAULT_COMPRESSION = -1;
  Z_DEFAULT_STRATEGY    = 0;

// Thin wrappers over the raw DEFLATE API (names come from THIS unit, so no
// enum pollution reaches the caller).
function deflateInit2(var strm: z_stream;
  level, method, windowBits, memLevel, strategy: Integer): Integer;
function deflate(var strm: z_stream; flush: Integer): Integer;
function deflateEnd(var strm: z_stream): Integer;

type
  // Mirrors the slice of System.ZLib.TZDecompressionStream the WebSocket codec
  // uses: Create(source, windowBits) with a NEGATIVE windowBits (raw INFLATE,
  // no zlib/gzip header) + incremental Read + Free. FPC's zstream stream cannot
  // take a raw windowBits, so this drives the raw inflate API directly. Inflates
  // lazily (one chunk per Read) so the caller's per-iteration
  // decompression-bomb ceiling still works.
  TZDecompressionStream = class
  private
    FStrm: z_stream;
    FInput: TBytes;
    FInited: Boolean;
    FDone: Boolean;
  public
    constructor Create(ASource: TStream; AWindowBits: Integer);
    destructor Destroy; override;
    function Read(var ABuffer; ACount: Longint): Longint;
  end;
{$ENDIF}

implementation

{$IFDEF FPC}

function deflateInit2(var strm: z_stream;
  level, method, windowBits, memLevel, strategy: Integer): Integer;
begin
  Result := zdeflate.deflateInit2(strm, level, method, windowBits, memLevel, strategy);
end;

function deflate(var strm: z_stream; flush: Integer): Integer;
begin
  Result := zdeflate.deflate(strm, flush);
end;

function deflateEnd(var strm: z_stream): Integer;
begin
  Result := zdeflate.deflateEnd(strm);
end;

constructor TZDecompressionStream.Create(ASource: TStream; AWindowBits: Integer);
begin
  inherited Create;
  SetLength(FInput, ASource.Size - ASource.Position);
  if Length(FInput) > 0 then
    ASource.ReadBuffer(FInput[0], Length(FInput));
  FillChar(FStrm, SizeOf(FStrm), 0);
  if zinflate.inflateInit2(FStrm, AWindowBits) <> Z_OK then
    raise Exception.Create('TZDecompressionStream: inflateInit2 failed');
  FInited := True;
  if Length(FInput) > 0 then
  begin
    FStrm.next_in := @FInput[0];
    FStrm.avail_in := Length(FInput);
  end;
end;

destructor TZDecompressionStream.Destroy;
begin
  if FInited then
    zinflate.inflateEnd(FStrm);
  inherited Destroy;
end;

function TZDecompressionStream.Read(var ABuffer; ACount: Longint): Longint;
var
  LRet: Integer;
begin
  if FDone or (ACount <= 0) then
    Exit(0);
  FStrm.next_out := @ABuffer;
  FStrm.avail_out := ACount;
  LRet := zinflate.inflate(FStrm, Z_NO_FLUSH);
  // Z_BUF_ERROR = no further progress possible (input exhausted): treated as a
  // benign end-of-data here so the caller's read-until-0 loop terminates.
  if (LRet <> Z_OK) and (LRet <> Z_STREAM_END) and (LRet <> Z_BUF_ERROR) then
    raise Exception.CreateFmt('TZDecompressionStream: inflate error %d', [LRet]);
  if LRet = Z_STREAM_END then
    FDone := True;
  Result := ACount - Longint(FStrm.avail_out);
end;

{$ENDIF}

end.
