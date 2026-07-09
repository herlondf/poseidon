unit Poseidon.Middleware.CORS;

// Usage:
//   App.Use(CORSMiddleware);
//   App.Use(CORSMiddleware(MyCORSOptions));

interface

uses
  Poseidon.Native.Types;

type
  TCORSOptions = record
    AllowOrigin: string;
    AllowMethods: string;
    AllowHeaders: string;
    ExposeHeaders: string;
    AllowCredentials: Boolean;
    MaxAge: Integer;
  end;

function CORSMiddleware: TNativeMiddlewareFunc; overload;
function CORSMiddleware(const AOptions: TCORSOptions): TNativeMiddlewareFunc; overload;
function DefaultCORSOptions: TCORSOptions;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

function DefaultCORSOptions: TCORSOptions;
begin
  Result.AllowOrigin := '*';
  Result.AllowMethods := 'GET, POST, PUT, DELETE, PATCH, HEAD, OPTIONS';
  Result.AllowHeaders := 'Content-Type, Authorization, Accept';
  Result.ExposeHeaders := '';
  Result.AllowCredentials := False;
  Result.MaxAge := 86400;
end;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function CORSMiddleware(const AOptions: TCORSOptions): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      AddHeader(ACtx, 'Access-Control-Allow-Origin', AOptions.AllowOrigin);
      AddHeader(ACtx, 'Access-Control-Allow-Methods', AOptions.AllowMethods);
      AddHeader(ACtx, 'Access-Control-Allow-Headers', AOptions.AllowHeaders);

      if AOptions.ExposeHeaders <> '' then
        AddHeader(ACtx, 'Access-Control-Expose-Headers', AOptions.ExposeHeaders);

      if AOptions.AllowCredentials then
        AddHeader(ACtx, 'Access-Control-Allow-Credentials', 'true');

      if AOptions.MaxAge > 0 then
        AddHeader(ACtx, 'Access-Control-Max-Age', IntToStr(AOptions.MaxAge));

      if SameText(ACtx.Method, 'OPTIONS') then
      begin
        ACtx.Status := 204;
        ACtx.Body := nil;
        ACtx.Handled := True;
        Exit;
      end;

      ANext();
    end;
end;

function CORSMiddleware: TNativeMiddlewareFunc;
begin
  Result := CORSMiddleware(DefaultCORSOptions);
end;

end.
