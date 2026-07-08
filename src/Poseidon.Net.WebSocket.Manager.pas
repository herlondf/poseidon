unit Poseidon.Net.WebSocket.Manager;

// TWebSocketManager — handler registration, upgrade handshake, frame dispatch.
//
// Extracted from TPoseidonNativeServer. Owns FWSHandlers + FWSLock.
// Transport operations are provided via constructor-injected callbacks.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.WebSocket;

type
  // Transport callbacks — injected by the server
  TWSTransportSend  = reference to procedure(AConn: Pointer; const AData: TBytes);
  TWSTransportClose = reference to procedure(AConn: Pointer);
  TWSTransportRecv  = reference to procedure(AConn: Pointer);
  TWSBuildResponse  = reference to function(AStatus: Integer;
    const AContentType: string; const ABody: TBytes; AKeepAlive: Boolean;
    const AExtra: TArray<TPair<string,string>>): TBytes;

  TWebSocketManager = class
  private
    FWSHandlers: TDictionary<string, TWSMessageCallback>;
    FWSLock: TCriticalSection;
    FMaxWSFrameSize: Int64;
    FSend: TWSTransportSend;
    FClose: TWSTransportClose;
    FRecv: TWSTransportRecv;
    FBuildResponse: TWSBuildResponse;
    FOnLog: TOnPoseidonLog;
  public
    constructor Create(ASend: TWSTransportSend; AClose: TWSTransportClose;
      ARecv: TWSTransportRecv; ABuildResponse: TWSBuildResponse);
    destructor Destroy; override;

    procedure RegisterHandler(const APath: string; AHandler: TWSMessageCallback);
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function DispatchFrames(AConn: Pointer): Boolean;

    property MaxWSFrameSize: Int64 read FMaxWSFrameSize write FMaxWSFrameSize;
    property OnLog: TOnPoseidonLog read FOnLog write FOnLog;
  end;

implementation

const
  CDefaultMaxWSFrameSize = 16 * 1024 * 1024;  // 16 MB

constructor TWebSocketManager.Create(ASend: TWSTransportSend;
  AClose: TWSTransportClose; ARecv: TWSTransportRecv;
  ABuildResponse: TWSBuildResponse);
begin
  inherited Create;
  FWSHandlers := TDictionary<string, TWSMessageCallback>.Create;
  FWSLock := TCriticalSection.Create;
  FMaxWSFrameSize := CDefaultMaxWSFrameSize;
  FSend := ASend;
  FClose := AClose;
  FRecv := ARecv;
  FBuildResponse := ABuildResponse;
end;

destructor TWebSocketManager.Destroy;
begin
  FreeAndNil(FWSHandlers);
  FreeAndNil(FWSLock);
  inherited Destroy;
end;

procedure TWebSocketManager.RegisterHandler(const APath: string;
  AHandler: TWSMessageCallback);
begin
  FWSLock.Enter;
  try
    FWSHandlers.AddOrSetValue(APath, AHandler);
  finally
    FWSLock.Leave;
  end;
end;

procedure TWebSocketManager.UpgradeToWS(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
var
  LConn: TNativeConn;
  LKey: string;
  LResp: TBytes;
  I: Integer;
  LDeflate: Boolean;
begin
  LConn := TNativeConn(AConn);
  LKey := '';
  LDeflate := False;
  for I := 0 to High(AReq.Headers) do
  begin
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Key') then
      LKey := AReq.Headers[I].Value;
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Extensions') and
       (Pos('permessage-deflate', LowerCase(AReq.Headers[I].Value)) > 0) then
      LDeflate := True;
  end;
  if LKey = '' then
  begin
    LResp := FBuildResponse(400, 'text/plain',
      TEncoding.ASCII.GetBytes('Missing Sec-WebSocket-Key'), False, []);
    FSend(AConn, LResp);
    Exit;
  end;

  LResp := TWebSocketUtils.BuildHandshakeResponse(LKey, LDeflate);
  LConn.WSMode := CCMWebSocket;
  LConn.WSPath := AReq.Path;
  LConn.WSDeflate := LDeflate;
  LConn.KeepAlive := True;
  LConn.AccumLen := 0;

  LConn.WSConn := TPoseidonWSConn.Create(
    LConn.RemoteAddr,
    procedure(const AData: TBytes)
    begin
      FSend(AConn, AData);
    end,
    procedure
    begin
      FClose(AConn);
    end,
    LDeflate
  );

  FSend(AConn, LResp);
  FRecv(AConn);
end;

function TWebSocketManager.DispatchFrames(AConn: Pointer): Boolean;
var
  LConn: TNativeConn;
  LFrame: TWebSocketFrame;
  LConsumed: Integer;
  LTotal: Integer;
  LOut: TBytes;
  LHandler: TWSMessageCallback;
  LHasHandler: Boolean;
begin
  Result := True;
  LConn := TNativeConn(AConn);
  LTotal := 0;
  while TWebSocketUtils.ParseFrame(@LConn.AccumBuf[LTotal],
                                    LConn.AccumLen - LTotal,
                                    LFrame, LConsumed) do
  begin
    Inc(LTotal, LConsumed);
    if LConn.WSDeflate then
      TWebSocketUtils.ApplyRXDeflate(LFrame);
    if (FMaxWSFrameSize > 0) and (Int64(Length(LFrame.Payload)) > FMaxWSFrameSize) then
    begin
      LOut := TWebSocketUtils.CloseFrame(1009);
      FSend(AConn, LOut);
      FClose(AConn);
      Result := False;
      Exit;
    end;
    case LFrame.Opcode of
      OPCODE_PING:
      begin
        LOut := TWebSocketUtils.PongFrame(LFrame.Payload);
        FSend(AConn, LOut);
      end;
      OPCODE_CLOSE:
      begin
        LOut := TWebSocketUtils.CloseFrame(1000);
        FSend(AConn, LOut);
        if LTotal < LConn.AccumLen then
          Move(LConn.AccumBuf[LTotal], LConn.AccumBuf[0], LConn.AccumLen - LTotal);
        Dec(LConn.AccumLen, LTotal);
        FClose(AConn);
        Result := False;
        Exit;
      end;
      OPCODE_TEXT, OPCODE_BINARY:
      begin
        FWSLock.Enter;
        LHasHandler := FWSHandlers.TryGetValue(LConn.WSPath, LHandler);
        FWSLock.Leave;
        if LHasHandler then
        try
          LHandler(LConn.WSConn, LFrame);
        except
          on E: Exception do
            if Assigned(FOnLog) then
              FOnLog(llError, '[ws] ' + LConn.RemoteAddr + ' EX: ' + E.Message);
        end;
      end;
    end;
  end;
  if LTotal > 0 then
  begin
    if LTotal < LConn.AccumLen then
      Move(LConn.AccumBuf[LTotal], LConn.AccumBuf[0], LConn.AccumLen - LTotal);
    Dec(LConn.AccumLen, LTotal);
  end;
end;

end.
