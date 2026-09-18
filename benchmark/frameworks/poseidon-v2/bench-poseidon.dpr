program bench_poseidon;

// Minimal Poseidon v2 contender for the framework comparison (#218): serves the
// three TechEmpower-style endpoints, nothing else — same contract as every other
// contender (/plaintext text, /json json, /json-large ~62KB json, port 8080,
// keep-alive). The large payload is baked into the image (/app/large.json) and
// loaded once at startup so every framework serves byte-identical bytes.
//
// Dual-compiler: builds under Delphi (dcclinux64) and Free Pascal (FPC/Linux).
// Handlers are methods (not inline anonymous methods) to sidestep an FPC 3.3.1
// codegen ICE on closures written in the program's main block.

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHIUNICODE}{$H+}{$ENDIF}

uses
  {$IFDEF FPC}
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  {$ENDIF}
  Poseidon.Native.Types,
  Poseidon.Native.Server;

type
  THandlers = class
    procedure Plaintext(var ACtx: TNativeRequestContext);
    procedure Json(var ACtx: TNativeRequestContext);
    procedure JsonLarge(var ACtx: TNativeRequestContext);
  end;

var
  GLarge: TBytes;
  GPlain: TBytes;
  GJson:  TBytes;

function LoadBytes(const APath: string): TBytes;
var
  LFS: TFileStream;
begin
  LFS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(Result, LFS.Size);
    if LFS.Size > 0 then
      LFS.ReadBuffer(Result[0], LFS.Size);
  finally
    LFS.Free;
  end;
end;

procedure THandlers.Plaintext(var ACtx: TNativeRequestContext);
begin
  ACtx.Status := 200;
  ACtx.ContentType := 'text/plain';
  ACtx.Body := GPlain;  // pre-encoded constant — same as every other contender
end;

procedure THandlers.Json(var ACtx: TNativeRequestContext);
begin
  ACtx.Status := 200;
  ACtx.ContentType := 'application/json';
  ACtx.Body := GJson;  // pre-encoded constant
end;

procedure THandlers.JsonLarge(var ACtx: TNativeRequestContext);
begin
  ACtx.Status := 200;
  ACtx.ContentType := 'application/json';
  ACtx.Body := GLarge;
end;

var
  App: TPoseidonServer;
  H: THandlers;
  HP, HJ, HJL: TNativeHandler;
begin
  GLarge := LoadBytes('/app/large.json');
  GPlain := TEncoding.UTF8.GetBytes('Hello, World!');
  GJson  := TEncoding.UTF8.GetBytes('{"message":"Hello, World!"}');
  H := THandlers.Create;
  App := TPoseidonServer.Create;
  try
    HP := H.Plaintext;   App.Get('/plaintext', HP);
    HJ := H.Json;        App.Get('/json', HJ);
    HJL := H.JsonLarge;  App.Get('/json-large', HJL);
    // Plain HTTP/1.1 request-response, non-blocking handlers -> max-throughput
    // path: dispatch inline on the completion thread (no worker-pool hand-off),
    // lightweight pipeline (no upgrade/logging). Same class of fast path other
    // contenders use.
    App.SyncDispatch := True;
    App.FastPath := True;
    App.Listen(8080, '0.0.0.0');
  finally
    App.Free;
    H.Free;
  end;
end.
