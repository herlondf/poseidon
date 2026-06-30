unit Poseidon.Middleware.HealthCheck;

// Standard health-check endpoints for Poseidon.
//
// Exposes three paths (configurable):
//   - /health        Aggregate of all registered checks
//   - /health/live   Liveness probe — server is responding (always 200 OK)
//   - /health/ready  Readiness probe — all dependencies pass their checks
//
// Liveness vs Readiness (K8s semantics):
//   * Liveness fails  → container restart
//   * Readiness fails → container removed from load-balancer rotation, NOT restarted
//
// Response shape (JSON):
//   {
//     "status": "ok" | "degraded",
//     "checks": {
//       "postgres": { "ok": true,  "ms": 3 },
//       "redis":    { "ok": false, "ms": 1200, "error": "timeout" }
//     }
//   }
//
// HTTP status:
//   200 OK              — all checks pass (or /live always)
//   503 Service Unavailable — any check fails on /health or /health/ready
//
// Usage:
//   uses Poseidon.Middleware.HealthCheck;
//
//   var H := TPoseidonMiddlewareHealthCheck.New;
//   H.AddCheck('postgres',
//     function: THealthCheckResult
//     begin
//       try MyDB.Ping; Result := THealthCheckResult.OK;
//       except on E: Exception do Result := THealthCheckResult.Failed(E.Message); end;
//     end);
//   TPoseidon.Use(H.Build);

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Callback,
  Poseidon.Proc;

type
  THealthCheckResult = record
    Healthy: Boolean;
    Error:   string;
    class function OK: THealthCheckResult; static;
    class function Failed(const AReason: string): THealthCheckResult; static;
  end;

  THealthCheckProc = reference to function: THealthCheckResult;

  TPoseidonMiddlewareHealthCheck = class
  private
    FBasePath: string;
    FChecks:   TDictionary<string, THealthCheckProc>;
  public
    constructor Create;
    destructor  Destroy; override;

    function BasePath(const APath: string): TPoseidonMiddlewareHealthCheck;
    function AddCheck(const AName: string;
      const ACheck: THealthCheckProc): TPoseidonMiddlewareHealthCheck;

    function Build: TPoseidonCallback;

    class function New: TPoseidonMiddlewareHealthCheck; static;
  end;

implementation

uses
  System.DateUtils,
  System.JSON,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Commons;

{ THealthCheckResult }

class function THealthCheckResult.OK: THealthCheckResult;
begin
  Result.Healthy := True;
  Result.Error   := '';
end;

class function THealthCheckResult.Failed(const AReason: string): THealthCheckResult;
begin
  Result.Healthy := False;
  Result.Error   := AReason;
end;

{ TPoseidonMiddlewareHealthCheck }

constructor TPoseidonMiddlewareHealthCheck.Create;
begin
  inherited Create;
  FBasePath := '/health';
  FChecks   := TDictionary<string, THealthCheckProc>.Create;
end;

destructor TPoseidonMiddlewareHealthCheck.Destroy;
begin
  FChecks.Free;
  inherited;
end;

class function TPoseidonMiddlewareHealthCheck.New: TPoseidonMiddlewareHealthCheck;
begin
  Result := TPoseidonMiddlewareHealthCheck.Create;
end;

function TPoseidonMiddlewareHealthCheck.BasePath(const APath: string): TPoseidonMiddlewareHealthCheck;
begin
  FBasePath := APath;
  Result := Self;
end;

function TPoseidonMiddlewareHealthCheck.AddCheck(const AName: string;
  const ACheck: THealthCheckProc): TPoseidonMiddlewareHealthCheck;
begin
  FChecks.AddOrSetValue(AName, ACheck);
  Result := Self;
end;

function TPoseidonMiddlewareHealthCheck.Build: TPoseidonCallback;
var
  LBase:   string;
  LChecks: TDictionary<string, THealthCheckProc>;
begin
  // Capture state into local vars for the closure. The builder retains
  // ownership of FChecks; the closure references a snapshot copy of the
  // proc map so the builder can be freed afterwards.
  LBase   := FBasePath;
  LChecks := TDictionary<string, THealthCheckProc>.Create;
  for var Pair in FChecks do
    LChecks.AddOrSetValue(Pair.Key, Pair.Value);
  Self.Free;

  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LPath:     string;
      LRoot:     TJSONObject;
      LChecksJ:  TJSONObject;
      LEntry:    TJSONObject;
      LAllOk:    Boolean;
      LStart:    TDateTime;
      LResult:   THealthCheckResult;
    begin
      LPath := Req.PathInfo;
      if LPath = LBase + '/live' then
      begin
        // Liveness — fastest possible. We're responding, that's enough.
        Res.Status(THTTPStatus.Ok).Json(
          TJSONObject.Create.AddPair('status', 'ok'));
        Exit;
      end;

      if (LPath = LBase) or (LPath = LBase + '/ready') then
      begin
        LRoot    := TJSONObject.Create;
        LChecksJ := TJSONObject.Create;
        LAllOk   := True;
        try
          for var Pair in LChecks do
          begin
            LStart := Now;
            try
              LResult := Pair.Value();
            except
              on E: Exception do
                LResult := THealthCheckResult.Failed(E.ClassName + ': ' + E.Message);
            end;
            LEntry := TJSONObject.Create
              .AddPair('ok', TJSONBool.Create(LResult.Healthy))
              .AddPair('ms', TJSONNumber.Create(MilliSecondsBetween(Now, LStart)));
            if not LResult.Healthy then
            begin
              LAllOk := False;
              LEntry.AddPair('error', LResult.Error);
            end;
            LChecksJ.AddPair(Pair.Key, LEntry);
          end;

          if LAllOk then
            LRoot.AddPair('status', 'ok')
          else
            LRoot.AddPair('status', 'degraded');
          LRoot.AddPair('checks', LChecksJ);

          if LAllOk then
            Res.Status(THTTPStatus.Ok).Json(LRoot)
          else
            Res.Status(THTTPStatus.ServiceUnavailable).Json(LRoot);
        except
          LRoot.Free;
          raise;
        end;
        Exit;
      end;

      Next();
    end;
end;

end.
