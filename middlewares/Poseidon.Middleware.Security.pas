unit Poseidon.Middleware.Security;

// Helmet-style HTTP security headers.
//
// Usage:
//   App.Use(SecurityMiddleware);
//   App.Use(SecurityMiddleware(MyOptions));

interface

uses
  Poseidon.Native.Types;

type
  TSecurityOptions = record
    HSTSMaxAge: Integer;
    HSTSIncludeSubDomains: Boolean;
    HSTSPreload: Boolean;
    CSP: string;
    XFrameOptions: string;
    XContentTypeOptions: string;
    ReferrerPolicy: string;
    PermissionsPolicy: string;
  end;

function SecurityMiddleware: TNativeMiddlewareFunc; overload;
function SecurityMiddleware(const AOptions: TSecurityOptions): TNativeMiddlewareFunc; overload;
function DefaultSecurityOptions: TSecurityOptions;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

function DefaultSecurityOptions: TSecurityOptions;
begin
  Result.HSTSMaxAge := 31536000;
  Result.HSTSIncludeSubDomains := True;
  Result.HSTSPreload := False;
  Result.CSP := 'default-src ''self''';
  Result.XFrameOptions := 'DENY';
  Result.XContentTypeOptions := 'nosniff';
  Result.ReferrerPolicy := 'strict-origin-when-cross-origin';
  Result.PermissionsPolicy := '';
end;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function SecurityMiddleware(const AOptions: TSecurityOptions): TNativeMiddlewareFunc;
var
  LHSTSValue: string;
begin
  if AOptions.HSTSMaxAge > 0 then
  begin
    LHSTSValue := 'max-age=' + IntToStr(AOptions.HSTSMaxAge);
    if AOptions.HSTSIncludeSubDomains then
      LHSTSValue := LHSTSValue + '; includeSubDomains';
    if AOptions.HSTSPreload then
      LHSTSValue := LHSTSValue + '; preload';
  end
  else
    LHSTSValue := '';

  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      ANext();

      if LHSTSValue <> '' then
        AddHeader(ACtx, 'Strict-Transport-Security', LHSTSValue);
      if AOptions.CSP <> '' then
        AddHeader(ACtx, 'Content-Security-Policy', AOptions.CSP);
      if AOptions.XFrameOptions <> '' then
        AddHeader(ACtx, 'X-Frame-Options', AOptions.XFrameOptions);
      if AOptions.XContentTypeOptions <> '' then
        AddHeader(ACtx, 'X-Content-Type-Options', AOptions.XContentTypeOptions);
      if AOptions.ReferrerPolicy <> '' then
        AddHeader(ACtx, 'Referrer-Policy', AOptions.ReferrerPolicy);
      if AOptions.PermissionsPolicy <> '' then
        AddHeader(ACtx, 'Permissions-Policy', AOptions.PermissionsPolicy);
    end;
end;

function SecurityMiddleware: TNativeMiddlewareFunc;
begin
  Result := SecurityMiddleware(DefaultSecurityOptions);
end;

end.
