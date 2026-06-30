unit Poseidon.Core.RouterTree.NextCaller;

interface

uses
  Web.HTTPApp,
  System.Generics.Collections,
  Poseidon.Proc,
  Poseidon.Commons,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback;

type
  TNextCaller = class
  private
    FIndex: Integer;
    FIndexCallback: Integer;
    FSegs: TArray<string>;
    FSegIdx: Integer;
    FMethod: TMethodType;
    FRequest: TPoseidonRequest;
    FResponse: TPoseidonResponse;
    FMiddleware: TList<TPoseidonCallback>;
    FCallBack: TObjectDictionary<TMethodType, TList<TPoseidonCallback>>;
    FCallNextPath: TCallNextPath;
    FIsGroup: Boolean;
    FTag: string;
    FIsParamsKey: Boolean;
    FFound: ^Boolean;
  public
    function Init: TNextCaller;
    function SetCallbacks(ACallbacks: TObjectDictionary<TMethodType, TList<TPoseidonCallback>>): TNextCaller;
    function SetPath(const ASegs: TArray<string>; AIdx: Integer): TNextCaller;
    function SetMethod(AMethod: TMethodType): TNextCaller;
    function SetRequest(ARequest: TPoseidonRequest): TNextCaller;
    function SetResponse(AResponse: TPoseidonResponse): TNextCaller;
    function SetIsGroup(AIsGroup: Boolean): TNextCaller;
    function SetMiddleware(AMiddleware: TList<TPoseidonCallback>): TNextCaller;
    function SetTag(const ATag: string): TNextCaller;
    function SetIsParamsKey(AIsParamsKey: Boolean): TNextCaller;
    function SetOnCallNextPath(ACallNextPath: TCallNextPath): TNextCaller;
    function SetFound(var AFound: Boolean): TNextCaller;
    procedure Next;
  end;

implementation

uses
  System.SysUtils,
  System.NetEncoding,
  Poseidon.Exception;

function TNextCaller.Init: TNextCaller;
var
  LSegment: string;
begin
  Result := Self;
  if not FIsGroup then
  begin
    LSegment := FSegs[FSegIdx];
    Inc(FSegIdx);
  end;
  FIndex := -1;
  FIndexCallback := -1;
  if FIsParamsKey then
    FRequest.Params.AddOrSet(FTag, TNetEncoding.URL.Decode(LSegment));
end;

procedure TNextCaller.Next;
var
  LCallbacks: TList<TPoseidonCallback>;
begin
  Inc(FIndex);
  if FMiddleware.Count > FIndex then
  begin
    FFound^ := True;
    FMiddleware[FIndex](FRequest, FResponse, Next);
  end
  else if (FSegIdx >= Length(FSegs)) and Assigned(FCallBack) then
  begin
    Inc(FIndexCallback);
    if FCallBack.TryGetValue(FMethod, LCallbacks) then
    begin
      if LCallbacks.Count > FIndexCallback then
      begin
        try
          FFound^ := True;
          LCallbacks[FIndexCallback](FRequest, FResponse, Next);
        except
          on E: Exception do
          begin
            if (not (E is EPoseidonCallbackInterrupted)) and
               (not (E is EPoseidonException)) and
               (FResponse.StatusCode < THTTPStatus.BadRequest.ToInteger)
            then
              FResponse.Send('Internal Server Error').Status(THTTPStatus.InternalServerError);
            raise;
          end;
        end;
        Next;
      end;
    end
    else
    begin
      if FCallBack.Count > 0 then
      begin
        FFound^ := True;
        FResponse.Send('Method Not Allowed').Status(THTTPStatus.MethodNotAllowed);
      end
      else
        FResponse.Send('Not Found').Status(THTTPStatus.NotFound);
    end;
  end
  else
    FFound^ := FCallNextPath(FSegs, FSegIdx, FMethod, FRequest, FResponse);

  if not FFound^ then
    FResponse.Send('Not Found').Status(THTTPStatus.NotFound);
end;

function TNextCaller.SetCallbacks(ACallbacks: TObjectDictionary<TMethodType, TList<TPoseidonCallback>>): TNextCaller;
begin
  FCallBack := ACallbacks;
  Result := Self;
end;

function TNextCaller.SetFound(var AFound: Boolean): TNextCaller;
begin
  FFound := @AFound;
  Result := Self;
end;

function TNextCaller.SetIsGroup(AIsGroup: Boolean): TNextCaller;
begin
  FIsGroup := AIsGroup;
  Result := Self;
end;

function TNextCaller.SetIsParamsKey(AIsParamsKey: Boolean): TNextCaller;
begin
  FIsParamsKey := AIsParamsKey;
  Result := Self;
end;

function TNextCaller.SetMethod(AMethod: TMethodType): TNextCaller;
begin
  FMethod := AMethod;
  Result := Self;
end;

function TNextCaller.SetMiddleware(AMiddleware: TList<TPoseidonCallback>): TNextCaller;
begin
  FMiddleware := AMiddleware;
  Result := Self;
end;

function TNextCaller.SetOnCallNextPath(ACallNextPath: TCallNextPath): TNextCaller;
begin
  FCallNextPath := ACallNextPath;
  Result := Self;
end;

function TNextCaller.SetPath(const ASegs: TArray<string>; AIdx: Integer): TNextCaller;
begin
  FSegs := ASegs;
  FSegIdx := AIdx;
  Result := Self;
end;

function TNextCaller.SetRequest(ARequest: TPoseidonRequest): TNextCaller;
begin
  FRequest := ARequest;
  Result := Self;
end;

function TNextCaller.SetResponse(AResponse: TPoseidonResponse): TNextCaller;
begin
  FResponse := AResponse;
  Result := Self;
end;

function TNextCaller.SetTag(const ATag: string): TNextCaller;
begin
  FTag := ATag;
  Result := Self;
end;

end.
