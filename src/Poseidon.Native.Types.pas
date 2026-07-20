unit Poseidon.Native.Types;

// Native API types — zero-copy request context and handler signatures.
//
// TNativeRequestContext is stack-allocated by the dispatch pipeline.
// Fields reference the parsed TPoseidonNativeRequest without copying.
// Handlers write Status/ContentType/Body/ExtraHeaders directly.

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Generics.Collections,
  Poseidon.Compat;
  {$ELSE}
  System.SysUtils,
  System.NetEncoding,
  System.Generics.Collections;
  {$ENDIF}

type
  // --------------------------------------------------------------------------
  // Deferred (asynchronous) responses
  // --------------------------------------------------------------------------
  //
  // A handler that must wait on slow work (async DB acquire, upstream call)
  // calls Ctx.Defer to take ownership of the response. The dispatch pipeline
  // then returns WITHOUT sending — freeing the IO/worker thread — while the
  // connection is kept alive underneath. When the work finishes, the handler
  // (on ANY thread) calls Respond/RespondText on the returned responder to send
  // the reply and re-arm the connection.
  //
  // This is what makes SyncDispatch (inline-on-IO-thread) safe under load: an
  // async acquire yields the event loop instead of blocking it.
  //
  // Contract:
  //   * Respond/RespondText/Fail may be called exactly once, from any thread.
  //   * If the responder is dropped without ever responding, the connection is
  //     force-closed (never left hanging).
  //   * Middleware-added headers present at Defer time are preserved and merged
  //     with those passed to Respond.
  IPoseidonResponder = interface
    ['{B7E4B2A0-5C3D-4E7F-9A1B-2C8D6E0F1A34}']
    // Send the deferred reply with a raw body. AExtra is merged over the
    // headers captured at Defer time (app values win on key collision).
    procedure Respond(AStatus: Integer; const AContentType: string;
      const ABody: TBytes; const AExtra: TArray<TPair<string,string>>);
    // Send the deferred reply with a string body (UTF-8 encoded).
    procedure RespondText(AStatus: Integer; const AContentType, ABody: string);
    // Convenience: send an error (text/plain) reply.
    procedure Fail(AStatus: Integer; const AMessage: string);
  end;

  // Server-supplied factory that mints a responder bound to the connection
  // currently being dispatched on this thread. Installed by the native server
  // at unit init; nil when no native server is active. ABaseExtra carries the
  // headers accumulated on the context (e.g. by CORS middleware) at Defer time.
  TPoseidonDeferHook = reference to function(
    const ABaseExtra: TArray<TPair<string,string>>): IPoseidonResponder;

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
    // Set by Defer — tells the pipeline to skip the synchronous send.
    Deferred: Boolean;

    // Convenience: get param by name
    function Param(const AName: string): string;
    // Convenience: get header by name
    function Header(const AName: string): string;
    // Convenience: get query param by name
    function Query(const AName: string): string;
    // Take ownership of the response for asynchronous completion. Returns a
    // responder to call (from any thread) when the work finishes. Raises if
    // deferred responses are unavailable (no active server / HTTP/2 request).
    function Defer: IPoseidonResponder;
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

var
  // Installed by Poseidon.Net.HttpServer at unit initialization.
  GPoseidonDeferHook: TPoseidonDeferHook;

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
    if (Length(LPair) = 2) and SameText(TNetEncoding.URL.Decode(LPair[0]), AName) then
      Exit(TNetEncoding.URL.Decode(LPair[1]));
  end;
end;

function TNativeRequestContext.Defer: IPoseidonResponder;
begin
  if not Assigned(GPoseidonDeferHook) then
    raise Exception.Create(
      'Poseidon: deferred responses are unavailable — no active native server, ' +
      'or this is an HTTP/2 request (not yet supported).');
  // Capture headers already set on the context (e.g. by CORS middleware) so the
  // eventual async reply carries them too.
  Result := GPoseidonDeferHook(ExtraHeaders);
  Deferred := True;
  // Stop the middleware chain from progressing to a real handler after a
  // middleware defers, and mark the context handled.
  Handled := True;
end;

end.
