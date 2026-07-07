unit Poseidon.Mock.Context;

// Helper to build TNativeRequestContext for tests.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Native.Types;

type
  TContextBuilder = record
  private
    FCtx: TNativeRequestContext;
  public
    class function New: TContextBuilder; static;
    function Method(const AValue: string): TContextBuilder;
    function Path(const AValue: string): TContextBuilder;
    function QueryString(const AValue: string): TContextBuilder;
    function RemoteAddr(const AValue: string): TContextBuilder;
    function RawBody(const AValue: TBytes): TContextBuilder; overload;
    function RawBody(const AValue: string): TContextBuilder; overload;
    function Header(const AName, AValue: string): TContextBuilder;
    function Build: TNativeRequestContext;
  end;

function GetExtraHeader(const ACtx: TNativeRequestContext; const AName: string): string;
function BodyAsString(const ACtx: TNativeRequestContext): string;

implementation

class function TContextBuilder.New: TContextBuilder;
begin
  Result.FCtx := Default(TNativeRequestContext);
  Result.FCtx.Method := 'GET';
  Result.FCtx.Path := '/';
  Result.FCtx.Status := 200;
  Result.FCtx.RemoteAddr := '127.0.0.1';
end;

function TContextBuilder.Method(const AValue: string): TContextBuilder;
begin
  FCtx.Method := AValue;
  Result := Self;
end;

function TContextBuilder.Path(const AValue: string): TContextBuilder;
begin
  FCtx.Path := AValue;
  Result := Self;
end;

function TContextBuilder.QueryString(const AValue: string): TContextBuilder;
begin
  FCtx.QueryString := AValue;
  Result := Self;
end;

function TContextBuilder.RemoteAddr(const AValue: string): TContextBuilder;
begin
  FCtx.RemoteAddr := AValue;
  Result := Self;
end;

function TContextBuilder.RawBody(const AValue: TBytes): TContextBuilder;
begin
  FCtx.RawBody := AValue;
  Result := Self;
end;

function TContextBuilder.RawBody(const AValue: string): TContextBuilder;
begin
  FCtx.RawBody := TEncoding.UTF8.GetBytes(AValue);
  Result := Self;
end;

function TContextBuilder.Header(const AName, AValue: string): TContextBuilder;
var
  LLen: Integer;
begin
  LLen := Length(FCtx.Headers);
  SetLength(FCtx.Headers, LLen + 1);
  FCtx.Headers[LLen] := TPair<string,string>.Create(AName, AValue);
  Result := Self;
end;

function TContextBuilder.Build: TNativeRequestContext;
begin
  Result := FCtx;
end;

function GetExtraHeader(const ACtx: TNativeRequestContext; const AName: string): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(ACtx.ExtraHeaders) do
    if SameText(ACtx.ExtraHeaders[I].Key, AName) then
      Exit(ACtx.ExtraHeaders[I].Value);
end;

function BodyAsString(const ACtx: TNativeRequestContext): string;
begin
  if Length(ACtx.Body) = 0 then
    Result := ''
  else
    Result := TEncoding.UTF8.GetString(ACtx.Body);
end;

end.
