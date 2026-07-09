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

  // Per-connection fragmentation state (RFC 6455 §5.4).
  // Held in FFragStates keyed by the connection pointer so TNativeConn does
  // not need new fields. Cleared on close or protocol error.
  TWSFragState = record
    Active: Boolean;         // A data message is being assembled
    Opcode: Byte;            // Initial opcode (0x1 text or 0x2 binary)
    Compressed: Boolean;     // RSV1 was set on the first fragment
    Buffer: TBytes;          // Concatenated (still-compressed if Compressed=True)
  end;

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
    FFragStates: TDictionary<Pointer, TWSFragState>;
    FFragLock: TCriticalSection;
    function GetFragState(AConn: Pointer): TWSFragState;
    procedure SetFragState(AConn: Pointer; const AState: TWSFragState);
    procedure ClearFragState(AConn: Pointer);
    procedure FailProtocol(AConn: Pointer; ACloseCode: Word);
  public
    constructor Create(ASend: TWSTransportSend; AClose: TWSTransportClose;
      ARecv: TWSTransportRecv; ABuildResponse: TWSBuildResponse);
    destructor Destroy; override;

    procedure RegisterHandler(const APath: string; AHandler: TWSMessageCallback);
    procedure UpgradeToWS(AConn: Pointer; const AReq: TPoseidonNativeRequest);
    function DispatchFrames(AConn: Pointer): Boolean;
    // Drop per-connection fragmentation state on socket teardown.
    procedure DropConnection(AConn: Pointer);

    property MaxWSFrameSize: Int64 read FMaxWSFrameSize write FMaxWSFrameSize;
    property OnLog: TOnPoseidonLog read FOnLog write FOnLog;
  end;

implementation

const
  CDefaultMaxWSFrameSize = 16 * 1024 * 1024;  // 16 MB
  // RFC 6455 close codes used by the dispatcher
  CCloseNormal        = 1000;
  CCloseProtocolError = 1002;
  CCloseInvalidData   = 1007;  // e.g. text frame with malformed UTF-8
  CCloseMessageTooBig = 1009;
  // RFC 6455 §5.5 — control frames MUST have payload <= 125 bytes and FIN=1
  CMaxControlPayload  = 125;
  // RFC 6455 §4.1/§4.4 — only version 13 is defined; mismatch → 426 Upgrade
  // Required with a Sec-WebSocket-Version header advertising the supported
  // version.
  CWSVersion          = '13';

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
  FFragStates := TDictionary<Pointer, TWSFragState>.Create;
  FFragLock := TCriticalSection.Create;
end;

destructor TWebSocketManager.Destroy;
begin
  FreeAndNil(FFragStates);
  FreeAndNil(FFragLock);
  FreeAndNil(FWSHandlers);
  FreeAndNil(FWSLock);
  inherited Destroy;
end;

function TWebSocketManager.GetFragState(AConn: Pointer): TWSFragState;
begin
  FFragLock.Enter;
  try
    if not FFragStates.TryGetValue(AConn, Result) then
    begin
      Result.Active := False;
      Result.Opcode := 0;
      Result.Compressed := False;
      SetLength(Result.Buffer, 0);
    end;
  finally
    FFragLock.Leave;
  end;
end;

procedure TWebSocketManager.SetFragState(AConn: Pointer;
  const AState: TWSFragState);
begin
  FFragLock.Enter;
  try
    FFragStates.AddOrSetValue(AConn, AState);
  finally
    FFragLock.Leave;
  end;
end;

procedure TWebSocketManager.ClearFragState(AConn: Pointer);
begin
  FFragLock.Enter;
  try
    FFragStates.Remove(AConn);
  finally
    FFragLock.Leave;
  end;
end;

procedure TWebSocketManager.DropConnection(AConn: Pointer);
begin
  ClearFragState(AConn);
end;

procedure TWebSocketManager.FailProtocol(AConn: Pointer; ACloseCode: Word);
var
  LOut: TBytes;
begin
  ClearFragState(AConn);
  LOut := TWebSocketUtils.CloseFrame(ACloseCode);
  FSend(AConn, LOut);
  FClose(AConn);
end;

// Strict UTF-8 validator (RFC 3629). Rejects overlong forms, surrogates
// (U+D800..U+DFFF) and code points above U+10FFFF. Used to enforce the
// RFC 6455 requirement that TEXT frames carry valid UTF-8 across the
// reassembled message. TEncoding.UTF8.GetString silently replaces bad
// bytes, so we cannot rely on it for compliance.
function IsValidUTF8(const AData: TBytes): Boolean;
var
  LI: Integer;
  LN: Integer;
  LB: Byte;
  LNeeded: Integer;
  LCodePoint: Cardinal;
  LMin: Cardinal;
begin
  LI := 0;
  LN := Length(AData);
  while LI < LN do
  begin
    LB := AData[LI];
    if LB < $80 then
    begin
      Inc(LI);
      Continue;
    end;
    if (LB and $E0) = $C0 then
    begin
      LNeeded := 1;
      LCodePoint := LB and $1F;
      LMin := $80;
    end
    else if (LB and $F0) = $E0 then
    begin
      LNeeded := 2;
      LCodePoint := LB and $0F;
      LMin := $800;
    end
    else if (LB and $F8) = $F0 then
    begin
      LNeeded := 3;
      LCodePoint := LB and $07;
      LMin := $10000;
    end
    else
      Exit(False);
    if LI + LNeeded >= LN then
      Exit(False);
    Inc(LI);
    while LNeeded > 0 do
    begin
      LB := AData[LI];
      if (LB and $C0) <> $80 then
        Exit(False);
      LCodePoint := (LCodePoint shl 6) or (LB and $3F);
      Inc(LI);
      Dec(LNeeded);
    end;
    if LCodePoint < LMin then
      Exit(False);
    if (LCodePoint >= $D800) and (LCodePoint <= $DFFF) then
      Exit(False);
    if LCodePoint > $10FFFF then
      Exit(False);
  end;
  Result := True;
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
  LVersion: string;
  LResp: TBytes;
  I: Integer;
  LDeflate: Boolean;
begin
  LConn := TNativeConn(AConn);
  LKey := '';
  LVersion := '';
  LDeflate := False;
  for I := 0 to High(AReq.Headers) do
  begin
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Key') then
      LKey := AReq.Headers[I].Value;
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Version') then
      LVersion := Trim(AReq.Headers[I].Value);
    if SameText(AReq.Headers[I].Key, 'Sec-WebSocket-Extensions') and
       (Pos('permessage-deflate', LowerCase(AReq.Headers[I].Value)) > 0) then
      LDeflate := True;
  end;
  // RFC 6455 §4.4 — if Sec-WebSocket-Version is missing or not 13, respond
  // 426 Upgrade Required and advertise the supported version. Do NOT open
  // the WebSocket session.
  if LVersion <> CWSVersion then
  begin
    LResp := FBuildResponse(426, 'text/plain',
      TEncoding.ASCII.GetBytes('Unsupported Sec-WebSocket-Version'), False,
      [TPair<string,string>.Create('Sec-WebSocket-Version', CWSVersion)]);
    FSend(AConn, LResp);
    Exit;
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
  // Defensive — the connection pointer may have been reused after a prior
  // socket close. Drop any lingering fragmentation state before we start
  // reading frames on this session.
  ClearFragState(AConn);

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
  LState: TWSFragState;
  LDelivered: TWebSocketFrame;
  LOldLen: Integer;
  LInflated: TBytes;
  LIsControl: Boolean;
  LIsDataOpcode: Boolean;
  LIsReserved: Boolean;
begin
  Result := True;
  LConn := TNativeConn(AConn);
  LTotal := 0;
  while TWebSocketUtils.ParseFrame(@LConn.AccumBuf[LTotal],
                                    LConn.AccumLen - LTotal,
                                    LFrame, LConsumed) do
  begin
    Inc(LTotal, LConsumed);

    // RFC 6455 §5.3 — every frame sent from client to server MUST be masked.
    // An unmasked frame is a protocol error; server MUST close with 1002.
    if not LFrame.Masked then
    begin
      FailProtocol(AConn, CCloseProtocolError);
      Result := False;
      Exit;
    end;

    LIsControl    := LFrame.Opcode >= $8;
    LIsDataOpcode := (LFrame.Opcode = OPCODE_TEXT)
                  or (LFrame.Opcode = OPCODE_BINARY);
    LIsReserved   := ((LFrame.Opcode >= $3) and (LFrame.Opcode <= $7))
                  or ((LFrame.Opcode >= $B) and (LFrame.Opcode <= $F));

    // RFC 6455 §5.2 — reserved opcodes MUST cause a fail.
    if LIsReserved then
    begin
      FailProtocol(AConn, CCloseProtocolError);
      Result := False;
      Exit;
    end;

    // RFC 6455 §5.5 — control frames MUST be FIN=1 with payload <= 125.
    if LIsControl then
    begin
      if (not LFrame.FinFlag)
         or (Length(LFrame.Payload) > CMaxControlPayload) then
      begin
        FailProtocol(AConn, CCloseProtocolError);
        Result := False;
        Exit;
      end;
    end;

    // Per-frame size guard (uncompressed frame payload). Message assembly
    // is bounded again after inflate below.
    if (FMaxWSFrameSize > 0)
       and (Int64(Length(LFrame.Payload)) > FMaxWSFrameSize) then
    begin
      FailProtocol(AConn, CCloseMessageTooBig);
      Result := False;
      Exit;
    end;

    // ------------------------------------------------------------------
    // Control frames — processed INLINE, must NOT touch fragmentation state.
    // ------------------------------------------------------------------
    if LIsControl then
    begin
      case LFrame.Opcode of
        OPCODE_PING:
        begin
          LOut := TWebSocketUtils.PongFrame(LFrame.Payload);
          FSend(AConn, LOut);
        end;
        OPCODE_PONG:
          ; // Unsolicited pong — allowed; ignore.
        OPCODE_CLOSE:
        begin
          LOut := TWebSocketUtils.CloseFrame(CCloseNormal);
          FSend(AConn, LOut);
          if LTotal < LConn.AccumLen then
            Move(LConn.AccumBuf[LTotal], LConn.AccumBuf[0],
                 LConn.AccumLen - LTotal);
          Dec(LConn.AccumLen, LTotal);
          ClearFragState(AConn);
          FClose(AConn);
          Result := False;
          Exit;
        end;
      else
        // Unknown control opcode covered by reserved check above; defensive.
        FailProtocol(AConn, CCloseProtocolError);
        Result := False;
        Exit;
      end;
      // Control frame handled — pick up the next frame without touching
      // the data-message buffer.
      Continue;
    end;

    // ------------------------------------------------------------------
    // Data frames — TEXT / BINARY / CONTINUATION (with fragmentation).
    // ------------------------------------------------------------------
    LState := GetFragState(AConn);

    if LIsDataOpcode then
    begin
      // Starting a new data message. A previous message MUST NOT be in
      // progress (RFC 6455 §5.4 — nested text/binary is a protocol error).
      if LState.Active then
      begin
        FailProtocol(AConn, CCloseProtocolError);
        Result := False;
        Exit;
      end;
      // RFC 6455 §5.2 — a peer MUST NOT set RSV1 unless an extension has
      // negotiated its meaning. If deflate was not negotiated on this
      // session, RSV1 is a protocol error.
      if LFrame.RSV1 and (not LConn.WSDeflate) then
      begin
        FailProtocol(AConn, CCloseProtocolError);
        Result := False;
        Exit;
      end;
      if LFrame.FinFlag then
      begin
        // Single-frame message — bounded inflate + optional UTF-8 check.
        if LConn.WSDeflate and LFrame.RSV1 then
        begin
          if not TWebSocketUtils.TryApplyRXDeflate(LFrame) then
          begin
            FailProtocol(AConn, CCloseMessageTooBig);
            Result := False;
            Exit;
          end;
        end;
        if (LFrame.Opcode = OPCODE_TEXT)
           and (not IsValidUTF8(LFrame.Payload)) then
        begin
          FailProtocol(AConn, CCloseInvalidData);
          Result := False;
          Exit;
        end;
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
      end
      else
      begin
        // Open a fragmented message. Keep the payload STILL COMPRESSED
        // if RSV1 was set — RFC 7692 says the compression frame applies
        // to the assembled message, so we inflate only once on the final
        // fragment.
        LState.Active := True;
        LState.Opcode := LFrame.Opcode;
        LState.Compressed := LFrame.RSV1;
        LState.Buffer := Copy(LFrame.Payload, 0, Length(LFrame.Payload));
        SetFragState(AConn, LState);
      end;
    end
    else if LFrame.Opcode = OPCODE_CONTINUATION then
    begin
      // A continuation frame requires an open message.
      if not LState.Active then
      begin
        FailProtocol(AConn, CCloseProtocolError);
        Result := False;
        Exit;
      end;
      // RFC 7692 §7.2.3.1 — RSV1 is only valid on the first frame of a
      // permessage-deflate message; setting it on a continuation is a
      // protocol violation.
      if LFrame.RSV1 then
      begin
        FailProtocol(AConn, CCloseProtocolError);
        Result := False;
        Exit;
      end;
      LOldLen := Length(LState.Buffer);
      if Length(LFrame.Payload) > 0 then
      begin
        SetLength(LState.Buffer, LOldLen + Length(LFrame.Payload));
        Move(LFrame.Payload[0], LState.Buffer[LOldLen], Length(LFrame.Payload));
      end;
      // Bound the assembled message just like a single frame.
      if (FMaxWSFrameSize > 0)
         and (Int64(Length(LState.Buffer)) > FMaxWSFrameSize) then
      begin
        FailProtocol(AConn, CCloseMessageTooBig);
        Result := False;
        Exit;
      end;
      if LFrame.FinFlag then
      begin
        // Finalize: inflate (once, bounded), UTF-8 validate if text,
        // deliver, clear state.
        if LState.Compressed and LConn.WSDeflate then
        begin
          if not TWSDeflateUtils.TryDecompress(LState.Buffer, LInflated) then
          begin
            FailProtocol(AConn, CCloseMessageTooBig);
            Result := False;
            Exit;
          end;
          LState.Buffer := LInflated;
        end;
        if (LState.Opcode = OPCODE_TEXT)
           and (not IsValidUTF8(LState.Buffer)) then
        begin
          FailProtocol(AConn, CCloseInvalidData);
          Result := False;
          Exit;
        end;
        LDelivered.FinFlag := True;
        LDelivered.RSV1 := False;
        LDelivered.Masked := False;
        LDelivered.Opcode := LState.Opcode;
        LDelivered.Payload := LState.Buffer;
        ClearFragState(AConn);
        FWSLock.Enter;
        LHasHandler := FWSHandlers.TryGetValue(LConn.WSPath, LHandler);
        FWSLock.Leave;
        if LHasHandler then
        try
          LHandler(LConn.WSConn, LDelivered);
        except
          on E: Exception do
            if Assigned(FOnLog) then
              FOnLog(llError, '[ws] ' + LConn.RemoteAddr + ' EX: ' + E.Message);
        end;
      end
      else
      begin
        // Still assembling — persist the growing buffer.
        SetFragState(AConn, LState);
      end;
    end
    else
    begin
      // Non-control, non-continuation, non-text/binary — unreachable given
      // the reserved-opcode check above. Guard anyway.
      FailProtocol(AConn, CCloseProtocolError);
      Result := False;
      Exit;
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
