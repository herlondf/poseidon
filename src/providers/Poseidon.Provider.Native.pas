unit Poseidon.Provider.Native;

// HTTP provider built on TPoseidonNativeServer (IOCP on Windows, epoll on Linux).
// Zero dependency on Delphi-Cross-Socket vendor library.
// Single WSASend per response eliminates the two-write Nagle stall.
//
// Usage:
//   TPoseidonNative.Get('/ping', procedure(Req, Res) begin Res.Send('pong'); end);
//   TPoseidonNative.Listen(9006);

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  Poseidon.Proc,
  Poseidon.Provider.Abstract,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer,
  Poseidon.Net.WebSocket;

type
  TPoseidonProviderNative = class(TPoseidonProviderAbstract)
  private const
    DEFAULT_HOST = '0.0.0.0';
    DEFAULT_PORT = 9000;
  private
    class var FPort:          Integer;
    class var FHost:          string;
    class var FRunning:       Boolean;
    class var FShutdownEvent: TEvent;
    class var FServer:        TPoseidonNativeServer;

    class procedure HandleRequest(
      const AReq:          TPoseidonNativeRequest;
      out   AStatus:       Integer;
      out   AContentType:  string;
      out   ABody:         TBytes;
      out   AExtraHeaders: TArray<TPair<string,string>>);
  public
    class property Port:      Integer read FPort      write FPort;
    class property Host:      string  read FHost      write FHost;
    class property IsRunning: Boolean read FRunning;

    class procedure Listen; overload; override;
    class procedure Listen(APort: Integer; const AHost: string = DEFAULT_HOST;
      AOnListen: TProc = nil; AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure Listen(APort: Integer; AOnListen: TProc;
      AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure StopListen; override;

    // Enable HTTPS — must be called before Listen().
    // Cert and key are PEM files. Requires OpenSSL libssl/libcrypto in PATH.
    class procedure ConfigureSSL(const ACertFile, AKeyFile: string); static;

    // Register an additional certificate for a specific hostname (SNI).
    // Client TLS handshake with matching SNI receives this cert; others receive
    // the default cert from ConfigureSSL. Must be called after ConfigureSSL,
    // before Listen.
    class procedure AddSSLCert(const AHostName, ACertFile, AKeyFile: string); static;

    // Register a WebSocket handler for a specific path.
    // AHandler is called for each incoming text or binary frame.
    class procedure WebSocket(const APath: string; AHandler: TWSMessageCallback); static;

    // Enable HTTP/2 (h2 via ALPN). Requires ConfigureSSL to be called first.
    class procedure EnableHTTP2(AEnabled: Boolean = True); static;

    class destructor UnInitialize;
  end;

  TPoseidonNative = TPoseidonProviderNative;

implementation

uses
  System.Classes,
  Poseidon.Net.WebAdapters.Native,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Pool,
  Poseidon.Net.Pool.Native,
  Poseidon.Core,
  Poseidon.Exception,
  Poseidon.Problem;

{ TPoseidonProviderNative }

class procedure TPoseidonProviderNative.HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
var
  LWebReq:      TNativeWebRequest;
  LWebRes:      TNativeWebResponse;
  LReq:         TPoseidonRequest;
  LRes:         TPoseidonResponse;
  LFlushed:     Boolean;
  LStatus:      Integer;
  LContentType: string;
  LBody:        TBytes;
  LExtraHdrs:   TArray<TPair<string,string>>;
begin
  // Default error response — overwritten by CommitResponse on success
  LStatus       := 500;
  LContentType  := 'application/problem+json';
  LBody         := TEncoding.UTF8.GetBytes(
    '{"type":"about:blank","title":"Internal Server Error","status":500}');
  SetLength(LExtraHdrs, 0);
  LFlushed := False;

  // Acquire adapter pair — pool reuse, zero heap alloc on hot path
  // Note: closures cannot capture `out` parameters directly in Delphi;
  //       local variables are used and then copied to out params at the end.
  TNativeContextPool.Acquire(
    AReq,
    procedure(S: Integer; const CT: string; const B: TBytes;
      const EH: TArray<TPair<string,string>>)
    begin
      LStatus      := S;
      LContentType := CT;
      LBody        := B;
      LExtraHdrs   := EH;
      LFlushed     := True;
    end,
    LWebReq, LWebRes);

  TPoseidonRequestPool.Acquire(LWebReq, LWebRes, LReq, LRes);
  try
    try
      TPoseidonCore.Routes.Execute(LReq, LRes);
    except
      on E: EPoseidonException do
      begin
        var LProblem := TProblemDetail.FromException(E, AReq.Path);
        var LJson    := LProblem.ToJSON;
        try
          LRes.Status(E.Status);
          LWebRes.StatusCode  := E.Status.ToInteger;
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
    if LRes.HasRawBody then
    begin
      // W4: raw-bytes fast path — body is already UTF-8 encoded. Skip the
      // CommitResponse path that would re-encode FWebResponse.Content from
      // UTF-16 to UTF-8.
      LStatus      := LWebRes.StatusCode;
      LContentType := LRes.RawContentType;
      LBody        := LRes.RawBody;
      SetLength(LExtraHdrs, LWebRes.CustomHeaders.Count);
      var LExtraCount := 0;
      for var I := 0 to LWebRes.CustomHeaders.Count - 1 do
      begin
        if SameText(LWebRes.CustomHeaders.Names[I], 'Content-Type') then Continue;
        LExtraHdrs[LExtraCount] := TPair<string,string>.Create(
          LWebRes.CustomHeaders.Names[I], LWebRes.CustomHeaders.ValueFromIndex[I]);
        Inc(LExtraCount);
      end;
      SetLength(LExtraHdrs, LExtraCount);
      LFlushed := True;
    end
    else if not LFlushed then
      LWebRes.CommitResponse;  // triggers the closure → fills LStatus/LContentType/LBody/LExtraHdrs
  finally
    TPoseidonRequestPool.Release(LReq, LRes);
    TNativeContextPool.Release(LWebReq, LWebRes);
  end;

  AStatus      := LStatus;
  AContentType := LContentType;
  ABody        := LBody;
  AExtraHeaders := LExtraHdrs;
end;

class procedure TPoseidonProviderNative.Listen;
var
  LServer: TPoseidonNativeServer;
begin
  if FPort <= 0 then FPort := DEFAULT_PORT;
  if FHost.IsEmpty then FHost := DEFAULT_HOST;

  if FServer = nil then
    FServer := TPoseidonNativeServer.Create;

  FRunning := True;

  LServer := FServer;
  LServer.Listen(FHost, FPort,
    procedure(const AReq:  TPoseidonNativeRequest;
              out   AStatus:       Integer;
              out   AContentType:  string;
              out   ABody:         TBytes;
              out   AExtraHeaders: TArray<TPair<string,string>>)
    begin
      HandleRequest(AReq, AStatus, AContentType, ABody, AExtraHeaders);
    end,
    procedure begin
      Writeln('Poseidon-Native on http://' + FHost + ':' + IntToStr(FPort));
      DoOnListen;
    end);

  if IsConsole then
    while FRunning do
    begin
      var LEvt := FShutdownEvent;
      if LEvt <> nil then LEvt.WaitFor
      else Sleep(500);
    end;
end;

class procedure TPoseidonProviderNative.Listen(APort: Integer;
  const AHost: string; AOnListen, AOnStop: TProc);
begin
  FPort        := APort;
  FHost        := AHost;
  OnListen     := AOnListen;
  OnStopListen := AOnStop;
  Listen;
end;

class procedure TPoseidonProviderNative.Listen(APort: Integer;
  AOnListen, AOnStop: TProc);
begin
  Listen(APort, DEFAULT_HOST, AOnListen, AOnStop);
end;

class procedure TPoseidonProviderNative.StopListen;
begin
  if FServer = nil then
    raise Exception.Create('TPoseidonProviderNative is not listening');

  FRunning := False;
  FServer.Stop;
  DoOnStopListen;

  if FShutdownEvent = nil then
    FShutdownEvent := TEvent.Create;
  FShutdownEvent.SetEvent;
end;

class procedure TPoseidonProviderNative.ConfigureSSL(const ACertFile,
  AKeyFile: string);
begin
  if FServer = nil then
    FServer := TPoseidonNativeServer.Create;
  FServer.ConfigureSSL(ACertFile, AKeyFile);
end;

class procedure TPoseidonProviderNative.AddSSLCert(const AHostName, ACertFile,
  AKeyFile: string);
begin
  if FServer = nil then
    raise Exception.Create('Call ConfigureSSL before AddSSLCert');
  FServer.AddSSLCert(AHostName, ACertFile, AKeyFile);
end;

class procedure TPoseidonProviderNative.WebSocket(const APath: string;
  AHandler: TWSMessageCallback);
begin
  if FServer = nil then
    FServer := TPoseidonNativeServer.Create;
  FServer.RegisterWSHandler(APath, AHandler);
end;

class procedure TPoseidonProviderNative.EnableHTTP2(AEnabled: Boolean);
begin
  if FServer = nil then
    FServer := TPoseidonNativeServer.Create;
  FServer.HTTP2Enabled := AEnabled;
end;

class destructor TPoseidonProviderNative.UnInitialize;
begin
  if FServer <> nil then
  begin
    try FServer.Stop; except end;
    FreeAndNil(FServer);
  end;
  FreeAndNil(FShutdownEvent);
end;

initialization
  TPoseidonProviderNative.FPort := 0;
  TPoseidonProviderNative.FHost := '';

end.
