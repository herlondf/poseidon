unit Poseidon.Middleware.RateLimit;

// In-memory IP-based rate limiter (fixed window). Thread-safe.
//
// Usage:
//   App.Use(RateLimitMiddleware(100, 60));
//   // max 100 requests per 60 seconds per IP

interface

uses
  Poseidon.Native.Types;

function RateLimitMiddleware(AMaxRequests: Integer; AWindowSeconds: Integer;
  const AMessage: string = 'Too Many Requests';
  ATrustProxy: Boolean = False;
  const ATrustedProxies: TArray<string> = nil): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Math,
  System.DateUtils,
  System.Generics.Collections,
  System.SyncObjs,
  Poseidon.Exception,
  Poseidon.Status,
  Poseidon.Net.Security;

type
  TWindowEntry = record
    Count: Integer;
    WindowStart: TDateTime;
  end;

function RateLimitMiddleware(AMaxRequests: Integer; AWindowSeconds: Integer;
  const AMessage: string;
  ATrustProxy: Boolean;
  const ATrustedProxies: TArray<string>): TNativeMiddlewareFunc;
var
  LTable: TDictionary<string, TWindowEntry>;
  LLock: TCriticalSection;
  LLastCleanup: TDateTime;
  LTrustProxy: Boolean;
  LTrustedProxies: TArray<string>;
begin
  LTable := TDictionary<string, TWindowEntry>.Create(256);
  LLock := TCriticalSection.Create;
  LLastCleanup := Now;
  LTrustProxy := ATrustProxy and (Length(ATrustedProxies) > 0);
  LTrustedProxies := ATrustedProxies;

  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LIP: string;
      LXFF: string;
      LEntry: TWindowEntry;
      LNow: TDateTime;
      LElapsed: Int64;
      LRemaining: Integer;
      LStale: TArray<string>;
      LIdx: Integer;
      LPair: TPair<string, TWindowEntry>;
      LLen: Integer;
      LPeerTrusted: Boolean;
      LCIDRIdx: Integer;
    begin
      LIP := ACtx.RemoteAddr;
      if LTrustProxy then
      begin
        LPeerTrusted := False;
        for LCIDRIdx := 0 to High(LTrustedProxies) do
          if IsIPInCIDR(ACtx.RemoteAddr, LTrustedProxies[LCIDRIdx]) then
          begin
            LPeerTrusted := True;
            Break;
          end;
        if LPeerTrusted then
        begin
          LXFF := ACtx.Header('X-Forwarded-For');
          if LXFF <> '' then
            LIP := LXFF.Split([','])[0].Trim;
        end;
      end;

      LNow := Now;
      LLock.Enter;
      try
        if SecondsBetween(LNow, LLastCleanup) >= 60 then
        begin
          SetLength(LStale, 0);
          for LPair in LTable do
            if SecondsBetween(LNow, LPair.Value.WindowStart) > 2 * AWindowSeconds then
            begin
              LIdx := Length(LStale);
              SetLength(LStale, LIdx + 1);
              LStale[LIdx] := LPair.Key;
            end;
          for LIdx := 0 to High(LStale) do
            LTable.Remove(LStale[LIdx]);
          LLastCleanup := LNow;
        end;

        if LTable.TryGetValue(LIP, LEntry) then
        begin
          LElapsed := SecondsBetween(LNow, LEntry.WindowStart);
          if LElapsed >= AWindowSeconds then
          begin
            LEntry.Count := 1;
            LEntry.WindowStart := LNow;
          end
          else
            Inc(LEntry.Count);
          LTable[LIP] := LEntry;
        end
        else
        begin
          LEntry.Count := 1;
          LEntry.WindowStart := LNow;
          LTable.Add(LIP, LEntry);
        end;
        LRemaining := AMaxRequests - LEntry.Count;
      finally
        LLock.Leave;
      end;

      LLen := Length(ACtx.ExtraHeaders);
      SetLength(ACtx.ExtraHeaders, LLen + 2);
      ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(
        'X-RateLimit-Limit', IntToStr(AMaxRequests));
      ACtx.ExtraHeaders[LLen + 1] := TPair<string,string>.Create(
        'X-RateLimit-Remaining', IntToStr(Max(0, LRemaining)));

      if LRemaining < 0 then
        raise EPoseidonException.Create(AMessage, THTTPStatus.TooManyRequests);

      ANext();
    end;
end;

end.
