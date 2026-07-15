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
  const ATrustedProxies: TArray<string> = nil;
  AMaxTrackedKeys: Integer = 100000): TNativeMiddlewareFunc;

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

const
  // Longest textual IP (IPv6 with embedded IPv4 + zone) is 45 chars — an
  // X-Forwarded-For token longer than this is not a real address; cap it so a
  // malicious multi-KB XFF value can't bloat per-entry key memory (#209).
  CMaxKeyLen = 45;

type
  TWindowEntry = record
    Count: Integer;
    WindowStart: TDateTime;
  end;

function RateLimitMiddleware(AMaxRequests: Integer; AWindowSeconds: Integer;
  const AMessage: string;
  ATrustProxy: Boolean;
  const ATrustedProxies: TArray<string>;
  AMaxTrackedKeys: Integer): TNativeMiddlewareFunc;
var
  LTable: TDictionary<string, TWindowEntry>;
  LLock: TCriticalSection;
  LLastCleanup: TDateTime;
  LTrustProxy: Boolean;
  LTrustedProxies: TArray<string>;
  LMaxKeys: Integer;
begin
  LTable := TDictionary<string, TWindowEntry>.Create(256);
  LLock := TCriticalSection.Create;
  LLastCleanup := Now;
  LTrustProxy := ATrustProxy and (Length(ATrustedProxies) > 0);
  LTrustedProxies := ATrustedProxies;
  LMaxKeys := AMaxTrackedKeys;
  if LMaxKeys < 1 then LMaxKeys := 100000;

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
          begin
            LIP := LXFF.Split([','])[0].Trim;
            // Reject an implausible (empty/oversized) XFF token — a client-
            // controlled multi-KB value would otherwise become a huge map key.
            if (LIP = '') or (Length(LIP) > CMaxKeyLen) then
              LIP := ACtx.RemoteAddr;
          end;
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
          // New key. An unbounded map is itself a memory-DoS: a distinct-key
          // flood (IPv6 source rotation, spoofed XFF) inserts one live entry per
          // request. At the cap, force ONE amortized stale sweep (gated by
          // LLastCleanup so the flood can't turn it into an O(n)/request cost);
          // if still full, fail closed (429) for the new key instead of growing.
          if LTable.Count >= LMaxKeys then
          begin
            if SecondsBetween(LNow, LLastCleanup) >= 5 then
            begin
              SetLength(LStale, 0);
              for LPair in LTable do
                if SecondsBetween(LNow, LPair.Value.WindowStart) >= AWindowSeconds then
                begin
                  LIdx := Length(LStale);
                  SetLength(LStale, LIdx + 1);
                  LStale[LIdx] := LPair.Key;
                end;
              for LIdx := 0 to High(LStale) do
                LTable.Remove(LStale[LIdx]);
              LLastCleanup := LNow;
            end;
          end;
          if LTable.Count >= LMaxKeys then
            LEntry.Count := AMaxRequests + 1  // over limit → 429 below, no insert
          else
          begin
            LEntry.Count := 1;
            LEntry.WindowStart := LNow;
            LTable.Add(LIP, LEntry);
          end;
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
