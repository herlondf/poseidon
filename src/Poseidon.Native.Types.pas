unit Poseidon.Native.Types;

// #92: Native API types — zero-copy request context and handler signatures.
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

  // Stack-allocated request/response context.
  // Request fields are shared references (refcount, no copy).
  // Response fields are set by the handler.
  TNativeRequestContext = record
    // --- Request (shared references from parser) ---
    Method:       string;
    Path:         string;
    QueryString:  string;
    RemoteAddr:   string;
    RawBody:      TBytes;
    KeepAlive:    Boolean;
    Headers:      TArray<TPair<string,string>>;
    // Route params populated by router
    Params:       TArray<TPair<string,string>>;
    // --- Response (handler fills these) ---
    Status:       Integer;
    ContentType:  string;
    Body:         TBytes;
    ExtraHeaders: TArray<TPair<string,string>>;
    // --- Control ---
    Handled:      Boolean;  // True = middleware short-circuited

    // Convenience: get param by name
    function Param(const AName: string): string;
    // Convenience: get header by name
    function Header(const AName: string): string;
    // Convenience: get query param by name
    function Query(const AName: string): string;
  end;

  // Handler: procedure of object — zero heap allocation per call
  TNativeHandler = procedure(var ACtx: TNativeRequestContext) of object;
  // Handler: anonymous method — 1 closure alloc at registration, not per request
  TNativeHandlerFunc = reference to procedure(var ACtx: TNativeRequestContext);

  // Middleware with Next() — allows wrapping (timing, auth, etc.)
  // 1 closure per request for Next (vs N closures in Horse)
  TNativeMiddleware = procedure(var ACtx: TNativeRequestContext; ANext: TProc) of object;
  TNativeMiddlewareFunc = reference to procedure(var ACtx: TNativeRequestContext; ANext: TProc);

  // Internal: middleware entry in the pre-compiled pipeline
  TNativeMiddlewareEntry = record
    MethodPtr: TNativeMiddleware;
    FuncPtr:   TNativeMiddlewareFunc;
    IsFunc:    Boolean;
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
  LPair:  TArray<string>;
  I:      Integer;
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
