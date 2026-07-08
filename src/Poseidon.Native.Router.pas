unit Poseidon.Native.Router;

// Native router — hash-map for static routes, linear scan for param routes.
//
// Static routes: O(1) lookup via TDictionary (key = 'GET/ping') → index into
//   FStaticEntries list. Returns stable pointer via List[I].
// Param routes: O(n) linear scan with segment-count filter (n = param routes, <20).
//   Path is split once before the loop to avoid repeated allocations.
// Each route entry has a pre-compiled middleware array + handler pointer.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Native.Types;

type
  PNativeRouteEntry = ^TNativeRouteEntry;
  TNativeRouteEntry = record
    Handler: TNativeHandler;
    HandlerFunc: TNativeHandlerFunc;
    Middlewares: TArray<TNativeMiddlewareEntry>;
    ParamNames: TArray<string>;
  end;

  TNativeParamRoute = record
    Method: string;
    Segments: TArray<string>;
    SegmentCount: Integer;
    Entry: TNativeRouteEntry;
  end;

  TNativeRouter = class
  private
    FStaticIndex: TDictionary<string, Integer>;
    FStaticEntries: TList<TNativeRouteEntry>;
    FParamRoutes: TList<TNativeParamRoute>;
    FGlobalMiddlewares: TArray<TNativeMiddlewareEntry>;

    class function MakeKey(const AMethod, APath: string): string; static;
    function MatchParam(const ARoute: TNativeParamRoute;
      const ASegments: TArray<string>;
      var ACtx: TNativeRequestContext): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    procedure AddRoute(const AMethod, APath: string;
      const AEntry: TNativeRouteEntry);
    procedure AddGlobalMiddleware(const AEntry: TNativeMiddlewareEntry);

    function Lookup(const AMethod, APath: string;
      var ACtx: TNativeRequestContext): PNativeRouteEntry;

    property GlobalMiddlewares: TArray<TNativeMiddlewareEntry> read FGlobalMiddlewares;
  end;

implementation

class function TNativeRouter.MakeKey(const AMethod, APath: string): string;
begin
  Result := AMethod + APath;
end;

constructor TNativeRouter.Create;
begin
  inherited Create;
  FStaticIndex := TDictionary<string, Integer>.Create;
  FStaticEntries := TList<TNativeRouteEntry>.Create;
  FParamRoutes := TList<TNativeParamRoute>.Create;
end;

destructor TNativeRouter.Destroy;
begin
  FreeAndNil(FParamRoutes);
  FreeAndNil(FStaticEntries);
  FreeAndNil(FStaticIndex);
  inherited Destroy;
end;

procedure TNativeRouter.AddRoute(const AMethod, APath: string;
  const AEntry: TNativeRouteEntry);
var
  LParamRoute: TNativeParamRoute;
  LSegments: TArray<string>;
  LNames: TArray<string>;
  I, LCount: Integer;
  LHasParam: Boolean;
  LKey: string;
  LIdx: Integer;
begin
  LHasParam := Pos(':', APath) > 0;

  if not LHasParam then
  begin
    LKey := MakeKey(AMethod, APath);
    if FStaticIndex.TryGetValue(LKey, LIdx) then
      FStaticEntries[LIdx] := AEntry
    else
    begin
      LIdx := FStaticEntries.Count;
      FStaticEntries.Add(AEntry);
      FStaticIndex.Add(LKey, LIdx);
    end;
    Exit;
  end;

  LSegments := APath.Split(['/'], TStringSplitOptions.ExcludeEmpty);
  SetLength(LNames, 0);
  LCount := 0;
  for I := 0 to High(LSegments) do
  begin
    if LSegments[I].StartsWith(':') then
    begin
      Inc(LCount);
      SetLength(LNames, LCount);
      LNames[LCount - 1] := Copy(LSegments[I], 2, MaxInt);
    end;
  end;

  LParamRoute.Method := AMethod;
  LParamRoute.Segments := LSegments;
  LParamRoute.SegmentCount := Length(LSegments);
  LParamRoute.Entry := AEntry;
  LParamRoute.Entry.ParamNames := LNames;
  FParamRoutes.Add(LParamRoute);
end;

procedure TNativeRouter.AddGlobalMiddleware(const AEntry: TNativeMiddlewareEntry);
var
  LLen: Integer;
begin
  LLen := Length(FGlobalMiddlewares);
  SetLength(FGlobalMiddlewares, LLen + 1);
  FGlobalMiddlewares[LLen] := AEntry;
end;

function TNativeRouter.Lookup(const AMethod, APath: string;
  var ACtx: TNativeRequestContext): PNativeRouteEntry;
var
  LIdx: Integer;
  I: Integer;
  LSegments: TArray<string>;
  LSegCount: Integer;
begin
  if FStaticIndex.TryGetValue(MakeKey(AMethod, APath), LIdx) then
  begin
    Result := @FStaticEntries.List[LIdx];
    Exit;
  end;

  if FParamRoutes.Count > 0 then
  begin
    LSegments := APath.Split(['/'], TStringSplitOptions.ExcludeEmpty);
    LSegCount := Length(LSegments);
    for I := 0 to FParamRoutes.Count - 1 do
    begin
      if not SameText(FParamRoutes[I].Method, AMethod) then Continue;
      if FParamRoutes[I].SegmentCount <> LSegCount then Continue;
      if MatchParam(FParamRoutes[I], LSegments, ACtx) then
      begin
        Result := @FParamRoutes.List[I].Entry;
        Exit;
      end;
    end;
  end;

  Result := nil;
end;

function TNativeRouter.MatchParam(const ARoute: TNativeParamRoute;
  const ASegments: TArray<string>;
  var ACtx: TNativeRequestContext): Boolean;
var
  I, LPIdx: Integer;
  LParams: TArray<TPair<string,string>>;
begin
  Result := False;
  LPIdx := 0;
  SetLength(LParams, Length(ARoute.Entry.ParamNames));
  for I := 0 to ARoute.SegmentCount - 1 do
  begin
    if ARoute.Segments[I].StartsWith(':') then
    begin
      LParams[LPIdx] := TPair<string,string>.Create(
        ARoute.Entry.ParamNames[LPIdx], ASegments[I]);
      Inc(LPIdx);
    end
    else if not SameText(ARoute.Segments[I], ASegments[I]) then
      Exit;
  end;

  ACtx.Params := LParams;
  Result := True;
end;

end.
