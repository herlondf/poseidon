unit Poseidon.Native.Types;

// Native API types — zero-copy request context and handler signatures.
//
// TNativeRequestContext is stack-allocated by the dispatch pipeline.
// Fields reference the parsed TPoseidonNativeRequest without copying.
// Handlers write Status/ContentType/Body/ExtraHeaders directly.

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  PNativeRequestContext = ^TNativeRequestContext;

  TNativeRequestContext = record
    Method: string;
    Path: string;
    QueryString: string;
    RemoteAddr: string;
    RawBody: TBytes;
    KeepAlive: Boolean;
    Headers: TArray<TPair<string,string>>;
    Params: TArray<TPair<string,string>>;
    Status: Integer;
    ContentType: string;
    Body: TBytes;
    ExtraHeaders: TArray<TPair<string,string>>;
    Handled: Boolean;

    // Convenience: get param by name
    function Param(const AName: string): string;
    // Convenience: get header by name
    function Header(const AName: string): string;
    // Convenience: get query param by name
    function Query(const AName: string): string;
  end;

  TNativeHandler = procedure(var ACtx: TNativeRequestContext) of object;
  TNativeHandlerFunc = reference to procedure(var ACtx: TNativeRequestContext);

  TNativeMiddleware = procedure(var ACtx: TNativeRequestContext; ANext: TProc) of object;
  TNativeMiddlewareFunc = reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);

  TNativeMiddlewareEntry = record
    MethodPtr: TNativeMiddleware;
    FuncPtr: TNativeMiddlewareFunc;
    IsFunc: Boolean;
  end;

implementation

function TNativeRequestContext.Param(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(Params) do
    if SameText(Params[I].Key, AName) then
      Exit(Params[I].Value);
  Result := '';
end;

function TNativeRequestContext.Header(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(Headers) do
    if SameText(Headers[I].Key, AName) then
      Exit(Headers[I].Value);
  Result := '';
end;

function TNativeRequestContext.Query(const AName: string): string;
var
  LParts: TArray<string>;
  LPair: TArray<string>;
  I: Integer;
begin
  Result := '';
  if QueryString = '' then Exit;
  LParts := QueryString.Split(['&']);
  for I := 0 to High(LParts) do
  begin
    LPair := LParts[I].Split(['='], 2);
    if (Length(LPair) = 2) and SameText(LPair[0], AName) then
      Exit(LPair[1]);
  end;
end;

end.
