unit Poseidon.Net.Pool.Native;

// Thread-safe object pool for TNativeWebRequest / TNativeWebResponse pairs.
//
// Eliminates per-request heap allocation of the native adapter wrappers.
// Complements TPoseidonRequestPool (pools TPoseidonRequest/Response layer).
//
// Usage (handled internally by TPoseidonProviderNative):
//   TNativeContextPool.Acquire(AReq, AFlush, LWebReq, LWebRes);
//   try
//     ... handle request ...
//   finally
//     TNativeContextPool.Release(LWebReq, LWebRes);
//   end;
//
// When the pool is exhausted, Acquire falls back to heap allocation.

interface

uses
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer,
  Poseidon.Net.WebAdapters.Native;

type
  TNativeContextPool = class
  public
    class procedure Acquire(
      const AReq:   TPoseidonNativeRequest;
      const AFlush: TNativeFlushProc;
      out   AWebReq: TNativeWebRequest;
      out   AWebRes: TNativeWebResponse); static;
    class procedure Release(
      AWebReq: TNativeWebRequest;
      AWebRes: TNativeWebResponse); static;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

const
  MAX_POOL_SIZE = 256;

type
  TNativePair = record
    WebReq: TNativeWebRequest;
    WebRes: TNativeWebResponse;
  end;

var
  GPool: TStack<TNativePair>;

class procedure TNativeContextPool.Acquire(
  const AReq:   TPoseidonNativeRequest;
  const AFlush: TNativeFlushProc;
  out   AWebReq: TNativeWebRequest;
  out   AWebRes: TNativeWebResponse);
var
  LPair: TNativePair;
  LHave: Boolean;
begin
  TMonitor.Enter(GPool);
  try
    LHave := GPool.Count > 0;
    if LHave then
      LPair := GPool.Pop;
  finally
    TMonitor.Exit(GPool);
  end;

  if LHave then
  begin
    LPair.WebReq.Reset(AReq);
    LPair.WebRes.Reset(AFlush);
    AWebReq := LPair.WebReq;
    AWebRes := LPair.WebRes;
  end
  else
  begin
    AWebReq := TNativeWebRequest.Create(AReq);
    AWebRes := TNativeWebResponse.Create(AWebReq, AFlush);
  end;
end;

class procedure TNativeContextPool.Release(
  AWebReq: TNativeWebRequest;
  AWebRes: TNativeWebResponse);
var
  LPair:   TNativePair;
  LPooled: Boolean;
begin
  TMonitor.Enter(GPool);
  try
    LPooled := GPool.Count < MAX_POOL_SIZE;
    if LPooled then
    begin
      LPair.WebReq := AWebReq;
      LPair.WebRes := AWebRes;
      GPool.Push(LPair);
    end;
  finally
    TMonitor.Exit(GPool);
  end;
  if not LPooled then
  begin
    AWebRes.Free;
    AWebReq.Free;
  end;
end;

initialization
  GPool := TStack<TNativePair>.Create;

finalization
  while GPool.Count > 0 do
  begin
    var LPair := GPool.Pop;
    LPair.WebRes.Free;
    LPair.WebReq.Free;
  end;
  FreeAndNil(GPool);

end.
