unit Poseidon.Core.RouterTree;

interface

uses
  Web.HTTPApp,
  System.SysUtils,
  System.Generics.Collections,
  System.RegularExpressions,
  Poseidon.Proc,
  Poseidon.Commons,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback;

type
  PPoseidonRouterTree = ^TPoseidonRouterTree;

  TPoseidonRouterTree = class
  strict private
    FPrefix: string;
    FIsInitialized: Boolean;
    function BuildQueue(APath: string; AUsePrefix: Boolean = True): TQueue<string>;
    function BuildSegments(const APath: string): TArray<string>;
    function ForceChild(const AKey: string): TPoseidonRouterTree;
  private
    FPart: string;
    FTag: string;
    FIsParamKey: Boolean;
    FRouterRegex: string;
    FIsRouterRegex: Boolean;
    FMiddleware: TList<TPoseidonCallback>;
    FParamKeys: TList<string>;
    FCallBack: TObjectDictionary<TMethodType, TList<TPoseidonCallback>>;
    FChildren: TObjectDictionary<string, TPoseidonRouterTree>;
    procedure RegisterInternal(AMethod: TMethodType; var APath: TQueue<string>;
      ACallback: TPoseidonCallback; const AFullPath: string);
    procedure RegisterMiddlewareInternal(var APath: TQueue<string>; AMiddleware: TPoseidonCallback);
    function ExecuteInternal(const ASegs: TArray<string>; AIdx: Integer; AMethod: TMethodType;
      ARequest: TPoseidonRequest; AResponse: TPoseidonResponse; AIsGroup: Boolean = False): Boolean;
    function CallNextChild(const ASegs: TArray<string>; AIdx: Integer; const AMethod: TMethodType;
      const ARequest: TPoseidonRequest; const AResponse: TPoseidonResponse): Boolean;
    function HasNext(AMethod: TMethodType; const APaths: TArray<string>; AIndex: Integer = 0): Boolean;
    function LiteralScore(AMethod: TMethodType; const APaths: TArray<string>; AIndex: Integer = 0): Integer;
    class function NormalizeParamKey(const APart: string): string; static;
  public
    constructor Create;
    destructor Destroy; override;

    procedure SetPrefix(const APrefix: string);
    function GetPrefix: string;

    procedure RegisterRoute(AMethod: TMethodType; const APath: string; ACallback: TPoseidonCallback);
    procedure RegisterMiddleware(const APath: string; AMiddleware: TPoseidonCallback); overload;
    procedure RegisterMiddleware(AMiddleware: TPoseidonCallback); overload;

    function Execute(ARequest: TPoseidonRequest; AResponse: TPoseidonResponse): Boolean;
    function CreateSubRouter(const APath: string): TPoseidonRouterTree;
  end;

implementation

uses
  System.TypInfo,
  Poseidon.Core.RouterTree.NextCaller;

class function TPoseidonRouterTree.NormalizeParamKey(const APart: string): string;
begin
  if APart.StartsWith(':') then
    Result := ':_param'
  else
    Result := APart;
end;

constructor TPoseidonRouterTree.Create;
begin
  FMiddleware  := TList<TPoseidonCallback>.Create;
  FChildren    := TObjectDictionary<string, TPoseidonRouterTree>.Create([doOwnsValues]);
  FParamKeys   := TList<string>.Create;
  FCallBack    := TObjectDictionary<TMethodType, TList<TPoseidonCallback>>.Create([doOwnsValues]);
  FPrefix      := '';
  FIsRouterRegex := False;
end;

destructor TPoseidonRouterTree.Destroy;
begin
  FMiddleware.Free;
  FChildren.Free;
  FParamKeys.Free;
  FCallBack.Free;
  inherited;
end;

procedure TPoseidonRouterTree.SetPrefix(const APrefix: string);
begin
  FPrefix := '/' + APrefix.Trim(['/']);
end;

function TPoseidonRouterTree.GetPrefix: string;
begin
  Result := FPrefix;
end;

function TPoseidonRouterTree.BuildQueue(APath: string; AUsePrefix: Boolean): TQueue<string>;
// Scans APath character-by-character emitting segments directly into the
// queue — avoids the TArray<string> allocation that `APath.Split(['/'])`
// produces on every request lookup.
var
  I, LStart, LLen: Integer;
  LPart:           string;
begin
  Result := TQueue<string>.Create;
  if AUsePrefix then
    if APath.StartsWith('/') then
      APath := FPrefix + APath
    else
      APath := FPrefix + '/' + APath;

  LLen := Length(APath);
  if LLen = 0 then
  begin
    Result.Enqueue('');
    Exit;
  end;

  LStart := 1;
  for I := 1 to LLen do
  begin
    if APath[I] = '/' then
    begin
      if I > LStart then
        LPart := Copy(APath, LStart, I - LStart)
      else
        LPart := '';
      // Match original behavior: skip empties except the first one
      if (Result.Count = 0) or not LPart.IsEmpty then
        Result.Enqueue(LPart);
      LStart := I + 1;
    end;
  end;
  // Trailing segment after the last '/'
  if LStart <= LLen then
    Result.Enqueue(Copy(APath, LStart, LLen - LStart + 1));
end;

function TPoseidonRouterTree.BuildSegments(const APath: string): TArray<string>;
var
  I, LStart, LLen, LCount: Integer;
  LPart: string;
begin
  LLen := Length(APath);
  if LLen = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := '';
    Exit;
  end;
  SetLength(Result, 8);
  LCount := 0;
  LStart := 1;
  for I := 1 to LLen do
  begin
    if APath[I] = '/' then
    begin
      if I > LStart then
        LPart := Copy(APath, LStart, I - LStart)
      else
        LPart := '';
      if (LCount = 0) or (LPart <> '') then
      begin
        if LCount = Length(Result) then
          SetLength(Result, LCount * 2);
        Result[LCount] := LPart;
        Inc(LCount);
      end;
      LStart := I + 1;
    end;
  end;
  if LStart <= LLen then
  begin
    if LCount = Length(Result) then
      SetLength(Result, LCount + 1);
    Result[LCount] := Copy(APath, LStart, LLen - LStart + 1);
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

function TPoseidonRouterTree.ForceChild(const AKey: string): TPoseidonRouterTree;
begin
  if not FChildren.TryGetValue(AKey, Result) then
  begin
    Result := TPoseidonRouterTree.Create;
    FChildren.Add(AKey, Result);
  end;
end;

function TPoseidonRouterTree.CreateSubRouter(const APath: string): TPoseidonRouterTree;
begin
  Result := ForceChild(APath);
end;

procedure TPoseidonRouterTree.RegisterRoute(AMethod: TMethodType; const APath: string; ACallback: TPoseidonCallback);
var
  LQueue: TQueue<string>;
begin
  LQueue := BuildQueue(APath);
  try
    RegisterInternal(AMethod, LQueue, ACallback, APath);
  finally
    LQueue.Free;
  end;
end;

procedure TPoseidonRouterTree.RegisterMiddleware(const APath: string; AMiddleware: TPoseidonCallback);
var
  LQueue: TQueue<string>;
begin
  LQueue := BuildQueue(APath);
  try
    RegisterMiddlewareInternal(LQueue, AMiddleware);
  finally
    LQueue.Free;
  end;
end;

procedure TPoseidonRouterTree.RegisterMiddleware(AMiddleware: TPoseidonCallback);
begin
  FMiddleware.Add(AMiddleware);
end;

procedure TPoseidonRouterTree.RegisterInternal(AMethod: TMethodType; var APath: TQueue<string>;
  ACallback: TPoseidonCallback; const AFullPath: string);
var
  LNormKey: string;
  LChild: TPoseidonRouterTree;
  LCallbacks: TList<TPoseidonCallback>;
  LRaw: string;
begin
  if not FIsInitialized then
  begin
    LRaw := APath.Dequeue;
    FPart := LRaw;
    FIsParamKey := FPart.StartsWith(':');
    FTag := FPart.Substring(1);
    FIsRouterRegex := FPart.StartsWith('(') and FPart.EndsWith(')');
    FRouterRegex := FPart;
    FIsInitialized := True;
  end
  else
    APath.Dequeue;

  if APath.Count = 0 then
  begin
    if FCallBack.TryGetValue(AMethod, LCallbacks) then
      raise Exception.CreateFmt('Duplicate route: [%s] %s', [GetEnumName(TypeInfo(TMethodType), Ord(AMethod)), AFullPath]);
    LCallbacks := TList<TPoseidonCallback>.Create;
    FCallBack.Add(AMethod, LCallbacks);
    LCallbacks.Add(ACallback);
    Exit;
  end;

  LNormKey := NormalizeParamKey(APath.Peek);
  LChild := ForceChild(LNormKey);
  LChild.RegisterInternal(AMethod, APath, ACallback, AFullPath);
  if LChild.FIsParamKey or LChild.FIsRouterRegex then
    if not FParamKeys.Contains(LNormKey) then
      FParamKeys.Add(LNormKey);
end;

procedure TPoseidonRouterTree.RegisterMiddlewareInternal(var APath: TQueue<string>; AMiddleware: TPoseidonCallback);
begin
  APath.Dequeue;
  if APath.Count = 0 then
    FMiddleware.Add(AMiddleware)
  else
    ForceChild(APath.Peek).RegisterMiddlewareInternal(APath, AMiddleware);
end;

function TPoseidonRouterTree.Execute(ARequest: TPoseidonRequest; AResponse: TPoseidonResponse): Boolean;
var
  LSegs: TArray<string>;
begin
  LSegs := BuildSegments(ARequest.PathInfo);
  Result := ExecuteInternal(LSegs, 0, ARequest.MethodType, ARequest, AResponse);
  if not Result then
  begin
    LSegs := TArray<string>.Create('', '*');
    Result := ExecuteInternal(LSegs, 0, ARequest.MethodType, ARequest, AResponse);
    if Result and (AResponse.StatusCode = THTTPStatus.MethodNotAllowed.ToInteger) then
      AResponse.Send('Not Found').Status(THTTPStatus.NotFound);
  end;
end;

function TPoseidonRouterTree.ExecuteInternal(const ASegs: TArray<string>; AIdx: Integer;
  AMethod: TMethodType;
  ARequest: TPoseidonRequest; AResponse: TPoseidonResponse; AIsGroup: Boolean): Boolean;
var
  LCaller: TNextCaller;
begin
  Result := False;
  LCaller := TNextCaller.Create;
  try
    LCaller
      .SetCallbacks(FCallBack)
      .SetPath(ASegs, AIdx)
      .SetMethod(AMethod)
      .SetRequest(ARequest)
      .SetResponse(AResponse)
      .SetIsGroup(AIsGroup)
      .SetMiddleware(FMiddleware)
      .SetTag(FTag)
      .SetIsParamsKey(FIsParamKey)
      .SetOnCallNextPath(CallNextChild)
      .SetFound(Result)
      .Init
      .Next;
  finally
    LCaller.Free;
  end;
end;

function TPoseidonRouterTree.CallNextChild(const ASegs: TArray<string>; AIdx: Integer;
  const AMethod: TMethodType;
  const ARequest: TPoseidonRequest; const AResponse: TPoseidonResponse): Boolean;
var
  LKey: string;
  LChild, LBest: TPoseidonRouterTree;
  LBestScore, LScore: Integer;
  LCurrent: string;
  LIsGroup: Boolean;
begin
  LIsGroup := False;
  LCurrent := ASegs[AIdx];
  LChild := nil;

  if not FChildren.TryGetValue(LCurrent, LChild) then
  begin
    if FChildren.TryGetValue('', LChild) then
    begin
      LIsGroup := True;
    end
    else if FParamKeys.Count > 0 then
    begin
      LBest := nil;
      LBestScore := -1;
      for LKey in FParamKeys do
      begin
        if FChildren.TryGetValue(LKey, LChild) and LChild.HasNext(AMethod, ASegs, AIdx) then
        begin
          LScore := LChild.LiteralScore(AMethod, ASegs, AIdx);
          if (LBest = nil) or (LScore > LBestScore) then
          begin
            LBest := LChild;
            LBestScore := LScore;
          end;
        end;
      end;
      if LBest <> nil then
        Exit(LBest.ExecuteInternal(ASegs, AIdx, AMethod, ARequest, AResponse));
      Exit(False);
    end
    else
      Exit(False);
  end;

  Result := LChild.ExecuteInternal(ASegs, AIdx, AMethod, ARequest, AResponse, LIsGroup);
end;

function TPoseidonRouterTree.HasNext(AMethod: TMethodType; const APaths: TArray<string>; AIndex: Integer): Boolean;
var
  LKey: string;
  LChild: TPoseidonRouterTree;
begin
  Result := False;
  if Length(APaths) <= AIndex then
    Exit;

  if (Length(APaths) - 1 = AIndex) and ((APaths[AIndex] = FPart) or FIsParamKey) then
    Exit(FCallBack.ContainsKey(AMethod) or (AMethod = mtAny));

  if FIsRouterRegex then
    Exit(TRegEx.IsMatch(APaths[AIndex], Format('^%s$', [FRouterRegex])));

  if FChildren.TryGetValue(APaths[AIndex + 1], LChild) then
    Exit(LChild.HasNext(AMethod, APaths, AIndex + 1));

  for LKey in FParamKeys do
    if FChildren.TryGetValue(LKey, LChild) and LChild.HasNext(AMethod, APaths, AIndex + 1) then
      Exit(True);
end;

function TPoseidonRouterTree.LiteralScore(AMethod: TMethodType; const APaths: TArray<string>; AIndex: Integer): Integer;
var
  LKey: string;
  LChild: TPoseidonRouterTree;
begin
  Result := 0;
  if Length(APaths) <= AIndex then
    Exit;

  if Length(APaths) - 1 = AIndex then
  begin
    if not FIsParamKey then
      Result := 1;
    Exit;
  end;

  if FChildren.TryGetValue(APaths[AIndex + 1], LChild) then
  begin
    Result := 1 + LChild.LiteralScore(AMethod, APaths, AIndex + 1);
    Exit;
  end;

  for LKey in FParamKeys do
    if FChildren.TryGetValue(LKey, LChild) and LChild.HasNext(AMethod, APaths, AIndex + 1) then
    begin
      Result := LChild.LiteralScore(AMethod, APaths, AIndex + 1);
      Exit;
    end;
end;

end.
