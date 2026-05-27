unit Poseidon.Net.Pool.Buffer;

// Object pool for per-connection AccumBuf buffers.
// Eliminates the SetLength(AccumBuf, 8192) heap allocation that happens on
// every connection accept. Buffers > 8KB (grown for large requests) bypass
// the pool — fast-path for small requests, slow-path for large.

interface

uses
  System.SysUtils;

const
  POOL_BUF_SIZE = 8192;
  MAX_POOL_SIZE = 256;

type
  TBufferPool = class
  public
    class function  Acquire: TBytes; static;
    class procedure Release(var ABuf: TBytes); static;
  end;

implementation

uses
  System.SyncObjs,
  System.Generics.Collections;

var
  GPool: TStack<TBytes>;

class function TBufferPool.Acquire: TBytes;
var
  LHave: Boolean;
begin
  Result := nil;
  TMonitor.Enter(GPool);
  try
    LHave := GPool.Count > 0;
    if LHave then Result := GPool.Pop;
  finally
    TMonitor.Exit(GPool);
  end;
  if not LHave then
    SetLength(Result, POOL_BUF_SIZE);
end;

class procedure TBufferPool.Release(var ABuf: TBytes);
begin
  // Only pool buffers of the standard size — larger ones (grown for big
  // requests) get freed normally to keep the pool slot turnover predictable.
  if Length(ABuf) = POOL_BUF_SIZE then
  begin
    TMonitor.Enter(GPool);
    try
      if GPool.Count < MAX_POOL_SIZE then GPool.Push(ABuf);
    finally
      TMonitor.Exit(GPool);
    end;
  end;
  ABuf := nil;   // decrement caller's ref; pool now owns it (or buffer is freed)
end;

initialization
  GPool := TStack<TBytes>.Create;

finalization
  while GPool.Count > 0 do
    GPool.Pop;
  FreeAndNil(GPool);

end.
