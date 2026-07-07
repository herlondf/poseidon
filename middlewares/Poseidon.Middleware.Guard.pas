unit Poseidon.Middleware.Guard;

// Request guard: method whitelist, path traversal, request smuggling.
//
// Usage:
//   App.Use(GuardMiddleware);
//   App.Use(GuardMiddleware(['GET', 'POST']));

interface

uses
  Poseidon.Native.Types;

function GuardMiddleware: TNativeMiddlewareFunc; overload;
function GuardMiddleware(const AAllowedMethods: TArray<string>): TNativeMiddlewareFunc; overload;

implementation

uses
  System.SysUtils,
  Poseidon.Net.Security;

function GuardMiddleware: TNativeMiddlewareFunc;
begin
  Result := GuardMiddleware([]);
end;

function GuardMiddleware(const AAllowedMethods: TArray<string>): TNativeMiddlewareFunc;
var
  LMethods: TArray<string>;
begin
  LMethods := AAllowedMethods;
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LHasCL: Boolean;
      LTE: string;
    begin
      if Length(LMethods) > 0 then
      begin
        if not IsMethodAllowed(ACtx.Method, LMethods) then
        begin
          ACtx.Status := 405;
          ACtx.ContentType := 'application/problem+json';
          ACtx.Body := TEncoding.UTF8.GetBytes(
            '{"type":"about:blank","title":"Method Not Allowed","status":405}');
          ACtx.Handled := True;
          Exit;
        end;
      end;

      if not IsPathSafe(ACtx.Path) then
      begin
        ACtx.Status := 400;
        ACtx.ContentType := 'application/problem+json';
        ACtx.Body := TEncoding.UTF8.GetBytes(
          '{"type":"about:blank","title":"Bad Request","status":400}');
        ACtx.Handled := True;
        Exit;
      end;

      LHasCL := ACtx.Header('Content-Length') <> '';
      LTE := LowerCase(ACtx.Header('Transfer-Encoding'));
      if HasRequestSmuggling(LHasCL, Pos('chunked', LTE) > 0) then
      begin
        ACtx.Status := 400;
        ACtx.ContentType := 'application/problem+json';
        ACtx.Body := TEncoding.UTF8.GetBytes(
          '{"type":"about:blank","title":"Bad Request","status":400}');
        ACtx.Handled := True;
        Exit;
      end;

      ANext();
    end;
end;

end.
