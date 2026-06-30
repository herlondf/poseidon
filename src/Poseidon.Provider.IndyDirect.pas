unit Poseidon.Provider.IndyDirect;

// HTTP provider that hooks TIdHTTPServer.OnCommandGet directly,
// bypassing TIdHTTPWebBrokerBridge and the WebBroker dispatch layer.
// Drop-in replacement for TPoseidonProviderIndy with lower per-request overhead.

interface

uses
  System.SysUtils,
  System.SyncObjs,
  IdHTTPServer,
  IdCustomHTTPServer,
  IdContext,
  Poseidon.Proc,
  Poseidon.Provider.Abstract;

type
  TPoseidonProviderIndyDirect = class(TPoseidonProviderAbstract)
  private const
    DEFAULT_HOST = '0.0.0.0';
    DEFAULT_PORT = 9000;
  private
    class var FPort:           Integer;
    class var FHost:           string;
    class var FRunning:        Boolean;
    class var FShutdownEvent:  TEvent;
    class var FMaxConnections: Integer;
    class var FServer:         TIdHTTPServer;
    class var FInFlightCount:  Int64;

    class function  GetServer: TIdHTTPServer;
    class function  GetOrCreateEvent: TEvent;
    class procedure HandleRequest(AContext: TIdContext;
      ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
  public
    class property Port:           Integer read FPort           write FPort;
    class property Host:           string  read FHost           write FHost;
    class property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    class property IsRunning:      Boolean read FRunning;

    class procedure Listen; overload; override;
    class procedure Listen(APort: Integer; const AHost: string = DEFAULT_HOST;
      AOnListen: TProc = nil; AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure Listen(APort: Integer; AOnListen: TProc;
      AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure StopListen; override;

    // HTTPS — requires OpenSSL DLLs (libssl / libcrypto) alongside the executable
    class procedure ListenSSL(APort: Integer; const ACertFile, AKeyFile: string;
      const AKeyPassword: string = ''; const AHost: string = DEFAULT_HOST;
      AOnListen: TProc = nil; AOnStop: TProc = nil); reintroduce; overload; static;

    class destructor UnInitialize;
  end;

  // Top-level alias — mirrors the TPoseidonCrossSocket naming convention.
  TPoseidonIndyDirect = TPoseidonProviderIndyDirect;

implementation

uses
  System.Threading,
  IdSSLOpenSSL,
  Poseidon.WebAdapters.Indy,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Pool,
  Poseidon.Core,
  Poseidon.Exception,
  Poseidon.Problem;

type
  TPoseidonSSLPasswordProvider = class
  private
    FPassword: string;
  public
    constructor Create(const APassword: string);
    procedure GetPassword(var APassword: string);
  end;

var
  GSSLPasswordProvider: TPoseidonSSLPasswordProvider;

constructor TPoseidonSSLPasswordProvider.Create(const APassword: string);
begin
  FPassword := APassword;
end;

procedure TPoseidonSSLPasswordProvider.GetPassword(var APassword: string);
begin
  APassword := FPassword;
end;

class function TPoseidonProviderIndyDirect.GetServer: TIdHTTPServer;
begin
  if FServer = nil then
  begin
    FServer := TIdHTTPServer.Create(nil);
    FServer.OnCommandGet   := HandleRequest;
    FServer.OnCommandOther := HandleRequest;
    FServer.AutoStartSession := False;
    FServer.KeepAlive := True;
  end;
  Result := FServer;
end;

class function TPoseidonProviderIndyDirect.GetOrCreateEvent: TEvent;
begin
  if FShutdownEvent = nil then
    FShutdownEvent := TEvent.Create;
  Result := FShutdownEvent;
end;

class procedure TPoseidonProviderIndyDirect.HandleRequest(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  LWebReq: TIndyWebRequest;
  LWebRes: TIndyWebResponse;
  LReq:    TPoseidonRequest;
  LRes:    TPoseidonResponse;
begin
  TInterlocked.Increment(FInFlightCount);
  LWebReq := TIndyWebRequest.Create(AContext, ARequestInfo);
  LWebRes := TIndyWebResponse.Create(LWebReq, AResponseInfo);
  TPoseidonRequestPool.Acquire(LWebReq, LWebRes, LReq, LRes);
  try
    try
      TPoseidonCore.Routes.Execute(LReq, LRes);
    except
      on E: EPoseidonException do
      begin
        var LProblem := TProblemDetail.FromException(E, ARequestInfo.Document);
        var LJson    := LProblem.ToJSON;
        try
          AResponseInfo.ResponseNo  := E.Status.ToInteger;
          AResponseInfo.ContentType := 'application/problem+json';
          AResponseInfo.ContentText := LJson.ToString;
        finally
          LJson.Free;
        end;
      end;
      on E: Exception do
      begin
        AResponseInfo.ResponseNo  := 500;
        AResponseInfo.ContentType := 'application/problem+json';
        AResponseInfo.ContentText :=
          '{"type":"about:blank","title":"Internal Server Error",' +
          '"status":500,"detail":"' + E.Message + '"}';
      end;
    end;
    LWebRes.CommitHeaders;
  finally
    TPoseidonRequestPool.Release(LReq, LRes);
    LWebRes.Free;
    LWebReq.Free;
    TInterlocked.Decrement(FInFlightCount);
  end;
end;

class procedure TPoseidonProviderIndyDirect.Listen;
var
  LServer: TIdHTTPServer;
begin
  if FPort <= 0 then FPort := DEFAULT_PORT;
  if FHost.IsEmpty then FHost := DEFAULT_HOST;

  LServer := GetServer;

  if FMaxConnections > 0 then
    LServer.MaxConnections := FMaxConnections;

  LServer.Bindings.Clear;
  with LServer.Bindings.Add do
  begin
    IP   := FHost;
    Port := FPort;
  end;

  LServer.Active := True;
  FRunning := True;
  DoOnListen;

  if IsConsole then
    while FRunning do
      GetOrCreateEvent.WaitFor;
end;

class procedure TPoseidonProviderIndyDirect.Listen(APort: Integer;
  const AHost: string; AOnListen, AOnStop: TProc);
begin
  FPort          := APort;
  FHost          := AHost;
  OnListen       := AOnListen;
  OnStopListen   := AOnStop;
  Listen;
end;

class procedure TPoseidonProviderIndyDirect.Listen(APort: Integer;
  AOnListen, AOnStop: TProc);
begin
  Listen(APort, DEFAULT_HOST, AOnListen, AOnStop);
end;

class procedure TPoseidonProviderIndyDirect.StopListen;
const
  DRAIN_TIMEOUT_MS = 30000;
  POLL_INTERVAL_MS = 50;
var
  LElapsed: Integer;
begin
  if FServer = nil then
    raise Exception.Create('PoseidonIndyDirect is not listening');
  FRunning := False;
  // Stop accepting new connections first
  FServer.Active := False;
  // Drain in-flight requests (up to 30 s)
  LElapsed := 0;
  while (TInterlocked.Read(FInFlightCount) > 0) and (LElapsed < DRAIN_TIMEOUT_MS) do
  begin
    Sleep(POLL_INTERVAL_MS);
    Inc(LElapsed, POLL_INTERVAL_MS);
  end;
  DoOnStopListen;
  if FShutdownEvent <> nil then
    FShutdownEvent.SetEvent;
end;

class procedure TPoseidonProviderIndyDirect.ListenSSL(APort: Integer;
  const ACertFile, AKeyFile, AKeyPassword, AHost: string;
  AOnListen, AOnStop: TProc);
var
  LServer: TIdHTTPServer;
  LSSL:    TIdServerIOHandlerSSLOpenSSL;
begin
  FPort        := APort;
  FHost        := AHost;
  OnListen     := AOnListen;
  OnStopListen := AOnStop;
  LServer      := GetServer;

  FreeAndNil(GSSLPasswordProvider);
  // Created with LServer as owner — freed automatically when FServer is freed
  LSSL := TIdServerIOHandlerSSLOpenSSL.Create(LServer);
  LSSL.SSLOptions.CertFile     := ACertFile;
  LSSL.SSLOptions.KeyFile      := AKeyFile;
  LSSL.SSLOptions.RootCertFile := ACertFile;
  LSSL.SSLOptions.Method       := sslvTLSv1_2;
  if AKeyPassword <> '' then
  begin
    GSSLPasswordProvider       := TPoseidonSSLPasswordProvider.Create(AKeyPassword);
    LSSL.OnGetPassword         := GSSLPasswordProvider.GetPassword;
  end;
  LServer.IOHandler := LSSL;

  Listen;
end;

class destructor TPoseidonProviderIndyDirect.UnInitialize;
begin
  FreeAndNil(FServer);
  FreeAndNil(FShutdownEvent);
end;

initialization
  TPoseidonProviderIndyDirect.FPort := 0;
  TPoseidonProviderIndyDirect.FHost := '';

finalization
  FreeAndNil(GSSLPasswordProvider);

end.
