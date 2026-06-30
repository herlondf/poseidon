unit Poseidon.Middleware.Security;

// Helmet-style HTTP security headers for Poseidon.
//
// Sets defensive response headers on every request:
//   - Strict-Transport-Security  (HSTS — forces HTTPS in modern browsers)
//   - Content-Security-Policy    (CSP — limits inline JS, restricts origins)
//   - X-Frame-Options            (clickjacking protection)
//   - X-Content-Type-Options     (MIME-sniff protection)
//   - Referrer-Policy            (limits referer leakage)
//   - Permissions-Policy         (feature policy — camera, mic, etc.)
//
// Usage:
//   uses Poseidon.Middleware.Security;
//
//   // Defaults — sensible production settings:
//   TPoseidon.Use(TPoseidonMiddlewareSecurity.Defaults);
//
//   // Custom config via fluent builder:
//   TPoseidon.Use(
//     TPoseidonMiddlewareSecurity.New
//       .HSTS(31536000, True, False)
//       .CSP('default-src ''self''; img-src ''self'' data:')
//       .XFrameOptions('SAMEORIGIN')
//       .ReferrerPolicy('no-referrer'));
//
// Disabling a specific header: pass empty string to its setter, e.g.
//   .CSP('')   // omits the Content-Security-Policy header.

interface

uses
  Poseidon.Callback,
  Poseidon.Proc;

type
  TPoseidonMiddlewareSecurity = class
  private
    FHSTSMaxAge:           Integer;
    FHSTSIncludeSubDomains:Boolean;
    FHSTSPreload:          Boolean;
    FCSP:                  string;
    FXFrameOptions:        string;
    FXContentTypeOptions:  string;
    FReferrerPolicy:       string;
    FPermissionsPolicy:    string;
  public
    constructor Create;

    function HSTS(AMaxAgeSeconds: Integer; AIncludeSubDomains: Boolean = True;
      APreload: Boolean = False): TPoseidonMiddlewareSecurity;
    function CSP(const APolicy: string): TPoseidonMiddlewareSecurity;
    function XFrameOptions(const AValue: string): TPoseidonMiddlewareSecurity;
    function XContentTypeOptions(const AValue: string): TPoseidonMiddlewareSecurity;
    function ReferrerPolicy(const AValue: string): TPoseidonMiddlewareSecurity;
    function PermissionsPolicy(const AValue: string): TPoseidonMiddlewareSecurity;

    function Build: TPoseidonCallback;

    // Convenience entry points
    class function New: TPoseidonMiddlewareSecurity; static;
    class function Defaults: TPoseidonCallback; static;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Request,
  Poseidon.Response;

constructor TPoseidonMiddlewareSecurity.Create;
begin
  inherited Create;
  // Sensible defaults — safe for most production deployments.
  FHSTSMaxAge            := 31536000;  // 1 year
  FHSTSIncludeSubDomains := True;
  FHSTSPreload           := False;
  FCSP                   := 'default-src ''self''';
  FXFrameOptions         := 'DENY';
  FXContentTypeOptions   := 'nosniff';
  FReferrerPolicy        := 'strict-origin-when-cross-origin';
  FPermissionsPolicy     := '';  // off by default — opt-in per app
end;

class function TPoseidonMiddlewareSecurity.New: TPoseidonMiddlewareSecurity;
begin
  Result := TPoseidonMiddlewareSecurity.Create;
end;

class function TPoseidonMiddlewareSecurity.Defaults: TPoseidonCallback;
var
  L: TPoseidonMiddlewareSecurity;
begin
  L := TPoseidonMiddlewareSecurity.Create;
  Result := L.Build();   // explicit parens — disambiguate method-call vs method-ref
end;

function TPoseidonMiddlewareSecurity.HSTS(AMaxAgeSeconds: Integer;
  AIncludeSubDomains: Boolean; APreload: Boolean): TPoseidonMiddlewareSecurity;
begin
  FHSTSMaxAge            := AMaxAgeSeconds;
  FHSTSIncludeSubDomains := AIncludeSubDomains;
  FHSTSPreload           := APreload;
  Result := Self;
end;

function TPoseidonMiddlewareSecurity.CSP(const APolicy: string): TPoseidonMiddlewareSecurity;
begin
  FCSP := APolicy;
  Result := Self;
end;

function TPoseidonMiddlewareSecurity.XFrameOptions(const AValue: string): TPoseidonMiddlewareSecurity;
begin
  FXFrameOptions := AValue;
  Result := Self;
end;

function TPoseidonMiddlewareSecurity.XContentTypeOptions(const AValue: string): TPoseidonMiddlewareSecurity;
begin
  FXContentTypeOptions := AValue;
  Result := Self;
end;

function TPoseidonMiddlewareSecurity.ReferrerPolicy(const AValue: string): TPoseidonMiddlewareSecurity;
begin
  FReferrerPolicy := AValue;
  Result := Self;
end;

function TPoseidonMiddlewareSecurity.PermissionsPolicy(const AValue: string): TPoseidonMiddlewareSecurity;
begin
  FPermissionsPolicy := AValue;
  Result := Self;
end;

function TPoseidonMiddlewareSecurity.Build: TPoseidonCallback;
var
  LHSTSValue:        string;
  LCSP:              string;
  LXFrame:           string;
  LXContentType:     string;
  LReferrerPolicy:   string;
  LPermissionsPolicy:string;
begin
  // Capture all values at build time so the closure doesn't keep a reference
  // to Self (which lets the builder be freed safely).
  if FHSTSMaxAge > 0 then
  begin
    LHSTSValue := 'max-age=' + IntToStr(FHSTSMaxAge);
    if FHSTSIncludeSubDomains then LHSTSValue := LHSTSValue + '; includeSubDomains';
    if FHSTSPreload           then LHSTSValue := LHSTSValue + '; preload';
  end
  else
    LHSTSValue := '';
  LCSP               := FCSP;
  LXFrame            := FXFrameOptions;
  LXContentType      := FXContentTypeOptions;
  LReferrerPolicy    := FReferrerPolicy;
  LPermissionsPolicy := FPermissionsPolicy;

  // Builder can be freed by caller; closure has its own captured values.
  Self.Free;

  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      if LHSTSValue <> ''     then Res.Header('Strict-Transport-Security', LHSTSValue);
      if LCSP <> ''           then Res.Header('Content-Security-Policy', LCSP);
      if LXFrame <> ''        then Res.Header('X-Frame-Options', LXFrame);
      if LXContentType <> ''  then Res.Header('X-Content-Type-Options', LXContentType);
      if LReferrerPolicy <> ''then Res.Header('Referrer-Policy', LReferrerPolicy);
      if LPermissionsPolicy <> '' then Res.Header('Permissions-Policy', LPermissionsPolicy);
      Next();
    end;
end;

end.
