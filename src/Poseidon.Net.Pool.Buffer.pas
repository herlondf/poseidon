unit Poseidon.Net.Pool.Buffer;

// P-2: Multi-tier object pool for AccumBuf buffers.
//
// Three tiers by buffer size:
//   Tier 0 —   8 KB (256 slots) — initial connection buffer, ping/small requests
//   Tier 1 —  64 KB ( 64 slots) — medium requests / uploads
//   Tier 2 — 512 KB ( 16 slots) — large responses / streaming
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

var
  GTier0: TStack<TBytes>;
  GTier1: TStack<TBytes>;
  GTier2: TStack<TBytes>;

class function TBufferPool.Acquire(ASize: Integer): TBytes;

  function PopOrAlloc(AStack: TStack<TBytes>; ABufSize: Integer): TBytes;
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
      SetLength(Result, ABufSize);
  end;

begin
  if ASize <= POOL_TIER0_SIZE then
    Result := PopOrAlloc(GTier0, POOL_TIER0_SIZE)
  else if ASize <= POOL_TIER1_SIZE then
    Result := PopOrAlloc(GTier1, POOL_TIER1_SIZE)
  else if ASize <= POOL_TIER2_SIZE then
    Result := PopOrAlloc(GTier2, POOL_TIER2_SIZE)
  else
    // Oversized: allocate directly, bypassing the pool
    SetLength(Result, ASize);
end;

class procedure TBufferPool.Release(var ABuf: TBytes);
var
  LLen: Integer;

  procedure PushIfRoom(AStack: TStack<TBytes>; AMax: Integer);
  begin
    TMonitor.Enter(AStack);
    try
      if AStack.Count < AMax then AStack.Push(ABuf);
    finally
      TMonitor.Exit(AStack);
    end;
  end;

begin
  LLen := Length(ABuf);
  if LLen = POOL_TIER0_SIZE then
    PushIfRoom(GTier0, POOL_TIER0_MAX)
  else if LLen = POOL_TIER1_SIZE then
    PushIfRoom(GTier1, POOL_TIER1_MAX)
  else if LLen = POOL_TIER2_SIZE then
    PushIfRoom(GTier2, POOL_TIER2_MAX);
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
