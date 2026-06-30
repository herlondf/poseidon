unit Poseidon.Pool.CrossSocket;

// Thread-safe object pool for TCrossWebRequest / TCrossWebResponse pairs.
//
// Eliminates per-request heap allocation of the CrossSocket adapter wrappers.
// Complements TPoseidonRequestPool, which pools the TPoseidonRequest/Response layer.
//
// Usage (handled internally by TPoseidonProviderCrossSocket):
//   TCrossContextPool.Acquire(AConn, AReq, ARes, LWebReq, LWebRes);
//   try
//     ... handle request ...
//   finally
//     TCrossContextPool.Release(LWebReq, LWebRes);
//   end;
//
// When the pool is exhausted, Acquire falls back to heap allocation — the pool
// is a fast path, never a hard limit.

interface

uses
  Net.CrossHttpServer,
  Net.CrossSocket.Base,
  Poseidon.WebAdapters.CrossSocket;

type
  TCrossContextPool = class
  public
    class procedure Acquire(
      const AConnection: ICrossHttpConnection;
      const ARequest:    ICrossHttpRequest;
      const AResponse:   ICrossHttpResponse;
      out   AWebReq:     TCrossWebRequest;
      out   AWebRes:     TCrossWebResponse); static;
    class procedure Release(
      AWebReq: TCrossWebRequest;
      AWebRes: TCrossWebResponse); static;
  end;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

const
  MAX_POOL_SIZE = 256;

type
  TCrossPair = record
    WebReq: TCrossWebRequest;
    WebRes: TCrossWebResponse;
  end;

var
  GPool: TStack<TCrossPair>;

{ TCrossContextPool }

class procedure TCrossContextPool.Acquire(
  const AConnection: ICrossHttpConnection;
  const ARequest:    ICrossHttpRequest;
  const AResponse:   ICrossHttpResponse;
  out   AWebReq:     TCrossWebRequest;
  out   AWebRes:     TCrossWebResponse);
var
  LPair: TCrossPair;
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
    LPair.WebReq.Reset(AConnection, ARequest);
    LPair.WebRes.Reset(AResponse);
    AWebReq := LPair.WebReq;
    AWebRes := LPair.WebRes;
  end
  else
  begin
    AWebReq := TCrossWebRequest.Create(AConnection, ARequest);
    AWebRes := TCrossWebResponse.Create(AWebReq, AResponse);
  end;
end;

class procedure TCrossContextPool.Release(
  AWebReq: TCrossWebRequest;
  AWebRes: TCrossWebResponse);
var
  LPair:   TCrossPair;
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
  GPool := TStack<TCrossPair>.Create;

finalization
  while GPool.Count > 0 do
  begin
    var LPair := GPool.Pop;
    LPair.WebRes.Free;
    LPair.WebReq.Free;
  end;
  FreeAndNil(GPool);

end.
