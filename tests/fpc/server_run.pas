program server_run;

// FPC / Win64 RUNTIME integration smoke for issue #5.
//
// server_smoke.pas proves the closure compiles+links; this proves it actually
// SERVES: it boots a real TPoseidonServer on the IOCP backend in a background
// thread, issues a real HTTP/1.1 GET over a socket, and checks the response.
// Success = the native server answers correctly when built by Free Pascal.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$H+}
{$ENDIF}

uses
  {$IFDEF FPC}
  {$IFDEF UNIX}cthreads,{$ENDIF}  // MUST be first: enables threaded RTL on Unix
  Classes,
  SysUtils,
  fphttpclient,
  {$ELSE}
  System.Classes,
  System.SysUtils,
  System.Net.HttpClient,
  {$ENDIF}
  Poseidon;

const
  CPort = 19780;
  CBase = 'http://127.0.0.1:19780';

type
  // Handler as a method (procedure-of-object) rather than an inline anonymous
  // method: FPC 3.3.1's function-reference support ICEs on a capturing closure
  // written directly in the program's main block. A method binds via the
  // TNativeHandler overload and sidesteps that.
  THandlers = class
    procedure Ping(var ACtx: TNativeRequestContext);
  end;

  TListenThread = class(TThread)
  private
    FApp: TPoseidonServer;
  public
    constructor Create(AApp: TPoseidonServer);
    procedure Execute; override;
  end;

procedure THandlers.Ping(var ACtx: TNativeRequestContext);
begin
  ACtx.Status := 200;
  ACtx.ContentType := 'text/plain';
  ACtx.Body := TEncoding.UTF8.GetBytes('pong');
end;

constructor TListenThread.Create(AApp: TPoseidonServer);
begin
  FApp := AApp;
  FreeOnTerminate := False;
  inherited Create(False);
end;

procedure TListenThread.Execute;
begin
  FApp.Listen(CPort, '127.0.0.1');
end;

var
  GOk: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; ACond: Boolean);
begin
  if ACond then
  begin
    Inc(GOk);
    Writeln('  ok   ', AName);
  end
  else
  begin
    Inc(GFail);
    Writeln(' FAIL  ', AName);
  end;
end;

// Poll the endpoint until it answers (server thread is still starting), or the
// attempt budget runs out. Returns the body of GET /ping, or '' on give-up.
function GetWithRetry(const AUrl: string; AAttempts: Integer): string;
var
  LClient: TFPHTTPClient;
  I: Integer;
begin
  Result := '';
  for I := 1 to AAttempts do
  begin
    LClient := TFPHTTPClient.Create(nil);
    try
      try
        Result := LClient.Get(AUrl);
        Exit;
      except
        on E: Exception do
          Sleep(100); // not listening yet — back off and retry
      end;
    finally
      LClient.Free;
    end;
  end;
end;

var
  GApp: TPoseidonServer;
  GThread: TListenThread;
  GHandlers: THandlers;
  GHandler: TNativeHandler;
  GBody: string;
  GStatus: Integer;
  GClient: TFPHTTPClient;
begin
  Writeln('=== Poseidon FPC server RUNTIME smoke (issue #5) ===');

  GHandlers := THandlers.Create;
  GApp := TPoseidonServer.Create;
  try
    // Assign through a typed TNativeHandler var so FPC binds the
    // procedure-of-object overload (not the reference-to one).
    GHandler := GHandlers.Ping;
    GApp.Get('/ping', GHandler);
    // No dispatch mode set here: under FPC the server defaults to SyncDispatch
    // (inline dispatch), which is clean. The async worker-pool path is
    // best-effort under FPC (compiler closure/threading bugs).

    GThread := TListenThread.Create(GApp);
    try
      // 404 path FIRST — a route that was never registered.
      GStatus := 0;
      GClient := TFPHTTPClient.Create(nil);
      try
        GClient.AllowRedirect := False;
        for GStatus := 1 to 50 do
        begin
          try
            GClient.Get(CBase + '/nope');
            Break;
          except
            on E: Exception do
              if GClient.ResponseStatusCode = 404 then Break else Sleep(100);
          end;
        end;
        GStatus := GClient.ResponseStatusCode;
      finally
        GClient.Free;
      end;
      Check('GET /nope returns 404', GStatus = 404);

      GBody := GetWithRetry(CBase + '/ping', 50); // up to ~5s
      Check('GET /ping returns pong', GBody = 'pong');
    finally
      GApp.Stop;
      GThread.WaitFor;
      GThread.Free;
    end;
  finally
    GApp.Free;
    GHandlers.Free;
  end;

  Writeln('---------------------------------------------------');
  Writeln(Format('DONE: %d ok, %d fail', [GOk, GFail]));
  if GFail > 0 then
    Halt(1);
end.
