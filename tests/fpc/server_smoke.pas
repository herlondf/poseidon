program server_smoke;

// FPC / Win64 server-closure compile gate for issue #5 (Free Pascal port).
//
// `uses Poseidon` forces the ENTIRE server closure to compile under FPC:
// facade -> Native.Server -> HttpServer -> IO backends (IOCP/RIO on Win64),
// Connection(+Manager), Dispatcher, pools, SSL(+Manager), HTTP2(+Manager),
// WebSocket(+Manager), ProxyProtocol, SendFile, Brotli, GracefulReload.
//
// This program does not open a socket; it only proves the whole graph builds
// and links natively under FPC. Runtime behaviour is covered by smoke.pas and,
// later, an FPC integration smoke.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$H+}
{$ENDIF}

uses
  Poseidon;

var
  GServer: TPoseidonServer;
begin
  // Reference the primary type so the linker keeps the whole closure; do not
  // construct it (no listen socket in a compile gate).
  GServer := nil;
  if GServer <> nil then
    GServer.Free;
  Writeln('OK: Poseidon server closure compiles + links under FPC/Win64');
end.
