unit Poseidon.Net.Pool.Buffer;

// P-2: Multi-tier object pool for AccumBuf buffers.
//
// Three tiers by buffer size:
//   Tier 0 —   8 KB (256 slots) — initial connection buffer, ping/small requests
//   Tier 1 —  64 KB ( 64 slots) — medium requests / uploads
//   Tier 2 — 512 KB ( 16 slots) — large responses / streaming
//
// v2: Thread-local fast path per tier.  Each worker thread keeps a small cache
//     (TL_TIER*_MAX) per tier — Acquire/Release hit this cache first with ZERO
//     locks.  Only when the local cache is empty (Acquire) or full (Release)
//     does the code fall back to the global pool under TMonitor.
//
// Acquire(ASize) returns the smallest tier whose slot size >= ASize.
// Buffers larger than 512 KB bypass the pool (heap alloc/free).
// Release detects the tier by buffer length and returns it to the correct stack.

interface

uses
  System.SysUtils;

const
  POOL_TIER0_SIZE  =    8192;  //   8 KB
  POOL_TIER1_SIZE  =   65536;  //  64 KB
  POOL_TIER2_SIZE  =  524288;  // 512 KB

  POOL_TIER0_MAX   = 256;
  POOL_TIER1_MAX   =  64;
  POOL_TIER2_MAX   =  16;

  // Thread-local cache sizes per tier (small — avoids hoarding buffers)
  TL_TIER0_MAX     =   8;
  TL_TIER1_MAX     =   4;
  TL_TIER2_MAX     =   2;

  // Backward-compat alias
  POOL_BUF_SIZE    = POOL_TIER0_SIZE;
  MAX_POOL_SIZE    = POOL_TIER0_MAX;

type
  TBufferPool = class
  public
    // Returns a buffer whose Length >= ASize, sourced from the matching tier.
    // ASize = 0 is treated as a request for a Tier-0 (8 KB) buffer.
    class function  Acquire(ASize: Integer = 0): TBytes; static;
    class procedure Release(var ABuf: TBytes); static;
  end;

implementation

uses
  System.SyncObjs,
  System.Generics.Collections;

{$IFNDEF MSWINDOWS}
const
  MADV_HUGEPAGE = 14;

function _madvise(addr: Pointer; len: NativeUInt; advice: Integer): Integer; cdecl;
  external 'libc.so.6' name 'madvise';

procedure _HintHugePage(var ABuf: TBytes);
begin
  if Length(ABuf) >= 65536 then
    _madvise(@ABuf[0], NativeUInt(Length(ABuf)), MADV_HUGEPAGE);
end;
{$ELSE}
procedure _HintHugePage(var ABuf: TBytes); begin end;
{$ENDIF}

// ---------------------------------------------------------------------------
// Thread-local cache — one instance per thread, lazily created
// ---------------------------------------------------------------------------

type
  TThreadLocalBufCache = class
    FTier0: array[0..TL_TIER0_MAX - 1] of TBytes;
    FTier0Count: Integer;
    FTier1: array[0..TL_TIER1_MAX - 1] of TBytes;
    FTier1Count: Integer;
    FTier2: array[0..TL_TIER2_MAX - 1] of TBytes;
    FTier2Count: Integer;
  end;

threadvar
  GTLCache: TThreadLocalBufCache;

function GetTLCache: TThreadLocalBufCache; inline;
begin
  Result := GTLCache;
  if Result = nil then
  begin
    Result := TThreadLocalBufCache.Create;
    GTLCache := Result;
  end;
end;

// ---------------------------------------------------------------------------
// Global pool (fallback when thread-local cache misses)
// ---------------------------------------------------------------------------

var
  GTier0: TStack<TBytes>;
  GTier1: TStack<TBytes>;
  GTier2: TStack<TBytes>;

// ---------------------------------------------------------------------------
// Acquire — thread-local first, then global, then heap
// ---------------------------------------------------------------------------

function _GlobalPopOrAlloc(AStack: TStack<TBytes>; ABufSize: Integer): TBytes;
var
  LHave: Boolean;
begin
  Result := nil;
  TMonitor.Enter(AStack);
  try
    LHave := AStack.Count > 0;
    if LHave then Result := AStack.Pop;
  finally
    TMonitor.Exit(AStack);
  end;
  if not LHave then
  begin
    SetLength(Result, ABufSize);
    _HintHugePage(Result);
  end;
end;

class function TBufferPool.Acquire(ASize: Integer): TBytes;
var
  LCache: TThreadLocalBufCache;
begin
  LCache := GetTLCache;

  if ASize <= POOL_TIER0_SIZE then
  begin
    if LCache.FTier0Count > 0 then
    begin
      Dec(LCache.FTier0Count);
      Result := LCache.FTier0[LCache.FTier0Count];
      LCache.FTier0[LCache.FTier0Count] := nil;
    end
    else
      Result := _GlobalPopOrAlloc(GTier0, POOL_TIER0_SIZE);
  end
  else if ASize <= POOL_TIER1_SIZE then
  begin
    if LCache.FTier1Count > 0 then
    begin
      Dec(LCache.FTier1Count);
      Result := LCache.FTier1[LCache.FTier1Count];
      LCache.FTier1[LCache.FTier1Count] := nil;
    end
    else
      Result := _GlobalPopOrAlloc(GTier1, POOL_TIER1_SIZE);
  end
  else if ASize <= POOL_TIER2_SIZE then
  begin
    if LCache.FTier2Count > 0 then
    begin
      Dec(LCache.FTier2Count);
      Result := LCache.FTier2[LCache.FTier2Count];
      LCache.FTier2[LCache.FTier2Count] := nil;
    end
    else
      Result := _GlobalPopOrAlloc(GTier2, POOL_TIER2_SIZE);
  end
  else
    SetLength(Result, ASize);
end;

// ---------------------------------------------------------------------------
// Release — thread-local first, overflow goes to global
// ---------------------------------------------------------------------------

procedure _GlobalPushIfRoom(AStack: TStack<TBytes>; AMax: Integer; const ABuf: TBytes);
begin
  TMonitor.Enter(AStack);
  try
    if AStack.Count < AMax then AStack.Push(ABuf);
  finally
    TMonitor.Exit(AStack);
  end;
end;

class procedure TBufferPool.Release(var ABuf: TBytes);
var
  LLen:   Integer;
  LCache: TThreadLocalBufCache;
begin
  LLen := Length(ABuf);
  LCache := GetTLCache;

  if LLen = POOL_TIER0_SIZE then
  begin
    if LCache.FTier0Count < TL_TIER0_MAX then
    begin
      LCache.FTier0[LCache.FTier0Count] := ABuf;
      Inc(LCache.FTier0Count);
    end
    else
      _GlobalPushIfRoom(GTier0, POOL_TIER0_MAX, ABuf);
  end
  else if LLen = POOL_TIER1_SIZE then
  begin
    if LCache.FTier1Count < TL_TIER1_MAX then
    begin
      LCache.FTier1[LCache.FTier1Count] := ABuf;
      Inc(LCache.FTier1Count);
    end
    else
      _GlobalPushIfRoom(GTier1, POOL_TIER1_MAX, ABuf);
  end
  else if LLen = POOL_TIER2_SIZE then
  begin
    if LCache.FTier2Count < TL_TIER2_MAX then
    begin
      LCache.FTier2[LCache.FTier2Count] := ABuf;
      Inc(LCache.FTier2Count);
    end
    else
      _GlobalPushIfRoom(GTier2, POOL_TIER2_MAX, ABuf);
  end;
  // Oversized or unrecognised: let the TBytes ref-count free it naturally.
  ABuf := nil;
end;

initialization
  GTier0 := TStack<TBytes>.Create;
  GTier1 := TStack<TBytes>.Create;
  GTier2 := TStack<TBytes>.Create;

finalization
  while GTier0.Count > 0 do GTier0.Pop;
  while GTier1.Count > 0 do GTier1.Pop;
  while GTier2.Count > 0 do GTier2.Pop;
  FreeAndNil(GTier0);
  FreeAndNil(GTier1);
  FreeAndNil(GTier2);

end.
