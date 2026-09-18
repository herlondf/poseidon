program bench_horse;

// Minimal Horse (epoll provider) contender for the framework comparison.
// Serves the three TechEmpower-style endpoints (/plaintext, /json,
// /json-large ~62KB). Dual-compiler (Delphi/FPC) - Horse.Provider.Epoll.pas
// already has {$IFDEF FPC} guards throughout, so only this wrapper needed
// porting.
//
// Under real FPC, THorseCallback (Horse.Callback.pas) is NOT the closure
// (`reference to procedure`) it is under Delphi - it's a record wrapping a
// raw Pointer, with implicit conversion FROM THorseCallbackProc, a PLAIN
// `procedure(...)` (no `of object`, no closure). That only accepts a bare
// function pointer, not a bound method and not a closure literal - hence
// plain global procedures below, no handler class, no captured state
// besides the one global GLarge (module-level, not instance state, so a
// bare function pointer can still reach it).

{$APPTYPE CONSOLE}
{$IFDEF FPC}{$MODE DELPHIUNICODE}{$H+}{$ENDIF}
{$DEFINE HORSE_PROVIDER_EPOLL}

uses
  {$IFDEF FPC}
  {$IFDEF UNIX}cthreads,{$ENDIF}
  SysUtils,
  Classes,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  {$ENDIF}
  Horse;

var
  GLarge: string;

function LoadText(const APath: string): string;
var
  LFS: TFileStream;
  LBytes: TBytes;
begin
  LFS := TFileStream.Create(APath, fmOpenRead or fmShareDenyWrite);
  try
    SetLength(LBytes, LFS.Size);
    if LFS.Size > 0 then
      LFS.ReadBuffer(LBytes[0], LFS.Size);
  finally
    LFS.Free;
  end;
  Result := TEncoding.UTF8.GetString(LBytes);
end;

procedure HandlePlaintext(Req: THorseRequest; Res: THorseResponse; Next: TNextProc);
begin
  Res.ContentType('text/plain').Send('Hello, World!');
end;

procedure HandleJson(Req: THorseRequest; Res: THorseResponse; Next: TNextProc);
begin
  Res.ContentType('application/json').Send('{"message":"Hello, World!"}');
end;

procedure HandleJsonLarge(Req: THorseRequest; Res: THorseResponse; Next: TNextProc);
begin
  Res.ContentType('application/json').Send(GLarge);
end;

begin
  GLarge := LoadText('/app/large.json');

  THorse.Get('/plaintext', HandlePlaintext);
  THorse.Get('/json', HandleJson);
  THorse.Get('/json-large', HandleJsonLarge);

  THorse.Listen(8080);
  // The epoll provider's Listen starts worker threads and RETURNS (non-blocking),
  // so keep the main thread alive or the process exits and tears the workers down.
  while True do
    TThread.Sleep(3600000);
end.
