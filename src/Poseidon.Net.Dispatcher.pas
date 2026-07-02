unit Poseidon.Net.Dispatcher;

// TProtocolDispatcher — R-5 Strategy pattern for HTTP/1.1 / WebSocket / HTTP/2.
//
// Encapsulates the routing logic extracted from TPoseidonNativeServer._DispatchAccumBuf:
//
//   Proxy Protocol header stripping
//   → HTTP/2 branch (TH2Conn.ProcessData)
//   → WebSocket branch (frame dispatch loop)
//   → HTTP/1.1 branch (parse → S-1/S-2 checks → rate limit → metrics
//                       → backpressure → handler → gzip → response)
//
// The server implements IDispatchCallbacks; the dispatcher calls back via the
// interface for transport operations and server-owned state.
// Pure config fields (no mutable server state) are bundled in TDispatchConfig
// and passed by value on each Dispatch call.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.SyncObjs,
  System.Math,
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.HTTP2,
  Poseidon.Net.ProxyProtocol,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.Interfaces;

type
  // --------------------------------------------------------------------------
  // Config snapshot — fields read on every request; copied from server fields.
  // --------------------------------------------------------------------------

  TDispatchConfig = record
    ProxyProtocol:        TProxyProtocolMode;
    MaxRequestSize:       Integer;
    MaxHeaderSize:        Integer;
    H2Enabled:            Boolean;
    SecureHeadersEnabled: Boolean;
    ServerBanner:         string;
    MaxQueueDepth:        Integer;
    InFlightCount:        PInt64;   // pointer to server's FInFlightCount (atomic)
  end;

  // --------------------------------------------------------------------------
  // Callback interface — implemented by TPoseidonNativeServer.
  // The dispatcher never calls server fields directly; only through here.
  // --------------------------------------------------------------------------

  IDispatchCallbacks = interface
    ['{D1E2F3A4-B5C6-7890-ABCD-EF1234567890}']
    // Transport
    procedure PostRecv(AConn: Pointer);
    procedure CloseConn(AConn: Pointer);
    procedure SendResponse(AConn: Pointer; const AData: TBytes; AActualLen: Integer);

    // Protocol upgrades
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    procedure UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);

    // WebSocket
    function DispatchWSFrames(AConn: Pointer): Boolean;

    // Application handler (includes exception handling and inflight tracking)
    procedure InvokeRequest(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtra: TArray<TPair<string,string>>);

    // Access log
    procedure LogRequest(const AEvent: TPoseidonRequestLogEvent);
  end;

  // --------------------------------------------------------------------------
  // Strategy dispatcher
  // --------------------------------------------------------------------------

  TProtocolDispatcher = class
  private
    FCallbacks: IDispatchCallbacks;
  public
    constructor Create(ACallbacks: IDispatchCallbacks);

    // Route accumulated bytes in AConn to the appropriate protocol handler.
    // Mirrors the former TPoseidonNativeServer._DispatchAccumBuf.
    procedure Dispatch(AConn: Pointer; const AConfig: TDispatchConfig); reintroduce;
  end;

implementation

uses
  Poseidon.Net.HTTP1.Parser;

constructor TProtocolDispatcher.Create(ACallbacks: IDispatchCallbacks);
begin
  inherited Create;
  FCallbacks := ACallbacks;
end;

procedure TProtocolDispatcher.Dispatch(AConn: Pointer; const AConfig: TDispatchConfig);
var
  LConn:          TNativeConn absolute AConn;
  LReq:           TPoseidonNativeRequest;
  LStatus:        Integer;
  LCT:            string;
  LBody:          TBytes;
  LExtra:         TArray<TPair<string,string>>;
  LResp:          TBytes;
  LRespActualLen: Integer;
  LUpgrade:       string;
  LWsKey:         string;
  I:              Integer;
  LStartTick:     Int64;
  LDurationMs:    Int64;
  LLogEvt:        TPoseidonRequestLogEvent;
  LPPAddr:        string;
  LPPPort:        Word;
  LPPConsumed:    Integer;
  LPPIncomplete:  Boolean;
  LPPInvalid:     Boolean;
  LPPNoSig:       Boolean;
  LConsumed:      Integer;
  LReqBad:        Boolean;
begin
  // --------------------------------------------------------------------------
  // Proxy Protocol — consume header once per new connection
  // --------------------------------------------------------------------------
  if (AConfig.ProxyProtocol <> ppDisabled) and not LConn.PPParsed then
  begin
    if LConn.AccumLen = 0 then
    begin
      FCallbacks.PostRecv(AConn);
      Exit;
    end;
    LPPAddr       := '';
    LPPPort       := 0;
    LPPConsumed   := 0;
    LPPIncomplete := False;
    LPPInvalid    := False;
    LPPNoSig      := False;
    if TryParseProxyProtocolAuto(AConfig.ProxyProtocol,
         @LConn.AccumBuf[0], LConn.AccumLen,
         LPPAddr, LPPPort, LPPConsumed,
         LPPIncomplete, LPPInvalid, LPPNoSig) then
    begin
      if LPPConsumed > 0 then
      begin
        Dec(LConn.AccumLen, LPPConsumed);
        if LConn.AccumLen > 0 then
          Move(LConn.AccumBuf[LPPConsumed], LConn.AccumBuf[0], LConn.AccumLen);
      end;
      if LPPAddr <> '' then
        LConn.RemoteAddr := LPPAddr + ':' + IntToStr(LPPPort);
      LConn.PPParsed := True;
    end
    else if LPPIncomplete then
    begin
      FCallbacks.PostRecv(AConn);
      Exit;
    end
    else if LPPInvalid then
    begin
      FCallbacks.CloseConn(AConn);
      Exit;
    end
    else
      LConn.PPParsed := True;  // ppAuto + no signature → treat as plain
  end;

  if LConn.AccumLen > AConfig.MaxRequestSize then
  begin
    LResp := BuildHTTPResponse(413, 'text/plain',
      TEncoding.ASCII.GetBytes('Payload Too Large'), False, [],
      AConfig.SecureHeadersEnabled, AConfig.ServerBanner);
    FCallbacks.SendResponse(AConn, LResp, 0);
    Exit;
  end;

  // --------------------------------------------------------------------------
  // HTTP/2 branch
  // --------------------------------------------------------------------------
  if LConn.H2Conn <> nil then
  begin
    if LConn.AccumLen > 0 then
    begin
      LConn.H2Conn.ProcessData(@LConn.AccumBuf[0], LConn.AccumLen);
      LConn.AccumLen := 0;
    end;
    if not LConn.H2Conn.GoAwaySent then
      FCallbacks.PostRecv(AConn);
    Exit;
  end;

  // --------------------------------------------------------------------------
  // WebSocket branch
  // --------------------------------------------------------------------------
  if LConn.WSMode = CM_WEBSOCKET then
  begin
    if FCallbacks.DispatchWSFrames(AConn) then
      FCallbacks.PostRecv(AConn);
    Exit;
  end;

  // --------------------------------------------------------------------------
  // HTTP/1.1 branch — parse request
  // --------------------------------------------------------------------------
  LReqBad := False;
  if not ParseHTTP1Request(
       LConn.AccumBuf, LConn.AccumLen,
       AConfig.MaxHeaderSize, AConfig.MaxRequestSize,
       LReq.Method, LReq.Path, LReq.QueryString,
       LReq.Headers, LReq.RawBody, LReq.KeepAlive,
       LConsumed, LReqBad) then
  begin
    if LReqBad then
    begin
      LResp := BuildHTTPResponse(400, 'text/plain',
        TEncoding.ASCII.GetBytes('Bad Request'), False, [],
        AConfig.SecureHeadersEnabled, AConfig.ServerBanner);
      FCallbacks.SendResponse(AConn, LResp, 0);
    end
    else
      FCallbacks.PostRecv(AConn);
    Exit;
  end;
  LReq.RemoteAddr := LConn.RemoteAddr;
  if LConn.AccumLen > LConsumed then
    Move(LConn.AccumBuf[LConsumed], LConn.AccumBuf[0], LConn.AccumLen - LConsumed);
  LConn.AccumLen := LConn.AccumLen - LConsumed;

  // Protocol upgrade checks
  LUpgrade := '';
  LWsKey   := '';
  for I := 0 to High(LReq.Headers) do
  begin
    if SameText(LReq.Headers[I].Key, 'Upgrade')           then LUpgrade := LReq.Headers[I].Value;
    if SameText(LReq.Headers[I].Key, 'Sec-WebSocket-Key') then LWsKey   := LReq.Headers[I].Value;
  end;
  if SameText(LUpgrade, 'websocket') and (LWsKey <> '') then
  begin
    FCallbacks.UpgradeToWS(AConn, LReq);
    Exit;
  end;
  if SameText(LUpgrade, 'h2c') and AConfig.H2Enabled and (LConn.SSLHandle = nil) then
  begin
    FCallbacks.UpgradeToH2C(AConn, LReq);
    Exit;
  end;

  LConn.KeepAlive := LReq.KeepAlive;

  // --------------------------------------------------------------------------
  // Invoke application handler
  // Security, rate limiting, compression and metrics are now opt-in
  // middlewares — registered via TPoseidon.Use().
  // --------------------------------------------------------------------------
  LStartTick := Int64(TThread.GetTickCount64);
  FCallbacks.InvokeRequest(LReq, LStatus, LCT, LBody, LExtra);

  // Build response
  LResp       := BuildHTTPResponsePooled(LStatus, LCT, LBody, LReq.KeepAlive,
    LExtra, AConfig.SecureHeadersEnabled, AConfig.ServerBanner, LRespActualLen);
  LDurationMs := Int64(TThread.GetTickCount64) - LStartTick;

  LLogEvt.Method     := LReq.Method;
  LLogEvt.Path       := LReq.Path;
  LLogEvt.Status     := LStatus;
  LLogEvt.DurationMs := LDurationMs;
  LLogEvt.RemoteAddr := LConn.RemoteAddr;
  LLogEvt.RxBytes    := Length(LReq.RawBody);
  LLogEvt.TxBytes    := LRespActualLen;
  FCallbacks.LogRequest(LLogEvt);

  FCallbacks.SendResponse(AConn, LResp, LRespActualLen);
end;

end.
