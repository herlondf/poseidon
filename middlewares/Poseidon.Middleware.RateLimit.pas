unit Poseidon.Middleware.RateLimit;

// Simple in-memory IP-based rate limiter (fixed window).
// Thread-safe via critical section.
//
// Usage:
//   TPoseidon.Use(TPoseidonMiddlewareRateLimit.New(100, 60));
//   // max 100 requests per 60 seconds per IP

interface

uses
  System.SysUtils,
  System.Math,
  System.DateUtils,
  System.Generics.Collections,
  System.SyncObjs,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback,
  Poseidon.Commons,
  Poseidon.Exception;

type
  TPoseidonMiddlewareRateLimit = class
  public
    // AMaxRequests: max hits per window
    // AWindowSeconds: rolling window size in seconds
    // AMessage: optional custom message
    class function New(
      AMaxRequests: Integer;
      AWindowSeconds: Integer;
      const AMessage: string = 'Too Many Requests'
    ): TPoseidonCallback;
  end;

implementation

type
  TWindowEntry = record
    Count: Integer;
    WindowStart: TDateTime;
  end;

// LTable and LLock are captured by the closure and live for the application
// lifetime. They are intentionally not freed — the OS reclaims them at exit.
// Stale entries are purged once per 60s (inside the lock) to prevent unbounded
// memory growth under sustained traffic from many distinct IPs.
class function TPoseidonMiddlewareRateLimit.New(AMaxRequests, AWindowSeconds: Integer;
  const AMessage: string): TPoseidonCallback;
var
  LTable:       TDictionary<string, TWindowEntry>;
  LLock:        TCriticalSection;
  LLastCleanup: TDateTime;
begin
  LTable       := TDictionary<string, TWindowEntry>.Create(256);
  LLock        := TCriticalSection.Create;
  LLastCleanup := Now;

  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LIP:       string;
      LEntry:    TWindowEntry;
      LNow:      TDateTime;
      LElapsed:  Int64;
      LRemaining: Integer;
      LStale:    TArray<string>;
      LIdx:      Integer;
      LPair:     TPair<string, TWindowEntry>;
    begin
      LIP := Req.Headers.GetOrDefault('X-Forwarded-For',
               Req.RawWebRequest.RemoteAddr);
      LIP := LIP.Split([','])[0].Trim;

      LNow := Now;
      LLock.Enter;
      try
        // Purge entries whose window expired more than 2× ago (once per 60s).
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

      Res.Header('X-RateLimit-Limit', AMaxRequests.ToString)
         .Header('X-RateLimit-Remaining', IntToStr(Max(0, LRemaining)));

      if LRemaining < 0 then
        raise EPoseidonException.Create(AMessage, THTTPStatus.TooManyRequests);

      Next;
    end;
end;

end.
