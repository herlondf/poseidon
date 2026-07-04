unit Poseidon.Pool;

// Thread-safe object pool for TPoseidonRequest / TPoseidonResponse pairs.
//
// Eliminates per-request heap allocation of wrapper objects and their
// internal TDictionary instances (via Reinitialize, which clears without freeing).
//
// Usage (handled internally by TPoseidonProviderIndyDirect):
//   TPoseidonRequestPool.Acquire(LWebReq, LWebRes, LReq, LRes);
//   try
//     ... handle request ...
//   finally
//     TPoseidonRequestPool.Release(LReq, LRes);
//   end;

interface

uses
  Web.HTTPApp,
  Poseidon.Request,
  Poseidon.Response;

type
  TPoseidonRequestPool = class
  public
    class procedure Acquire(AWebReq: TWebRequest; AWebRes: TWebResponse;
      out AReq: TPoseidonRequest; out ARes: TPoseidonResponse); static;
    class procedure Release(AReq: TPoseidonRequest; ARes: TPoseidonResponse); static;
  end;

implementation

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections;

const
  MAX_POOL_SIZE = 256;

type
  TRequestPair = record
    Req: TPoseidonRequest;
    Res: TPoseidonResponse;
  end;

var
  GPool: TStack<TRequestPair>;
  GPoolCS: TCriticalSection;

class procedure TPoseidonRequestPool.Acquire(AWebReq: TWebRequest;
  AWebRes: TWebResponse; out AReq: TPoseidonRequest; out ARes: TPoseidonResponse);
var
  LPair: TRequestPair;
  LHave: Boolean;
begin
  GPoolCS.Enter;
  try
    LHave := GPool.Count > 0;
    if LHave then
      LPair := GPool.Pop;
  finally
    GPoolCS.Leave;
  end;

  if LHave then
  begin
    AReq := LPair.Req;
    ARes := LPair.Res;
    AReq.Reinitialize(AWebReq);
    ARes.Reinitialize(AWebRes);
  end
  else
  begin
    AReq := TPoseidonRequest.Create(AWebReq);
    ARes := TPoseidonResponse.Create(AWebRes);
  end;
end;

class procedure TPoseidonRequestPool.Release(AReq: TPoseidonRequest;
  ARes: TPoseidonResponse);
var
  LPair:   TRequestPair;
  LPooled: Boolean;
begin
  GPoolCS.Enter;
  try
    LPooled := GPool.Count < MAX_POOL_SIZE;
    if LPooled then
    begin
      LPair.Req := AReq;
      LPair.Res := ARes;
      GPool.Push(LPair);
    end;
  finally
    GPoolCS.Leave;
  end;
  if not LPooled then
  begin
    AReq.Free;
    ARes.Free;
  end;
end;

initialization
  GPool := TStack<TRequestPair>.Create;
  GPoolCS := TCriticalSection.Create;

finalization
  while GPool.Count > 0 do
  begin
    var LPair := GPool.Pop;
    LPair.Req.Free;
    LPair.Res.Free;
  end;
  FreeAndNil(GPool);
  FreeAndNil(GPoolCS);

end.
