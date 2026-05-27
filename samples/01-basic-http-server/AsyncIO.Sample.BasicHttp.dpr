program AsyncIO.Sample.BasicHttp;

// Sample 01 — Basic HTTP Server
// Demonstrates the minimal setup to run TAsyncIONativeServer.
// Covers: server creation, Listen, graceful Stop on Enter.
//
// Run:
//   AsyncIO.Sample.BasicHttp.exe
//   curl http://localhost:9001/ping
//   curl http://localhost:9001/hello/world

{$APPTYPE CONSOLE}

uses
  System.SysUtils,
  System.StrUtils,
  System.Generics.Collections,
  AsyncIO.Net.HttpServer;

const
  SERVER_PORT = 9001;

procedure HandleRequest(
  const AReq:          TAsyncIONativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string, string>>);
var
  LPath: string;
  LJson: string;
begin
  AExtraHeaders := [];
  LPath := AReq.Path;

  if LPath = '/ping' then
  begin
    AStatus      := 200;
    AContentType := 'application/json';
    LJson        := '{"message":"pong"}';
    ABody        := TEncoding.UTF8.GetBytes(LJson);
  end
  else if StartsText('/hello/', LPath) then
  begin
    AStatus      := 200;
    AContentType := 'application/json';
    LJson        := '{"hello":"' + Copy(LPath, Length('/hello/') + 1, MaxInt) + '"}';
    ABody        := TEncoding.UTF8.GetBytes(LJson);
  end
  else
  begin
    AStatus      := 404;
    AContentType := 'application/json';
    LJson        := '{"error":"not found","path":"' + LPath + '"}';
    ABody        := TEncoding.UTF8.GetBytes(LJson);
  end;
end;

var
  LServer: TAsyncIONativeServer;
begin
  LServer := TAsyncIONativeServer.Create;
  try
    Writeln('AsyncIO Sample 01 — Basic HTTP Server');
    Writeln('Listening on http://0.0.0.0:', SERVER_PORT);
    Writeln('  GET /ping        → {"message":"pong"}');
    Writeln('  GET /hello/:name → {"hello":"<name>"}');
    Writeln;

    LServer.Listen('0.0.0.0', SERVER_PORT,
      HandleRequest,
      procedure
      begin
        Writeln('Server ready. Press Enter to stop...');
        Readln;
        LServer.Stop;
      end);
  finally
    LServer.Free;
  end;
end.
