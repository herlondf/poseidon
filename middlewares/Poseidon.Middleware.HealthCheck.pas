unit Poseidon.Middleware.HealthCheck;

// Health-check endpoints: /health, /health/live, /health/ready
//
// Usage:
//   var H := TPoseidonHealthCheck.Create;
//   H.AddCheck('postgres', function: THealthCheckResult begin ... end);
//   App.Use(H.Build);

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Native.Types;

type
  THealthCheckResult = record
    Healthy: Boolean;
    Error: string;
    class function OK: THealthCheckResult; static;
    class function Failed(const AReason: string): THealthCheckResult; static;
  end;

  THealthCheckProc = reference to function: THealthCheckResult;

  TPoseidonHealthCheck = class
  private
    FBasePath: string;
    FChecks: TDictionary<string, THealthCheckProc>;
  public
    constructor Create;
    destructor Destroy; override;

    function BasePath(const APath: string): TPoseidonHealthCheck;
    function AddCheck(const AName: string;
      const ACheck: THealthCheckProc): TPoseidonHealthCheck;

    function Build: TNativeMiddlewareFunc;
  end;

implementation

uses
  System.DateUtils,
  System.JSON;

class function THealthCheckResult.OK: THealthCheckResult;
begin
  Result.Healthy := True;
  Result.Error := '';
end;

class function THealthCheckResult.Failed(const AReason: string): THealthCheckResult;
begin
  Result.Healthy := False;
  Result.Error := AReason;
end;

constructor TPoseidonHealthCheck.Create;
begin
  inherited Create;
  FBasePath := '/health';
  FChecks := TDictionary<string, THealthCheckProc>.Create;
end;

destructor TPoseidonHealthCheck.Destroy;
begin
  FChecks.Free;
  inherited;
end;

function TPoseidonHealthCheck.BasePath(const APath: string): TPoseidonHealthCheck;
begin
  FBasePath := APath;
  Result := Self;
end;

function TPoseidonHealthCheck.AddCheck(const AName: string;
  const ACheck: THealthCheckProc): TPoseidonHealthCheck;
begin
  FChecks.AddOrSetValue(AName, ACheck);
  Result := Self;
end;

function TPoseidonHealthCheck.Build: TNativeMiddlewareFunc;
var
  LBase: string;
  LChecks: TDictionary<string, THealthCheckProc>;
  LPair: TPair<string, THealthCheckProc>;
begin
  LBase := FBasePath;
  LChecks := TDictionary<string, THealthCheckProc>.Create;
  for LPair in FChecks do
    LChecks.AddOrSetValue(LPair.Key, LPair.Value);
  Self.Free;

  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LPath: string;
      LRoot, LChecksJ, LEntry: TJSONObject;
      LAllOk: Boolean;
      LStart: TDateTime;
      LResult: THealthCheckResult;
      LP: TPair<string, THealthCheckProc>;
    begin
      LPath := ACtx.Path;

      if LPath = LBase + '/live' then
      begin
        ACtx.Status := 200;
        ACtx.ContentType := 'application/json';
        ACtx.Body := TEncoding.UTF8.GetBytes('{"status":"ok"}');
        ACtx.Handled := True;
        Exit;
      end;

      if (LPath = LBase) or (LPath = LBase + '/ready') then
      begin
        LRoot := TJSONObject.Create;
        LChecksJ := TJSONObject.Create;
        LAllOk := True;
        try
          for LP in LChecks do
          begin
            LStart := Now;
            try
              LResult := LP.Value();
            except
              on E: Exception do
                // Do not expose the raw exception (class/message) on an
                // unauthenticated /health endpoint — it can leak internal
                // details (connection strings, paths).
                LResult := THealthCheckResult.Failed('check raised an exception');
            end;
            LEntry := TJSONObject.Create;
            LEntry.AddPair('ok', TJSONBool.Create(LResult.Healthy));
            LEntry.AddPair('ms', TJSONNumber.Create(MilliSecondsBetween(Now, LStart)));
            if not LResult.Healthy then
            begin
              LAllOk := False;
              LEntry.AddPair('error', LResult.Error);
            end;
            LChecksJ.AddPair(LP.Key, LEntry);
          end;

          if LAllOk then
            LRoot.AddPair('status', 'ok')
          else
            LRoot.AddPair('status', 'degraded');
          LRoot.AddPair('checks', LChecksJ);

          if LAllOk then
            ACtx.Status := 200
          else
            ACtx.Status := 503;
          ACtx.ContentType := 'application/json';
          ACtx.Body := TEncoding.UTF8.GetBytes(LRoot.ToJSON);
        finally
          LRoot.Free;
        end;
        ACtx.Handled := True;
        Exit;
      end;

      ANext();
    end;
end;

end.
