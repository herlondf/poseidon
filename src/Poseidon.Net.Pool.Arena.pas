unit Poseidon.Net.Pool.Arena;

// THeaderArena — thread-local reusable TBytes for HTTP response headers.
//
// Eliminates TBufferPool.Acquire/Release overhead in the hot dispatch path.
// Each IO thread has one persistent TBytes that grows to accommodate the
// largest response header and is reused across requests.
//
// Safe because SyncDispatch processes one request at a time per thread,
// and writev() consumes the buffer synchronously before the next request.
// For async dispatch, falls back to TBufferPool (caller checks).

interface

uses
  {$IFDEF FPC}
  SysUtils;
  {$ELSE}
  System.SysUtils;
  {$ENDIF}

type
  THeaderArena = class
  public
    // Get the thread-local header buffer, ensuring it has at least AMinSize bytes.
    // Caller writes into Result[0..N-1]. Buffer is valid until next Acquire call.
    // Do NOT call TBufferPool.Release on the returned TBytes.
    class function Acquire(AMinSize: Integer): TBytes; static;
  end;

implementation

threadvar
  GHdrBuf: TBytes;

class function THeaderArena.Acquire(AMinSize: Integer): TBytes;
begin
  if Length(GHdrBuf) < AMinSize then
    SetLength(GHdrBuf, AMinSize + 512);  // grow with headroom
  Result := GHdrBuf;
end;

end.
