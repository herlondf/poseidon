program bench_mormot;

// Minimal mORMot2 contender for the framework comparison (#218). Serves exactly
// the two TechEmpower-style endpoints via mORMot2's THttpServer (thread-pool,
// keep-alive). Same contract as every other contender. Built with FPC.

{$I mormot.defines.inc}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  SysUtils,
  mormot.core.base,
  mormot.core.os,
  mormot.net.http,
  mormot.net.server;

type
  TBench = class
    function Process(Ctxt: THttpServerRequestAbstract): cardinal;
  end;

var
  glarge: RawUtf8;

function TBench.Process(Ctxt: THttpServerRequestAbstract): cardinal;
begin
  if Ctxt.Url = '/plaintext' then
  begin
    Ctxt.OutContent := 'Hello, World!';
    Ctxt.OutContentType := 'text/plain';
    result := HTTP_SUCCESS;
  end
  else if Ctxt.Url = '/json' then
  begin
    Ctxt.OutContent := '{"message":"Hello, World!"}';
    Ctxt.OutContentType := 'application/json';
    result := HTTP_SUCCESS;
  end
  else if Ctxt.Url = '/json-large' then
  begin
    Ctxt.OutContent := glarge;
    Ctxt.OutContentType := 'application/json';
    result := HTTP_SUCCESS;
  end
  else
    result := HTTP_NOTFOUND;
end;

var
  server: THttpServer;
  bench: TBench;
begin
  glarge := StringFromFile('/app/large.json');
  bench := TBench.Create;
  // '8080' port, no start/stop callbacks, process name, 8 pool threads.
  server := THttpServer.Create('8080', nil, nil, 'bench-mormot', 8);
  try
    server.OnRequest := bench.Process;
    server.WaitStarted;
    writeln('mORMot2 bench on :8080');
    while true do
      SleepHiRes(1000);
  finally
    server.Free;
    bench.Free;
  end;
end.
