unit Poseidon.Native.Router;

// #93: Native router — hash-map for static routes, linear scan for param routes.
//
// Static routes: O(1) lookup via TDictionary (key = 'GET/ping').
// Param routes: O(n) linear scan with segment-count filter (n = param routes, <20).
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
    FStaticRoutes: TDictionary<string, TNativeRouteEntry>;
    FParamRoutes: TList<TNativeParamRoute>;
    FGlobalMiddlewares: TArray<TNativeMiddlewareEntry>;
    FLastMatch: TNativeRouteEntry;

    class function MakeKey(const AMethod, APath: string): string; static;
    function MatchParam(const ARoute: TNativeParamRoute; const APath: string;
      var ACtx: TNativeRequestContext): Boolean;
  public
    constructor Create;
    destructor Destroy; override;

    // Register a static or parameterized route
    procedure AddRoute(const AMethod, APath: string;
      const AEntry: TNativeRouteEntry);

    // Register a global middleware
    procedure AddGlobalMiddleware(const AEntry: TNativeMiddlewareEntry);

    // Lookup: returns pointer to route entry, nil if not found.
    // For param routes, populates ACtx.Params.
    function Lookup(const AMethod, APath: string;
      var ACtx: TNativeRequestContext): PNativeRouteEntry;

    // Global middlewares (read-only)
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
  FStaticRoutes := TDictionary<string, TNativeRouteEntry>.Create;
  FParamRoutes  := TList<TNativeParamRoute>.Create;
end;

destructor TNativeRouter.Destroy;
begin
  FreeAndNil(FParamRoutes);
  FreeAndNil(FStaticRoutes);
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
begin
  LHasParam := Pos(':', APath) > 0;

  if not LHasParam then
  begin
    FStaticRoutes.AddOrSetValue(MakeKey(AMethod, APath), AEntry);
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
  LEntry: TNativeRouteEntry;
  I: Integer;
begin
  if FStaticRoutes.TryGetValue(MakeKey(AMethod, APath), LEntry) then
  begin
    FLastMatch := LEntry;
    Result := @FLastMatch;
    Exit;
  end;

  for I := 0 to FParamRoutes.Count - 1 do
  begin
    if not SameText(FParamRoutes[I].Method, AMethod) then Continue;
    if MatchParam(FParamRoutes[I], APath, ACtx) then
    begin
      Result := @FParamRoutes.List[I].Entry;
      Exit;
    end;
  end;

  Result := nil;
end;

function TNativeRouter.MatchParam(const ARoute: TNativeParamRoute;
  const APath: string; var ACtx: TNativeRequestContext): Boolean;
var
  LSegments: TArray<string>;
  I, LPIdx: Integer;
  LParams: TArray<TPair<string,string>>;
begin
  Result := False;
  LSegments := APath.Split(['/'], TStringSplitOptions.ExcludeEmpty);
  if Length(LSegments) <> ARoute.SegmentCount then Exit;

  LPIdx := 0;
  SetLength(LParams, Length(ARoute.Entry.ParamNames));
  for I := 0 to ARoute.SegmentCount - 1 do
  begin
    if ARoute.Segments[I].StartsWith(':') then
    begin
      LParams[LPIdx] := TPair<string,string>.Create(
        ARoute.Entry.ParamNames[LPIdx], LSegments[I]);
      Inc(LPIdx);
    end
    else if not SameText(ARoute.Segments[I], LSegments[I]) then
      Exit;
  end;

  ACtx.Params := LParams;
  Result := True;
end;

end.
