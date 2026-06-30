unit Poseidon.Provider.Indy;

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  IdHTTPWebBrokerBridge,
  IdContext,
  Poseidon.Proc,
  Poseidon.Provider.Abstract;

type
  TPoseidonProviderIndy = class(TPoseidonProviderAbstract)
  private const
    DEFAULT_HOST = '0.0.0.0';
    DEFAULT_PORT = 9000;
  private
    class var FPort: Integer;
    class var FHost: string;
    class var FRunning: Boolean;
    class var FShutdownEvent: TEvent;
    class var FMaxConnections: Integer;
    class var FBridge: TIdHTTPWebBrokerBridge;

    class function GetBridge: TIdHTTPWebBrokerBridge;
    class function GetOrCreateEvent: TEvent;
    class procedure OnAuthentication(AContext: TIdContext; const AAuthType, AAuthData: string;
      var VUsername, VPassword: string; var VHandled: Boolean);
  public
    class property Port: Integer read FPort write FPort;
    class property Host: string read FHost write FHost;
    class property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    class property IsRunning: Boolean read FRunning;

    class procedure Listen; overload; override;
    class procedure Listen(APort: Integer; const AHost: string = '0.0.0.0';
      AOnListen: TProc = nil; AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure Listen(APort: Integer; AOnListen: TProc;
      AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure StopListen; override;

    class destructor UnInitialize;
  end;

  TPoseidonIndy = TPoseidonProviderIndy;

implementation

uses
  Web.WebReq,
  Poseidon.WebModule;

class function TPoseidonProviderIndy.GetBridge: TIdHTTPWebBrokerBridge;
begin
  if FBridge = nil then
  begin
    FBridge := TIdHTTPWebBrokerBridge.Create(nil);
    FBridge.OnParseAuthentication := OnAuthentication;
  end;
  Result := FBridge;
end;

class function TPoseidonProviderIndy.GetOrCreateEvent: TEvent;
begin
  if FShutdownEvent = nil then
    FShutdownEvent := TEvent.Create;
  Result := FShutdownEvent;
end;

class procedure TPoseidonProviderIndy.OnAuthentication(AContext: TIdContext; const AAuthType, AAuthData: string;
  var VUsername, VPassword: string; var VHandled: Boolean);
begin
  VHandled := True;
end;

class procedure TPoseidonProviderIndy.Listen;
var
  LBridge: TIdHTTPWebBrokerBridge;
begin
  if FPort <= 0 then FPort := DEFAULT_PORT;
  if FHost.IsEmpty then FHost := DEFAULT_HOST;

  LBridge := GetBridge;
  WebRequestHandler.WebModuleClass := WebModuleClass;

  if FMaxConnections > 0 then
  begin
    WebRequestHandler.MaxConnections := FMaxConnections;
    LBridge.MaxConnections := FMaxConnections;
  end;

  if FHost <> DEFAULT_HOST then
  begin
    LBridge.Bindings.Clear;
    LBridge.Bindings.Add;
    LBridge.Bindings.Items[0].IP := FHost;
    LBridge.Bindings.Items[0].Port := FPort;
  end;

  LBridge.DefaultPort := FPort;
  LBridge.KeepAlive := True;
  LBridge.Active := True;
  LBridge.StartListening;
  FRunning := True;
  DoOnListen;

  if IsConsole then
    while FRunning do
      GetOrCreateEvent.WaitFor;
end;

class procedure TPoseidonProviderIndy.Listen(APort: Integer; const AHost: string;
  AOnListen, AOnStop: TProc);
begin
  FPort := APort;
  FHost := AHost;
  OnListen := AOnListen;
  OnStopListen := AOnStop;
  Listen;
end;

class procedure TPoseidonProviderIndy.Listen(APort: Integer; AOnListen, AOnStop: TProc);
begin
  Listen(APort, DEFAULT_HOST, AOnListen, AOnStop);
end;

class procedure TPoseidonProviderIndy.StopListen;
const
  DRAIN_TIMEOUT_MS = 30000;
  POLL_INTERVAL_MS = 50;
var
  LElapsed: Integer;
  LContexts: TList;
begin
  if FBridge = nil then
    raise Exception.Create('Poseidon is not listening');
  FRunning := False;
  FBridge.StopListening;
  // Drain active connections (up to 30 s)
  LElapsed := 0;
  while LElapsed < DRAIN_TIMEOUT_MS do
  begin
    LContexts := FBridge.Contexts.LockList;
    try
      if LContexts.Count = 0 then
        Break;
    finally
      FBridge.Contexts.UnlockList;
    end;
    Sleep(POLL_INTERVAL_MS);
    Inc(LElapsed, POLL_INTERVAL_MS);
  end;
  FBridge.Active := False;
  DoOnStopListen;
  if FShutdownEvent <> nil then
    FShutdownEvent.SetEvent;
end;

class destructor TPoseidonProviderIndy.UnInitialize;
begin
  FreeAndNil(FBridge);
  FreeAndNil(FShutdownEvent);
end;

initialization
  TPoseidonProviderIndy.FPort := 0;
  TPoseidonProviderIndy.FHost := '';

end.
