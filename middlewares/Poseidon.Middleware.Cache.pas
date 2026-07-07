unit Poseidon.Middleware.Cache;

// Response caching middleware with ETag / 304 Not Modified support.
//
// Features:
//   - In-memory LRU cache with configurable TTL
//   - Automatic ETag generation (MD5 hash of response body)
//   - If-None-Match → 304 Not Modified (zero-copy response)
//   - Thread-safe via TMonitor
//   - Configurable max cache size (bytes) and max entries
//
// Usage:
//   App.Use(CacheMiddleware(60, 1024*1024*50));  // 60s TTL, 50MB max

interface

uses
  Poseidon.Native.Types;

type
  TCacheOptions = record
    TTLSeconds: Integer;
    MaxBytes: Int64;
    MaxEntries: Integer;
    class function Default: TCacheOptions; static;
  end;

function CacheMiddleware(ATTLSeconds: Integer = 60;
  AMaxBytes: Int64 = 52428800): TNativeMiddlewareFunc; overload;
function CacheMiddleware(const AOptions: TCacheOptions): TNativeMiddlewareFunc; overload;

implementation

uses
  System.SysUtils,
  System.Hash,
  System.Generics.Collections;

type
  TCacheEntry = record
    Body: TBytes;
    ContentType: string;
    ETag: string;
    ExtraHeaders: TArray<TPair<string,string>>;
    Status: Integer;
    ExpiresAt: TDateTime;
  end;

  TCacheStore = class
  private
    FLock: TObject;
    FEntries: TDictionary<string, TCacheEntry>;
    FOrder: TList<string>;
    FCurrentBytes: Int64;
    FMaxBytes: Int64;
    FMaxEntries: Integer;
    procedure Evict;
  public
    constructor Create(AMaxBytes: Int64; AMaxEntries: Integer);
    destructor Destroy; override;
    function TryGet(const AKey: string; out AEntry: TCacheEntry): Boolean;
    procedure Put(const AKey: string; const AEntry: TCacheEntry);
  end;

class function TCacheOptions.Default: TCacheOptions;
begin
  Result.TTLSeconds := 60;
  Result.MaxBytes := 52428800;
  Result.MaxEntries := 10000;
end;

constructor TCacheStore.Create(AMaxBytes: Int64; AMaxEntries: Integer);
begin
  inherited Create;
  FLock := TObject.Create;
  FEntries := TDictionary<string, TCacheEntry>.Create;
  FOrder := TList<string>.Create;
  FCurrentBytes := 0;
  FMaxBytes := AMaxBytes;
  FMaxEntries := AMaxEntries;
end;

destructor TCacheStore.Destroy;
begin
  FreeAndNil(FOrder);
  FreeAndNil(FEntries);
  FreeAndNil(FLock);
  inherited;
end;

procedure TCacheStore.Evict;
var
  LKey: string;
  LEntry: TCacheEntry;
begin
  while (FOrder.Count > 0) and
    ((FCurrentBytes > FMaxBytes) or (FOrder.Count > FMaxEntries)) do
  begin
    LKey := FOrder[0];
    FOrder.Delete(0);
    if FEntries.TryGetValue(LKey, LEntry) then
    begin
      Dec(FCurrentBytes, Length(LEntry.Body));
      FEntries.Remove(LKey);
    end;
  end;
end;

function TCacheStore.TryGet(const AKey: string; out AEntry: TCacheEntry): Boolean;
begin
  TMonitor.Enter(FLock);
  try
    Result := FEntries.TryGetValue(AKey, AEntry);
    if Result then
    begin
      if Now > AEntry.ExpiresAt then
      begin
        Dec(FCurrentBytes, Length(AEntry.Body));
        FEntries.Remove(AKey);
        FOrder.Remove(AKey);
        Result := False;
      end
      else
      begin
        FOrder.Remove(AKey);
        FOrder.Add(AKey);
      end;
    end;
  finally
    TMonitor.Exit(FLock);
  end;
end;

procedure TCacheStore.Put(const AKey: string; const AEntry: TCacheEntry);
begin
  TMonitor.Enter(FLock);
  try
    if FEntries.ContainsKey(AKey) then
    begin
      Dec(FCurrentBytes, Length(FEntries[AKey].Body));
      FOrder.Remove(AKey);
    end;
    FEntries.AddOrSetValue(AKey, AEntry);
    FOrder.Add(AKey);
    Inc(FCurrentBytes, Length(AEntry.Body));
    Evict;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function GenerateETag(const ABody: TBytes): string;
begin
  if Length(ABody) = 0 then
    Result := '"0"'
  else
    Result := '"' + LowerCase(THashMD5.GetHashString(ABody)) + '"';
end;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function CacheMiddleware(ATTLSeconds: Integer; AMaxBytes: Int64): TNativeMiddlewareFunc;
var
  LOpts: TCacheOptions;
begin
  LOpts := TCacheOptions.Default;
  LOpts.TTLSeconds := ATTLSeconds;
  LOpts.MaxBytes := AMaxBytes;
  Result := CacheMiddleware(LOpts);
end;

function CacheMiddleware(const AOptions: TCacheOptions): TNativeMiddlewareFunc;
var
  LStore: TCacheStore;
  LTTL: Integer;
begin
  LStore := TCacheStore.Create(AOptions.MaxBytes, AOptions.MaxEntries);
  LTTL := AOptions.TTLSeconds;

  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LKey, LIfNoneMatch, LETag: string;
      LEntry: TCacheEntry;
    begin
      if ACtx.Method <> 'GET' then
      begin
        ANext();
        Exit;
      end;

      LKey := ACtx.Path;
      if ACtx.QueryString <> '' then
        LKey := LKey + '?' + ACtx.QueryString;

      if LStore.TryGet(LKey, LEntry) then
      begin
        LIfNoneMatch := ACtx.Header('If-None-Match');
        if (LIfNoneMatch <> '') and (LIfNoneMatch = LEntry.ETag) then
        begin
          ACtx.Status := 304;
          ACtx.Body := nil;
          AddHeader(ACtx, 'ETag', LEntry.ETag);
          ACtx.Handled := True;
          Exit;
        end;

        ACtx.Status := LEntry.Status;
        ACtx.ContentType := LEntry.ContentType;
        ACtx.Body := LEntry.Body;
        ACtx.ExtraHeaders := LEntry.ExtraHeaders;
        AddHeader(ACtx, 'ETag', LEntry.ETag);
        AddHeader(ACtx, 'X-Cache', 'HIT');
        ACtx.Handled := True;
        Exit;
      end;

      ANext();

      if (ACtx.Status >= 200) and (ACtx.Status < 300) then
      begin
        LETag := GenerateETag(ACtx.Body);
        LEntry.Body := ACtx.Body;
        LEntry.ContentType := ACtx.ContentType;
        LEntry.ETag := LETag;
        LEntry.ExtraHeaders := Copy(ACtx.ExtraHeaders);
        LEntry.Status := ACtx.Status;
        LEntry.ExpiresAt := Now + (LTTL / 86400);
        LStore.Put(LKey, LEntry);
        AddHeader(ACtx, 'ETag', LETag);
        AddHeader(ACtx, 'X-Cache', 'MISS');
      end;
    end;
end;

end.
