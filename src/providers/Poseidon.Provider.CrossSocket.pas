unit Poseidon.Provider.CrossSocket;

// HTTP provider built on Delphi-Cross-Socket (IOCP on Windows, epoll on Linux).
// Bypasses WebBroker entirely — uses TCrossWebRequest/TCrossWebResponse adapters.
// Requires vendor\Delphi-Cross-Socket in the project search path.
//
// Usage:
//   TPoseidonCrossSocket.Get('/ping', procedure(Req, Res) begin Res.Send('pong'); end);
//   TPoseidonCrossSocket.Listen(9002);

interface

uses
  System.SysUtils,
  System.SyncObjs,
  Net.CrossHttpServer,
  Net.CrossSocket.Base,
  Net.CrossSslSocket.Base,
  Poseidon.Proc,
  Poseidon.Provider.Abstract;

type
  // Forward — full definition below, after TPoseidonProviderCrossSocket.
  TCrossDispatcher = class;

  TPoseidonProviderCrossSocket = class(TPoseidonProviderAbstract)
  private const
    DEFAULT_HOST = '0.0.0.0';
    DEFAULT_PORT = 9000;
  private
    class var FPort:          Integer;
    class var FHost:          string;
    class var FRunning:       Integer;  // 0=stopped, 1=running — always via TInterlocked
    class var FShutdownEvent: TEvent;
    class var FServer:        ICrossHttpServer;
    class var FDispatcher:    TCrossDispatcher;
    class var FInFlightCount: Int64;
    class var FEnableTLS:     Boolean;
    class var FCertFile:      string;
    class var FKeyFile:       string;

    class function GetOrCreateEvent: TEvent;
    class function GetServer: ICrossHttpServer;
    class function GetIsRunning: Boolean; static;
    class procedure HandleRequest(const AConnection: ICrossHttpConnection;
      const ARequest: ICrossHttpRequest; const AResponse: ICrossHttpResponse);
  public
    class property Port:      Integer read FPort         write FPort;
    class property Host:      string  read FHost         write FHost;
    class property IsRunning: Boolean read GetIsRunning;
    // TLS configuration — must be set before the first Listen call.
    // CertFile and KeyFile must be PEM-format paths.
    class property EnableTLS: Boolean read FEnableTLS write FEnableTLS;
    class property CertFile:  string  read FCertFile  write FCertFile;
    class property KeyFile:   string  read FKeyFile   write FKeyFile;

    class procedure Listen; overload; override;
    class procedure Listen(APort: Integer; const AHost: string = DEFAULT_HOST;
      AOnListen: TProc = nil; AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure Listen(APort: Integer; AOnListen: TProc;
      AOnStop: TProc = nil); reintroduce; overload; static;
    // Convenience: enable TLS and listen in one call.
    class procedure ListenTLS(APort: Integer; const ACertFile, AKeyFile: string;
      const AHost: string = DEFAULT_HOST;
      AOnListen: TProc = nil; AOnStop: TProc = nil); static;
    class procedure StopListen; override;

    class destructor UnInitialize;
  end;

  TCrossDispatcher = class
  public
    procedure DoRequest(const Sender: TObject;
      const AConnection: ICrossHttpConnection;
      const ARequest:    ICrossHttpRequest;
      const AResponse:   ICrossHttpResponse;
      var   AHandled:    Boolean);
  end;

  // Top-level alias — mirrors the TPoseidonIndyDirect naming convention.
  TPoseidonCrossSocket = TPoseidonProviderCrossSocket;

implementation

uses
  System.Classes,
  Poseidon.WebAdapters.CrossSocket,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Pool,
  Poseidon.Pool.CrossSocket,
  Poseidon.Core,
  Poseidon.Exception,
  Poseidon.Problem;

{ TCrossDispatcher }

procedure TCrossDispatcher.DoRequest(const Sender: TObject;
  const AConnection: ICrossHttpConnection;
  const ARequest:    ICrossHttpRequest;
  const AResponse:   ICrossHttpResponse;
  var   AHandled:    Boolean);
begin
  // Run directly on the IOCP/epoll event thread — benchmarks show TTask.Run adds
  // ~28% overhead at c=100 with sub-ms handlers. For handlers with blocking I/O,
  // callers should use a dedicated thread pool in their own callback.
  AHandled := True;
  TInterlocked.Increment(TPoseidonProviderCrossSocket.FInFlightCount);
  TPoseidonProviderCrossSocket.HandleRequest(AConnection, ARequest, AResponse);
end;

{ TPoseidonProviderCrossSocket }

class function TPoseidonProviderCrossSocket.GetIsRunning: Boolean;
begin
  Result := FRunning <> 0;  // aligned 32-bit read is atomic on x86/x64
end;

class function TPoseidonProviderCrossSocket.GetServer: ICrossHttpServer;
var
  LSsl: ICrossSslSocket;
begin
  if FServer = nil then
  begin
    FServer := TCrossHttpServer.Create(0, FEnableTLS);
    if FEnableTLS and (FCertFile <> '') and Supports(FServer, ICrossSslSocket, LSsl) then
    begin
      LSsl.SetCertificateFile(FCertFile);
      LSsl.SetPrivateKeyFile(FKeyFile);
    end;
  end;
  Result := FServer;
end;

class function TPoseidonProviderCrossSocket.GetOrCreateEvent: TEvent;
begin
  if FShutdownEvent = nil then
    FShutdownEvent := TEvent.Create;
  Result := FShutdownEvent;
end;

class procedure TPoseidonProviderCrossSocket.HandleRequest(
  const AConnection: ICrossHttpConnection;
  const ARequest:    ICrossHttpRequest;
  const AResponse:   ICrossHttpResponse);
var
  LWebReq: TCrossWebRequest;
  LWebRes: TCrossWebResponse;
  LReq:    TPoseidonRequest;
  LRes:    TPoseidonResponse;
begin
  // Both pools eliminate heap alloc on the hot path:
  //   TCrossContextPool  → reuses TCrossWebRequest/Response adapter objects
  //   TPoseidonRequestPool → reuses TPoseidonRequest/Response wrapper objects
  TCrossContextPool.Acquire(AConnection, ARequest, AResponse, LWebReq, LWebRes);
  TPoseidonRequestPool.Acquire(LWebReq, LWebRes, LReq, LRes);
  try
    try
      TPoseidonCore.Routes.Execute(LReq, LRes);
    except
      on E: EPoseidonException do
      begin
        var LProblem := TProblemDetail.FromException(E, ARequest.Path);
        var LJson    := LProblem.ToJSON;
        try
          LRes.Status(E.Status);
          LWebRes.ContentType := 'application/problem+json';
          LWebRes.Content     := LJson.ToString;
        finally
          LJson.Free;
        end;
      end;
      on E: Exception do
      begin
        LWebRes.StatusCode  := 500;
        LWebRes.ContentType := 'application/problem+json';
        LWebRes.Content     :=
          '{"type":"about:blank","title":"Internal Server Error",' +
          '"status":500,"detail":"' + E.Message + '"}';
      end;
    end;
    LWebRes.CommitResponse;
  finally
    TPoseidonRequestPool.Release(LReq, LRes);
    TCrossContextPool.Release(LWebReq, LWebRes);
    TInterlocked.Decrement(FInFlightCount);
  end;
end;

class procedure TPoseidonProviderCrossSocket.Listen;
var
  LServer: ICrossHttpServer;
begin
  if FRunning <> 0 then
    raise Exception.Create('TPoseidonProviderCrossSocket: already listening — call StopListen first');

  if FPort <= 0 then FPort := DEFAULT_PORT;
  if FHost.IsEmpty then FHost := DEFAULT_HOST;

  LServer := GetServer;

  FreeAndNil(FDispatcher);
  FDispatcher       := TCrossDispatcher.Create;
  LServer.OnRequest := FDispatcher.DoRequest;

  LServer.StartLoop;

  // Set FRunning before the async Listen so the console wait-loop is entered.
  // If Listen fails, the callback rolls FRunning back and signals the event.
  TInterlocked.Exchange(FRunning, 1);

  LServer.Listen(FHost, FPort,
    procedure(const AListen: ICrossListen; const ASuccess: Boolean)
    begin
      if ASuccess then
        DoOnListen
      else
      begin
        TInterlocked.Exchange(FRunning, 0);
        if FShutdownEvent <> nil then
          FShutdownEvent.SetEvent;
      end;
    end);

  if IsConsole then
    while FRunning <> 0 do  // aligned 32-bit read is atomic on x86/x64
      GetOrCreateEvent.WaitFor(100);
end;

class procedure TPoseidonProviderCrossSocket.Listen(APort: Integer;
  const AHost: string; AOnListen, AOnStop: TProc);
begin
  FPort        := APort;
  FHost        := AHost;
  OnListen     := AOnListen;
  OnStopListen := AOnStop;
  Listen;
end;

class procedure TPoseidonProviderCrossSocket.Listen(APort: Integer;
  AOnListen, AOnStop: TProc);
begin
  Listen(APort, DEFAULT_HOST, AOnListen, AOnStop);
end;

class procedure TPoseidonProviderCrossSocket.ListenTLS(APort: Integer;
  const ACertFile, AKeyFile: string; const AHost: string;
  AOnListen, AOnStop: TProc);
begin
  FEnableTLS := True;
  FCertFile  := ACertFile;
  FKeyFile   := AKeyFile;
  Listen(APort, AHost, AOnListen, AOnStop);
end;

class procedure TPoseidonProviderCrossSocket.StopListen;
const
  DRAIN_TIMEOUT_MS = 30000;
  POLL_INTERVAL_MS = 50;
var
  LElapsed: Integer;
begin
  if FServer = nil then
    raise Exception.Create('TPoseidonProviderCrossSocket is not listening');

  TInterlocked.Exchange(FRunning, 0);

  // Stop accepting new connections
  FServer.CloseAllListens;

  // Drain in-flight requests (up to 30 s)
  LElapsed := 0;
  while (TInterlocked.Read(FInFlightCount) > 0) and (LElapsed < DRAIN_TIMEOUT_MS) do
  begin
    Sleep(POLL_INTERVAL_MS);
    Inc(LElapsed, POLL_INTERVAL_MS);
  end;

  FServer.StopLoop;
  DoOnStopListen;

  if FShutdownEvent <> nil then
    FShutdownEvent.SetEvent;
end;

class destructor TPoseidonProviderCrossSocket.UnInitialize;
begin
  if FServer <> nil then
  begin
    FServer.OnRequest := nil;
    FServer.StopLoop;
    FServer := nil;  // release interface reference (frees the object)
  end;
  FreeAndNil(FDispatcher);
  FreeAndNil(FShutdownEvent);
end;

initialization
  TPoseidonProviderCrossSocket.FPort      := 0;
  TPoseidonProviderCrossSocket.FHost      := '';
  TPoseidonProviderCrossSocket.FEnableTLS := False;
  TPoseidonProviderCrossSocket.FCertFile  := '';
  TPoseidonProviderCrossSocket.FKeyFile   := '';

end.
