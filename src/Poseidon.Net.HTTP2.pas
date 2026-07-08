unit Poseidon.Net.HTTP2;

// HTTP/2 (RFC 7540) + HPACK (RFC 7541) implementation for the Poseidon framework.
// One TH2Conn instance per connection, driven by TPoseidonNativeServer._ProcessRecv.
//
// Design decisions:
//   - Server push (RFC 7540 §8.2): ENABLE_PUSH=1; push resources returned by FOnRequest
//   - HPACK encode: literal without indexing (simple, correct)
//   - HPACK decode: full RFC 7541 (indexed, incremental-index, no-index, never-index, table-update)
//   - Huffman decode: tree built once at unit initialization
//   - Huffman encode: NOT used (literals sent as plain, flag = 0)
//   - Flow control: accepted/ignored (initial window 65535 is enough for most responses)
//   - Thread safety: caller (IOCP worker) is single-threaded per connection

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Poseidon.Net.HTTP2.HPACK,
  Poseidon.Net.Types;

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

type
  TH2RequestData = record
    Method, Path, Host, QueryString, RemoteAddr, ContentType, Protocol: string;
    Headers: TArray<TPair<string, string>>;
    Body: TBytes;
    StreamID: Cardinal;
  end;

  TH2RequestCallback = procedure(const AReq: TH2RequestData;
    var AStatus: Integer; var AContentType: string; var ABody: TBytes;
    var AExtra: TArray<TPair<string, string>>;
    var APushResources: TArray<TPoseidonPushResource>) of object;

  TH2SendProc  = procedure(AConn: Pointer; const AData: TBytes) of object;
  TH2CloseProc = procedure(AConn: Pointer) of object;

  TH2StreamState = (hssIdle, hssOpen, hssHalfClosedRemote, hssClosed);

  TH2Stream = class
  public
    StreamID:        Cardinal;
    State:           TH2StreamState;
    Method:          string;
    Path:            string;
    Scheme:          string;
    Authority:       string;
    RequestHeaders:  TArray<TPair<string, string>>;
    Body:            TBytes;
    BodyLen:         Integer;
    EndStream:       Boolean;
    HeadersComplete: Boolean;
    // Per-stream flow control
    SendWindow:      Integer;   // peer's stream-level send window (how much we can send)
    RecvWindow:      Integer;   // server's stream-level receive window (how much we accept)
    PendingBody:     TBytes;    // response DATA buffered when send window was exhausted
    PendingBodyOfs:  Integer;   // bytes of PendingBody already sent
    destructor Destroy; override;
  end;

  TH2Conn = class
  private
    FConn:       Pointer;
    FSendProc:   TH2SendProc;
    FCloseProc:  TH2CloseProc;
    FOnRequest:  TH2RequestCallback;

    // HPACK codec (owns dynamic table, static table ref, Huffman tree ref)
    FHpack: TH2HpackCodec;

    // Connection state
    FPrefaceReceived: Boolean;
    FSettingsSent:    Boolean;
    FGoAwaySent:      Boolean;

    // Frame reassembly accumulator
    FFrameBuf: TBytes;
    FFrameLen: Integer;

    // CONTINUATION state (RFC 7540 §6.10)
    FContinStreamID:   Cardinal;
    FContinHeaders:    TBytes;
    FContinHeadersLen: Integer;

    // Streams
    FStreams:      TDictionary<Cardinal, TH2Stream>;
    FLastStreamID: Cardinal;

    // Peer settings
    FPeerMaxFrameSize: Integer;
    FPeerInitWinSize: Integer;

    // Active stream tracking for graceful GOAWAY drain
    FActiveStreams: Integer;
    FPadStreams: array[0..14] of Integer; // cache-line padding
    FDeferClose: Boolean;

    // Server push (RFC 7540 §8.2)
    FNextPushStreamID: Cardinal;  // server-initiated streams are even (2, 4, 6, …)
    FClientEnablePush: Boolean;   // True until client sends ENABLE_PUSH=0

    // Server-side SETTINGS values (sent to client)
    FMaxConcurrentStreams: Cardinal;
    FInitialWindowSize:    Cardinal;

    // Connection-level flow control windows
    FConnSendWindow: Integer;  // peer's connection-level window (we decrement when sending)
    FConnRecvWindow: Integer;  // our connection-level receive window (peer's view)

    // -----------------------------------------------------------------------
    // Frame processing
    // -----------------------------------------------------------------------
    procedure _ProcessFrame(AType, AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);
    procedure _HandleSettings(AFlags: Byte; APayload: PByte; APayLen: Integer);
    procedure _HandleHeaders(AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer; AContinuation: Boolean = False);
    procedure _HandleData(AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);
    procedure _HandleWindowUpdate(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
    procedure _HandlePing(AFlags: Byte; APayload: PByte; APayLen: Integer);
    procedure _HandleGoAway(APayload: PByte; APayLen: Integer);
    procedure _HandleRstStream(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
    procedure _HandleContinuation(AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);
    procedure _DispatchStream(AStream: TH2Stream);
    procedure _DecodeRequestHeaders(AStream: TH2Stream;
      APayload: PByte; APayLen: Integer);

    // -----------------------------------------------------------------------
    // Frame sending
    // -----------------------------------------------------------------------
    procedure _SendRaw(const AData: TBytes);
    procedure _SendFrame(AType, AFlags: Byte; AStreamID: Cardinal;
      APayload: PByte; APayLen: Integer);

    procedure _GoAway(ALastStreamID: Cardinal; AErr: Cardinal);

    // Server push: send PUSH_PROMISE on AAssocStream, then HEADERS+DATA on the
    // promised (even) stream.  AAssocStream is the client stream that triggered push.
    procedure _SendPushPromiseAndResponse(AAssocStreamID: Cardinal;
      const APush: TPoseidonPushResource;
      const AScheme, AAuthority: string);

    // Flow control helpers
    procedure _SendWindowUpdate(AStreamID: Cardinal; AIncrement: Integer);
    procedure _DrainPendingStream(AStream: TH2Stream);
    procedure _CloseStreamAfterSend(AStream: TH2Stream);

  public
    constructor Create(AConn: Pointer;
      ASendProc: TH2SendProc; ACloseProc: TH2CloseProc;
      AOnRequest: TH2RequestCallback;
      AMaxConcurrentStreams: Cardinal = 100;
      AInitialWindowSize:    Cardinal = 65535);
    destructor Destroy; override;

    // Feed incoming raw bytes (called from _ProcessRecv)
    procedure ProcessData(ABuf: PByte; ALen: Integer);

    // Send a complete HTTP/2 response for a given stream
    procedure SendResponse(AStreamID: Cardinal; AStatus: Integer;
      const AContentType: string; const ABody: TBytes;
      const AExtra: TArray<TPair<string, string>>);

    // Send server SETTINGS once after upgrade/preface
    procedure SendInitialSettings;

    // Dispatch the initial HTTP/1.1 upgrade request as h2c stream 1.
    // Creates a synthetic stream 1 and runs it through the normal request handler.
    procedure DispatchH2CInitialRequest(const AMethod, APath, AQueryString,
      ARemoteAddr, AHost, AContentType: string;
      const AHeaders: TArray<TPair<string, string>>;
      const ABody: TBytes);

    property GoAwaySent: Boolean read FGoAwaySent;
  end;

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const
  H2_FRAME_DATA          = 0;
  H2_FRAME_HEADERS       = 1;
  H2_FRAME_PRIORITY      = 2;
  H2_FRAME_RST_STREAM    = 3;
  H2_FRAME_SETTINGS      = 4;
  H2_FRAME_PUSH_PROMISE  = 5;
  H2_FRAME_PING          = 6;
  H2_FRAME_GOAWAY        = 7;
  H2_FRAME_WINDOW_UPDATE = 8;
  H2_FRAME_CONTINUATION  = 9;

  H2_FLAG_END_STREAM  = $01;
  H2_FLAG_END_HEADERS = $04;
  H2_FLAG_PADDED      = $08;
  H2_FLAG_PRIORITY    = $20;
  H2_FLAG_ACK         = $01;

  H2_SETTINGS_HEADER_TABLE_SIZE      = 1;
  H2_SETTINGS_ENABLE_PUSH            = 2;
  H2_SETTINGS_MAX_CONCURRENT_STREAMS = 3;
  H2_SETTINGS_INITIAL_WINDOW_SIZE    = 4;
  H2_SETTINGS_MAX_FRAME_SIZE         = 5;
  H2_SETTINGS_MAX_HEADER_LIST_SIZE   = 6;

  H2_ERR_NO_ERROR            = 0;
  H2_ERR_PROTOCOL_ERROR      = 1;
  H2_ERR_INTERNAL_ERROR      = 2;
  H2_ERR_FLOW_CONTROL_ERROR  = 3;
  H2_ERR_SETTINGS_TIMEOUT    = 4;
  H2_ERR_STREAM_CLOSED       = 5;
  H2_ERR_FRAME_SIZE_ERROR    = 6;
  H2_ERR_REFUSED_STREAM      = 7;
  H2_ERR_CANCEL              = 8;
  H2_ERR_COMPRESSION_ERROR   = 9;
  H2_ERR_CONNECT_ERROR       = 10;
  H2_ERR_ENHANCE_YOUR_CALM   = 11;
  H2_ERR_INADEQUATE_SECURITY = 12;
  H2_ERR_HTTP_1_1_REQUIRED   = 13;

  H2_CLIENT_PREFACE = 'PRI * HTTP/2.0'#13#10#13#10'SM'#13#10#13#10;
  H2_PREFACE_LEN    = 24;

implementation

// Client connection preface — RFC 7540 §3.5 (24 bytes, no null terminator)
const
  H2_PREFACE_BYTES: array[0..23] of Byte = (
    $50,$52,$49,$20,$2A,$20,$48,$54,$54,$50,$2F,$32,$2E,$30,$0D,$0A,
    $0D,$0A,$53,$4D,$0D,$0A,$0D,$0A);
  // "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"

// ===========================================================================
// TH2Stream
// ===========================================================================

destructor TH2Stream.Destroy;
begin
  inherited Destroy;
end;

// ===========================================================================
// TH2Conn — constructor / destructor
// ===========================================================================

constructor TH2Conn.Create(AConn: Pointer;
  ASendProc: TH2SendProc; ACloseProc: TH2CloseProc;
  AOnRequest: TH2RequestCallback;
  AMaxConcurrentStreams: Cardinal = 100;
  AInitialWindowSize:    Cardinal = 65535);
begin
  inherited Create;
  FConn      := AConn;
  FSendProc  := ASendProc;
  FCloseProc := ACloseProc;
  FOnRequest := AOnRequest;

  FHpack := TH2HpackCodec.Create;

  FPrefaceReceived := False;
  FSettingsSent    := False;
  FGoAwaySent      := False;

  SetLength(FFrameBuf, 0);
  FFrameLen := 0;

  FContinStreamID    := 0;
  FContinHeadersLen  := 0;
  SetLength(FContinHeaders, 0);

  FStreams      := TDictionary<Cardinal, TH2Stream>.Create;
  FLastStreamID := 0;

  FPeerMaxFrameSize := 16384;
  FPeerInitWinSize  := 65535;

  // R-2
  FActiveStreams := 0;
  FDeferClose    := False;

  // Server push (RFC 7540 §8.2)
  FNextPushStreamID := 2;      // first server-initiated stream is even
  FClientEnablePush := True;   // default: push accepted until client says otherwise

  // P-1
  FMaxConcurrentStreams := AMaxConcurrentStreams;
  FInitialWindowSize    := AInitialWindowSize;

  // Flow control — start at RFC 7540 default (65535); updated by peer SETTINGS
  FConnSendWindow := 65535;
  FConnRecvWindow := 65535;
end;

destructor TH2Conn.Destroy;
var
  LPair: TPair<Cardinal, TH2Stream>;
begin
  for LPair in FStreams do
    LPair.Value.Free;
  FStreams.Free;
  FreeAndNil(FHpack);
  inherited Destroy;
end;

// ===========================================================================
// Raw send helpers
// ===========================================================================

procedure TH2Conn._SendRaw(const AData: TBytes);
begin
  if Assigned(FSendProc) then
    FSendProc(FConn, AData);
end;

// Build and send a complete HTTP/2 frame.
// APayload may be nil when APayLen = 0.
procedure TH2Conn._SendFrame(AType, AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
var
  LFrame: TBytes;
  LSID:   Cardinal;
begin
  SetLength(LFrame, 9 + APayLen);
  // 3-byte length (big-endian)
  LFrame[0] := (APayLen shr 16) and $FF;
  LFrame[1] := (APayLen shr  8) and $FF;
  LFrame[2] :=  APayLen         and $FF;
  LFrame[3] := AType;
  LFrame[4] := AFlags;
  // 4-byte stream ID (top bit = 0, big-endian)
  LSID := AStreamID and $7FFFFFFF;
  LFrame[5] := (LSID shr 24) and $FF;
  LFrame[6] := (LSID shr 16) and $FF;
  LFrame[7] := (LSID shr  8) and $FF;
  LFrame[8] :=  LSID         and $FF;
  if (APayLen > 0) and (APayload <> nil) then
    Move(APayload^, LFrame[9], APayLen);
  _SendRaw(LFrame);
end;

// ===========================================================================
// GOAWAY
// ===========================================================================

procedure TH2Conn._GoAway(ALastStreamID: Cardinal; AErr: Cardinal);
var
  LPayload: TBytes;
  LLSID:    Cardinal;
begin
  if FGoAwaySent then Exit;
  FGoAwaySent := True;
  SetLength(LPayload, 8);
  LLSID := ALastStreamID and $7FFFFFFF;
  LPayload[0] := (LLSID shr 24) and $FF;
  LPayload[1] := (LLSID shr 16) and $FF;
  LPayload[2] := (LLSID shr  8) and $FF;
  LPayload[3] :=  LLSID         and $FF;
  LPayload[4] := (AErr  shr 24) and $FF;
  LPayload[5] := (AErr  shr 16) and $FF;
  LPayload[6] := (AErr  shr  8) and $FF;
  LPayload[7] :=  AErr          and $FF;
  _SendFrame(H2_FRAME_GOAWAY, 0, 0, @LPayload[0], 8);
  // Defer close until all active streams complete
  if FActiveStreams > 0 then
    FDeferClose := True
  else if Assigned(FCloseProc) then
    FCloseProc(FConn);
end;

// ===========================================================================
// Flow control helpers
// ===========================================================================

procedure TH2Conn._SendWindowUpdate(AStreamID: Cardinal; AIncrement: Integer);
var
  LPayload: TBytes;
  LInc:     Cardinal;
begin
  if AIncrement <= 0 then Exit;
  LInc := Cardinal(AIncrement) and $7FFFFFFF;
  SetLength(LPayload, 4);
  LPayload[0] := (LInc shr 24) and $FF;
  LPayload[1] := (LInc shr 16) and $FF;
  LPayload[2] := (LInc shr  8) and $FF;
  LPayload[3] :=  LInc         and $FF;
  _SendFrame(H2_FRAME_WINDOW_UPDATE, 0, AStreamID, @LPayload[0], 4);
end;

procedure TH2Conn._CloseStreamAfterSend(AStream: TH2Stream);
begin
  // Called when all pending DATA has been flushed.
  // Mirrors the cleanup in _DispatchStream's finally block.
  FStreams.Remove(AStream.StreamID);
  AStream.Free;
  if TInterlocked.Decrement(FActiveStreams) = 0 then
    if FDeferClose and Assigned(FCloseProc) then
      FCloseProc(FConn);
end;

procedure TH2Conn._DrainPendingStream(AStream: TH2Stream);
// Send buffered DATA frames when new window credit arrives.
// Called from _HandleWindowUpdate for stream-level or connection-level updates.
var
  LRemaining: Integer;
  LChunkSize: Integer;
  LAvail:     Integer;
  LFinal:     Boolean;
begin
  if (AStream.PendingBody = nil) or
     (AStream.PendingBodyOfs >= Length(AStream.PendingBody)) then
    Exit;

  while AStream.PendingBodyOfs < Length(AStream.PendingBody) do
  begin
    // Respect both connection and stream windows
    LAvail := FConnSendWindow;
    if LAvail > AStream.SendWindow then LAvail := AStream.SendWindow;
    if LAvail <= 0 then Break;

    LRemaining := Length(AStream.PendingBody) - AStream.PendingBodyOfs;
    LChunkSize := LRemaining;
    if LChunkSize > LAvail          then LChunkSize := LAvail;
    if LChunkSize > FPeerMaxFrameSize then LChunkSize := FPeerMaxFrameSize;

    LFinal := (AStream.PendingBodyOfs + LChunkSize >= Length(AStream.PendingBody));
    if LFinal then
      _SendFrame(H2_FRAME_DATA, H2_FLAG_END_STREAM, AStream.StreamID,
        @AStream.PendingBody[AStream.PendingBodyOfs], LChunkSize)
    else
      _SendFrame(H2_FRAME_DATA, 0, AStream.StreamID,
        @AStream.PendingBody[AStream.PendingBodyOfs], LChunkSize);

    Dec(FConnSendWindow,     LChunkSize);
    Dec(AStream.SendWindow,  LChunkSize);
    Inc(AStream.PendingBodyOfs, LChunkSize);
  end;

  // If all pending data was sent, close the stream
  if AStream.PendingBodyOfs >= Length(AStream.PendingBody) then
  begin
    AStream.PendingBody    := nil;
    AStream.PendingBodyOfs := 0;
    _CloseStreamAfterSend(AStream);
  end;
end;

// ===========================================================================
// SendInitialSettings
// ===========================================================================

procedure TH2Conn.SendInitialSettings;
var
  LPayload: TBytes;
  LPos:     Integer;

  procedure PutSetting(AID: Word; AVal: Cardinal);
  begin
    LPayload[LPos + 0] := (AID  shr 8) and $FF;
    LPayload[LPos + 1] :=  AID         and $FF;
    LPayload[LPos + 2] := (AVal shr 24) and $FF;
    LPayload[LPos + 3] := (AVal shr 16) and $FF;
    LPayload[LPos + 4] := (AVal shr  8) and $FF;
    LPayload[LPos + 5] :=  AVal         and $FF;
    Inc(LPos, 6);
  end;

begin
  // 5 settings × 6 bytes each
  SetLength(LPayload, 30);
  LPos := 0;
  PutSetting(H2_SETTINGS_HEADER_TABLE_SIZE,      4096);
  PutSetting(H2_SETTINGS_ENABLE_PUSH,            1);
  PutSetting(H2_SETTINGS_MAX_CONCURRENT_STREAMS, FMaxConcurrentStreams);
  PutSetting(H2_SETTINGS_INITIAL_WINDOW_SIZE,    FInitialWindowSize);
  PutSetting(H2_SETTINGS_MAX_FRAME_SIZE,         16384);
  _SendFrame(H2_FRAME_SETTINGS, 0, 0, @LPayload[0], 30);
  FSettingsSent := True;
end;

// ===========================================================================
// ProcessData — main entry point called by the server on new bytes
// ===========================================================================

procedure TH2Conn.ProcessData(ABuf: PByte; ALen: Integer);
var
  LNeeded:   Integer;
  LPayLen:   Integer;
  LType:     Byte;
  LFlags:    Byte;
  LSIDRaw:   Cardinal;
  LStreamID: Cardinal;
  LFBuf:     PByte;
begin
  if FGoAwaySent then Exit;

  // Append to accumulator
  LNeeded := FFrameLen + ALen;
  if LNeeded > Length(FFrameBuf) then
    SetLength(FFrameBuf, LNeeded + 4096);
  Move(ABuf^, FFrameBuf[FFrameLen], ALen);
  Inc(FFrameLen, ALen);

  // Check preface
  if not FPrefaceReceived then
  begin
    if FFrameLen < H2_PREFACE_LEN then Exit; // need more data
    if not CompareMem(@FFrameBuf[0], @H2_PREFACE_BYTES[0], H2_PREFACE_LEN) then
    begin
      _GoAway(0, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    FPrefaceReceived := True;
    // Remove preface from buffer
    Move(FFrameBuf[H2_PREFACE_LEN], FFrameBuf[0], FFrameLen - H2_PREFACE_LEN);
    Dec(FFrameLen, H2_PREFACE_LEN);
    // Send our settings immediately
    if not FSettingsSent then
      SendInitialSettings;
  end;

  // Parse frames
  while FFrameLen >= 9 do
  begin
    LFBuf   := @FFrameBuf[0];
    LPayLen := (Integer(LFBuf[0]) shl 16) or
               (Integer(LFBuf[1]) shl  8) or
                Integer(LFBuf[2]);
    if FFrameLen < 9 + LPayLen then Break; // incomplete frame

    LType  := LFBuf[3];
    LFlags := LFBuf[4];
    LSIDRaw := (Cardinal(LFBuf[5]) shl 24) or
               (Cardinal(LFBuf[6]) shl 16) or
               (Cardinal(LFBuf[7]) shl  8) or
                Cardinal(LFBuf[8]);
    LStreamID := LSIDRaw and $7FFFFFFF;

    // RFC 7540 §6.10: while awaiting CONTINUATION, only CONTINUATION is allowed
    if (FContinStreamID <> 0) and (LType <> H2_FRAME_CONTINUATION) then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;

    if LPayLen > 0 then
      _ProcessFrame(LType, LFlags, LStreamID, @FFrameBuf[9], LPayLen)
    else
      _ProcessFrame(LType, LFlags, LStreamID, nil, 0);

    if FGoAwaySent then Exit;

    // Advance buffer
    LNeeded := FFrameLen - (9 + LPayLen);
    if LNeeded > 0 then
      Move(FFrameBuf[9 + LPayLen], FFrameBuf[0], LNeeded);
    FFrameLen := LNeeded;
  end;
end;

// ===========================================================================
// _ProcessFrame — dispatch by type
// ===========================================================================

procedure TH2Conn._ProcessFrame(AType, AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
begin
  // RFC 7540 §4.2 — reject frames whose payload exceeds SETTINGS_MAX_FRAME_SIZE
  if APayLen > FPeerMaxFrameSize then
  begin
    _GoAway(AStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;

  case AType of
    H2_FRAME_DATA:
      _HandleData(AFlags, AStreamID, APayload, APayLen);
    H2_FRAME_HEADERS:
      _HandleHeaders(AFlags, AStreamID, APayload, APayLen);
    H2_FRAME_PRIORITY:
      ; // ignore — RFC 7540 §6.3 says it may arrive on any stream state
    H2_FRAME_RST_STREAM:
      _HandleRstStream(AStreamID, APayload, APayLen);
    H2_FRAME_SETTINGS:
      _HandleSettings(AFlags, APayload, APayLen);
    H2_FRAME_PUSH_PROMISE:
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR); // client must not send push-promise
    H2_FRAME_PING:
      _HandlePing(AFlags, APayload, APayLen);
    H2_FRAME_GOAWAY:
      _HandleGoAway(APayload, APayLen);
    H2_FRAME_WINDOW_UPDATE:
      _HandleWindowUpdate(AStreamID, APayload, APayLen);
    H2_FRAME_CONTINUATION:
      _HandleContinuation(AFlags, AStreamID, APayload, APayLen);
    // Unknown frame types are ignored (RFC 7540 §4.1)
  end;
end;

// ===========================================================================
// _HandleSettings
// ===========================================================================

procedure TH2Conn._HandleSettings(AFlags: Byte; APayload: PByte; APayLen: Integer);
var
  LPos:        Integer;
  LID:         Word;
  LVal:        Cardinal;
  LDelta:      Integer;
  LStreamPair: TPair<Cardinal, TH2Stream>;
begin
  // ACK — nothing to do
  if (AFlags and H2_FLAG_ACK) <> 0 then Exit;

  // Each setting is 6 bytes
  if (APayLen mod 6) <> 0 then
  begin
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;

  LPos := 0;
  while LPos < APayLen do
  begin
    LID  := (Word(APayload[LPos]) shl 8) or Word(APayload[LPos + 1]);
    LVal := (Cardinal(APayload[LPos + 2]) shl 24) or
            (Cardinal(APayload[LPos + 3]) shl 16) or
            (Cardinal(APayload[LPos + 4]) shl  8) or
             Cardinal(APayload[LPos + 5]);
    Inc(LPos, 6);
    case LID of
      H2_SETTINGS_HEADER_TABLE_SIZE:
        FHpack.MaxDynTableSize := LVal;
      H2_SETTINGS_ENABLE_PUSH:
        FClientEnablePush := (LVal <> 0);
      H2_SETTINGS_MAX_FRAME_SIZE:
        begin
          if (LVal < 16384) or (LVal > 16777215) then
          begin
            _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
            Exit;
          end;
          FPeerMaxFrameSize := LVal;
        end;
      H2_SETTINGS_INITIAL_WINDOW_SIZE:
        begin
          // RFC 7540 §6.9.2 — update existing stream send windows by the delta
          if LVal > $7FFFFFFF then
          begin
            _GoAway(FLastStreamID, H2_ERR_FLOW_CONTROL_ERROR);
            Exit;
          end;
          LDelta := Integer(LVal) - Integer(FPeerInitWinSize);
          FPeerInitWinSize := LVal;
          for LStreamPair in FStreams do
            Inc(LStreamPair.Value.SendWindow, LDelta);
        end;
      // Other settings: silently accept
    end;
  end;

  // Send SETTINGS ACK
  _SendFrame(H2_FRAME_SETTINGS, H2_FLAG_ACK, 0, nil, 0);
end;

// ===========================================================================
// _HandlePing
// ===========================================================================

procedure TH2Conn._HandlePing(AFlags: Byte; APayload: PByte; APayLen: Integer);
begin
  if (AFlags and H2_FLAG_ACK) <> 0 then Exit; // ACK to our ping — ignore
  if APayLen <> 8 then
  begin
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;
  // Echo back with ACK
  _SendFrame(H2_FRAME_PING, H2_FLAG_ACK, 0, APayload, 8);
end;

// ===========================================================================
// _HandleGoAway
// ===========================================================================

procedure TH2Conn._HandleGoAway(APayload: PByte; APayLen: Integer);
begin
  FGoAwaySent := True; // suppress further sends
  if Assigned(FCloseProc) then
    FCloseProc(FConn);
end;

// ===========================================================================
// _HandleRstStream
// ===========================================================================

procedure TH2Conn._HandleRstStream(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
var
  LStream: TH2Stream;
begin
  if APayLen <> 4 then
  begin
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;
  if FStreams.TryGetValue(AStreamID, LStream) then
  begin
    FStreams.Remove(AStreamID);
    LStream.Free;
  end;
end;

// ===========================================================================
// _HandleWindowUpdate
// ===========================================================================

procedure TH2Conn._HandleWindowUpdate(AStreamID: Cardinal; APayload: PByte; APayLen: Integer);
// RFC 7540 §6.9 — increment the appropriate flow-control window and drain
// any buffered DATA that was waiting for credit.
var
  LInc:     Integer;
  LStream:  TH2Stream;
  LPair:    TPair<Cardinal, TH2Stream>;
  LRst:     TBytes;
  LErrCode: Cardinal;
begin
  if APayLen <> 4 then
  begin
    _GoAway(FLastStreamID, H2_ERR_FRAME_SIZE_ERROR);
    Exit;
  end;
  LInc := Integer(
    (Cardinal(APayload[0]) shl 24) or (Cardinal(APayload[1]) shl 16) or
    (Cardinal(APayload[2]) shl  8) or  Cardinal(APayload[3])) and $7FFFFFFF;
  if LInc = 0 then
  begin
    // RFC 7540 §6.9 — increment of 0 is a PROTOCOL_ERROR
    if AStreamID = 0 then
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR)
    else
    begin
      LErrCode := H2_ERR_PROTOCOL_ERROR;
      SetLength(LRst, 4);
      LRst[0] := (LErrCode shr 24) and $FF; LRst[1] := (LErrCode shr 16) and $FF;
      LRst[2] := (LErrCode shr  8) and $FF; LRst[3] :=  LErrCode         and $FF;
      _SendFrame(H2_FRAME_RST_STREAM, 0, AStreamID, @LRst[0], 4);
    end;
    Exit;
  end;

  if AStreamID = 0 then
  begin
    // Connection-level window update
    if FConnSendWindow > $7FFFFFFF - LInc then
    begin
      _GoAway(0, H2_ERR_FLOW_CONTROL_ERROR);
      Exit;
    end;
    Inc(FConnSendWindow, LInc);
    // Drain pending streams — iterate once; _DrainPendingStream may free the
    // stream which modifies FStreams, so we break after each drain call and
    // rely on the next WINDOW_UPDATE (or re-entry) to continue.
    for LPair in FStreams do
      if (LPair.Value.PendingBody <> nil) and
         (LPair.Value.PendingBodyOfs < Length(LPair.Value.PendingBody)) then
      begin
        _DrainPendingStream(LPair.Value);
        Break;
      end;
  end
  else
  begin
    // Stream-level window update
    if FStreams.TryGetValue(AStreamID, LStream) then
    begin
      if LStream.SendWindow > $7FFFFFFF - LInc then
      begin
        LErrCode := H2_ERR_FLOW_CONTROL_ERROR;
        SetLength(LRst, 4);
        LRst[0] := (LErrCode shr 24) and $FF; LRst[1] := (LErrCode shr 16) and $FF;
        LRst[2] := (LErrCode shr  8) and $FF; LRst[3] :=  LErrCode         and $FF;
        _SendFrame(H2_FRAME_RST_STREAM, 0, AStreamID, @LRst[0], 4);
        Exit;
      end;
      Inc(LStream.SendWindow, LInc);
      _DrainPendingStream(LStream);
    end;
  end;
end;

// ===========================================================================
// _HandleHeaders + _DecodeRequestHeaders
// ===========================================================================

procedure TH2Conn._HandleHeaders(AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer; AContinuation: Boolean);
var
  LStream:   TH2Stream;
  LPadLen:   Integer;
  LHasPad:   Boolean;
  LHasPri:   Boolean;
  LEndHdrs:  Boolean;
  LEndStrm:  Boolean;
  LTotal:    Integer;
begin
  if AStreamID = 0 then
  begin
    _GoAway(0, H2_ERR_PROTOCOL_ERROR);
    Exit;
  end;

  if AStreamID > FLastStreamID then
    FLastStreamID := AStreamID;

  LHasPad  := (not AContinuation) and ((AFlags and H2_FLAG_PADDED)   <> 0);
  LHasPri  := (not AContinuation) and ((AFlags and H2_FLAG_PRIORITY) <> 0);
  LEndHdrs := (AFlags and H2_FLAG_END_HEADERS) <> 0;
  LEndStrm := (AFlags and H2_FLAG_END_STREAM)  <> 0;

  LPadLen := 0;
  if LHasPad then
  begin
    if APayLen < 1 then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    LPadLen := APayload[0];
    Inc(APayload);
    Dec(APayLen);
  end;
  if LHasPri then
  begin
    if APayLen < 5 then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    Inc(APayload, 5);
    Dec(APayLen, 5);
  end;
  // Remove padding from end
  if LHasPad then
  begin
    if LPadLen >= APayLen then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    Dec(APayLen, LPadLen);
  end;

  // Get or create stream
  if not FStreams.TryGetValue(AStreamID, LStream) then
  begin
    LStream := TH2Stream.Create;
    LStream.StreamID   := AStreamID;
    LStream.State      := hssOpen;
    // Initialize per-stream flow control windows
    LStream.SendWindow := FPeerInitWinSize;           // what the peer allows us to send
    LStream.RecvWindow := Integer(FInitialWindowSize); // what we allow the peer to send
    FStreams.Add(AStreamID, LStream);
  end;

  if LEndHdrs then
  begin
    // Accumulate any CONTINUATION bytes already buffered, then decode
    if FContinHeadersLen > 0 then
    begin
      // Append final fragment — reuse LTotal as combined length
      LTotal := FContinHeadersLen + APayLen;
      if LTotal > Length(FContinHeaders) then
        SetLength(FContinHeaders, LTotal);
      Move(APayload^, FContinHeaders[FContinHeadersLen], APayLen);
      _DecodeRequestHeaders(LStream, @FContinHeaders[0], LTotal);
      FContinHeadersLen := 0;
      FContinStreamID   := 0;
    end
    else
      _DecodeRequestHeaders(LStream, APayload, APayLen);

    LStream.HeadersComplete := True;
    LStream.EndStream := LEndStrm;
    if LEndStrm then
      _DispatchStream(LStream);
  end
  else
  begin
    // Headers are split; buffer and wait for CONTINUATION
    FContinStreamID := AStreamID;
    if FContinHeadersLen + APayLen > Length(FContinHeaders) then
      SetLength(FContinHeaders, FContinHeadersLen + APayLen + 4096);
    Move(APayload^, FContinHeaders[FContinHeadersLen], APayLen);
    Inc(FContinHeadersLen, APayLen);
    LStream.EndStream := LEndStrm;
  end;
end;

procedure TH2Conn._HandleContinuation(AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
begin
  if AStreamID <> FContinStreamID then
  begin
    _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
    Exit;
  end;
  _HandleHeaders(AFlags, AStreamID, APayload, APayLen, True);
end;

// ===========================================================================
// _HandleData
// ===========================================================================

procedure TH2Conn._HandleData(AFlags: Byte; AStreamID: Cardinal;
  APayload: PByte; APayLen: Integer);
var
  LStream:  TH2Stream;
  LPadLen:  Integer;
  LDataLen: Integer;
begin
  if AStreamID = 0 then
  begin
    _GoAway(0, H2_ERR_PROTOCOL_ERROR);
    Exit;
  end;

  LPadLen := 0;
  if (AFlags and H2_FLAG_PADDED) <> 0 then
  begin
    if APayLen < 1 then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    LPadLen := APayload[0];
    Inc(APayload);
    Dec(APayLen);
    if LPadLen >= APayLen then
    begin
      _GoAway(FLastStreamID, H2_ERR_PROTOCOL_ERROR);
      Exit;
    end;
    Dec(APayLen, LPadLen);
  end;

  LDataLen := APayLen;

  if not FStreams.TryGetValue(AStreamID, LStream) then Exit;

  // Append body
  if LDataLen > 0 then
  begin
    if LStream.BodyLen + LDataLen > Length(LStream.Body) then
      SetLength(LStream.Body, LStream.BodyLen + LDataLen + 4096);
    Move(APayload^, LStream.Body[LStream.BodyLen], LDataLen);
    Inc(LStream.BodyLen, LDataLen);

    // Consume from our receive windows; replenish when < 50%
    Dec(FConnRecvWindow,    LDataLen);
    Dec(LStream.RecvWindow, LDataLen);
    if FConnRecvWindow < 65535 div 2 then
    begin
      _SendWindowUpdate(0, 65535 - FConnRecvWindow);
      FConnRecvWindow := 65535;
    end;
    if LStream.RecvWindow < Integer(FInitialWindowSize) div 2 then
    begin
      _SendWindowUpdate(LStream.StreamID,
        Integer(FInitialWindowSize) - LStream.RecvWindow);
      LStream.RecvWindow := Integer(FInitialWindowSize);
    end;
  end;

  if (AFlags and H2_FLAG_END_STREAM) <> 0 then
  begin
    LStream.EndStream := True;
    if LStream.HeadersComplete then
      _DispatchStream(LStream);
  end;
end;

// ===========================================================================
// _DecodeRequestHeaders — delegates to FHpack
// ===========================================================================

procedure TH2Conn._DecodeRequestHeaders(AStream: TH2Stream;
  APayload: PByte; APayLen: Integer);
var
  LMethod:    string;
  LPath:      string;
  LScheme:    string;
  LAuthority: string;
  LHeaders:   TArray<TPair<string, string>>;
begin
  if not FHpack.DecodeHeaders(APayload, APayLen,
    LMethod, LPath, LScheme, LAuthority, LHeaders,
    procedure begin _GoAway(FLastStreamID, H2_ERR_COMPRESSION_ERROR) end)
  then
    Exit;

  AStream.Method    := LMethod;
  AStream.Path      := LPath;
  AStream.Scheme    := LScheme;
  AStream.Authority := LAuthority;
  AStream.RequestHeaders := LHeaders;
end;

// ===========================================================================
// _DispatchStream — build TH2RequestData and call FOnRequest
// ===========================================================================

procedure TH2Conn._DispatchStream(AStream: TH2Stream);
var
  LReq: TH2RequestData;
  LStatus: Integer;
  LContentType: string;
  LBody: TBytes;
  LExtra: TArray<TPair<string, string>>;
  LPushResources: TArray<TPoseidonPushResource>;
  I: Integer;
  LQ: Integer;
begin
  LReq.StreamID  := AStream.StreamID;
  LReq.Method    := AStream.Method;
  LReq.Protocol  := 'HTTP/2';
  LReq.Host      := AStream.Authority;
  LReq.RemoteAddr := '';  // caller sets if available

  // Split path and query string
  LQ := Pos('?', AStream.Path);
  if LQ > 0 then
  begin
    LReq.Path        := Copy(AStream.Path, 1, LQ - 1);
    LReq.QueryString := Copy(AStream.Path, LQ + 1, MaxInt);
  end
  else
  begin
    LReq.Path        := AStream.Path;
    LReq.QueryString := '';
  end;

  LReq.Headers := AStream.RequestHeaders;

  // Extract content-type from headers
  LReq.ContentType := '';
  for I := 0 to Length(AStream.RequestHeaders) - 1 do
    if SameText(AStream.RequestHeaders[I].Key, 'content-type') then
    begin
      LReq.ContentType := AStream.RequestHeaders[I].Value;
      Break;
    end;

  if AStream.BodyLen > 0 then
  begin
    SetLength(LReq.Body, AStream.BodyLen);
    Move(AStream.Body[0], LReq.Body[0], AStream.BodyLen);
  end;

  LStatus := 200;
  LContentType := 'text/plain';
  SetLength(LBody, 0);
  SetLength(LExtra, 0);
  SetLength(LPushResources, 0);

  // Track active streams
  TInterlocked.Increment(FActiveStreams);
  try
    try
      if Assigned(FOnRequest) then
        FOnRequest(LReq, LStatus, LContentType, LBody, LExtra, LPushResources);
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, '[h2] dispatch error: ', E.Message);
        LStatus := 500;
        LContentType := 'text/plain';
        SetLength(LBody, 0);
        SetLength(LPushResources, 0);
      end;
    end;

    // Send server push resources before the actual response (RFC 7540 §8.2)
    if FClientEnablePush then
      for I := 0 to Length(LPushResources) - 1 do
        _SendPushPromiseAndResponse(AStream.StreamID, LPushResources[I],
          AStream.Scheme, AStream.Authority);

    SendResponse(AStream.StreamID, LStatus, LContentType, LBody, LExtra);
  finally
    // If SendResponse buffered pending DATA, keep the stream alive until
    // _DrainPendingStream finishes. Cleanup then deferred to _CloseStreamAfterSend.
    if Length(AStream.PendingBody) = 0 then
    begin
      FStreams.Remove(AStream.StreamID);
      AStream.Free;
      // Signal deferred close when last stream completes
      if TInterlocked.Decrement(FActiveStreams) = 0 then
        if FDeferClose and Assigned(FCloseProc) then
          FCloseProc(FConn);
    end;
    // else: FActiveStreams stays incremented; cleanup in _CloseStreamAfterSend
  end;
end;

// ===========================================================================
// SendResponse — send HEADERS [+ DATA] frame(s)
// ===========================================================================

procedure TH2Conn.SendResponse(AStreamID: Cardinal; AStatus: Integer;
  const AContentType: string; const ABody: TBytes;
  const AExtra: TArray<TPair<string, string>>);
// Respects per-stream and connection flow-control windows.
// If the send window is exhausted, remaining data is buffered in the stream
// and flushed when _HandleWindowUpdate grants more credit.
var
  LHdrPayload: TBytes;
  LBodyLen:    Integer;
  LHFlags:     Byte;
  LDataOfs:    Integer;
  LChunkSize:  Integer;
  LRemaining:  Integer;
  LAvail:      Integer;
  LFinal:      Boolean;
  LStream:     TH2Stream;
begin
  if FGoAwaySent then Exit;

  LBodyLen    := Length(ABody);
  LHdrPayload := FHpack.EncodeResponseHeaders(AStatus, AContentType, LBodyLen, AExtra);

  if LBodyLen = 0 then
  begin
    // HEADERS with END_HEADERS + END_STREAM (no body, no window needed)
    LHFlags := H2_FLAG_END_HEADERS or H2_FLAG_END_STREAM;
    _SendFrame(H2_FRAME_HEADERS, LHFlags, AStreamID, @LHdrPayload[0], Length(LHdrPayload));
    Exit;
  end;

  // HEADERS frame (END_HEADERS only — DATA follows)
  _SendFrame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS, AStreamID,
    @LHdrPayload[0], Length(LHdrPayload));

  // Locate stream for window tracking (it must exist, created on HEADERS receipt)
  if not FStreams.TryGetValue(AStreamID, LStream) then Exit;

  // DATA in chunks, bounded by both windows and FPeerMaxFrameSize
  LDataOfs   := 0;
  LRemaining := LBodyLen;
  while LRemaining > 0 do
  begin
    LAvail := FConnSendWindow;
    if LAvail > LStream.SendWindow then LAvail := LStream.SendWindow;
    if LAvail <= 0 then Break;  // window exhausted — buffer the rest

    LChunkSize := LRemaining;
    if LChunkSize > LAvail          then LChunkSize := LAvail;
    if LChunkSize > FPeerMaxFrameSize then LChunkSize := FPeerMaxFrameSize;

    LFinal := (LDataOfs + LChunkSize >= LBodyLen);
    if LFinal then
      _SendFrame(H2_FRAME_DATA, H2_FLAG_END_STREAM, AStreamID,
        @ABody[LDataOfs], LChunkSize)
    else
      _SendFrame(H2_FRAME_DATA, 0, AStreamID,
        @ABody[LDataOfs], LChunkSize);

    Dec(FConnSendWindow,    LChunkSize);
    Dec(LStream.SendWindow, LChunkSize);
    Inc(LDataOfs,   LChunkSize);
    Dec(LRemaining, LChunkSize);
  end;

  // If window was exhausted before all data was sent, buffer the remainder.
  // _DispatchStream will NOT free the stream when PendingBody is set.
  if LRemaining > 0 then
  begin
    SetLength(LStream.PendingBody, LRemaining);
    Move(ABody[LDataOfs], LStream.PendingBody[0], LRemaining);
    LStream.PendingBodyOfs := 0;
  end;
end;

// ===========================================================================
// Server push — RFC 7540 §8.2
// ===========================================================================

procedure TH2Conn._SendPushPromiseAndResponse(AAssocStreamID: Cardinal;
  const APush: TPoseidonPushResource;
  const AScheme, AAuthority: string);
// Sends a PUSH_PROMISE frame on AAssocStreamID, then synthesises a complete
// HEADERS + DATA response on the server-initiated (even) promised stream.
var
  LPromisedID:  Cardinal;
  LReqHdr:      TBytes;
  LHdrPayload:  TBytes;
  LPPPayload:   TBytes;
  LBodyLen:     Integer;
  LPushStream:  TH2Stream;
begin
  if FGoAwaySent then Exit;

  // Allocate the next server-initiated even stream ID
  LPromisedID       := FNextPushStreamID;
  Inc(FNextPushStreamID, 2);

  // Encode the promised request headers (:method GET, :path, :scheme, :authority)
  LReqHdr := FHpack.EncodeRequestHeaders('GET', APush.Path,
    AScheme, AAuthority);

  // PUSH_PROMISE payload = 4-byte promised-stream-id (MSB=0) + HPACK block
  SetLength(LPPPayload, 4 + Length(LReqHdr));
  LPPPayload[0] := (LPromisedID shr 24) and $7F;
  LPPPayload[1] := (LPromisedID shr 16) and $FF;
  LPPPayload[2] := (LPromisedID shr  8) and $FF;
  LPPPayload[3] :=  LPromisedID         and $FF;
  if Length(LReqHdr) > 0 then
    Move(LReqHdr[0], LPPPayload[4], Length(LReqHdr));

  // Send PUSH_PROMISE on the associated (client-initiated) stream
  _SendFrame(H2_FRAME_PUSH_PROMISE, H2_FLAG_END_HEADERS,
    AAssocStreamID, @LPPPayload[0], Length(LPPPayload));

  // Create the synthetic server-initiated stream
  LPushStream            := TH2Stream.Create;
  LPushStream.StreamID   := LPromisedID;
  LPushStream.State      := hssHalfClosedRemote;
  LPushStream.SendWindow := FPeerInitWinSize;
  LPushStream.RecvWindow := Integer(FInitialWindowSize);
  FStreams.Add(LPromisedID, LPushStream);

  // Build and send the promised response (HEADERS + DATA)
  LBodyLen    := Length(APush.Body);
  LHdrPayload := FHpack.EncodeResponseHeaders(200, APush.ContentType,
    LBodyLen, APush.Extra);

  if LBodyLen = 0 then
    _SendFrame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS or H2_FLAG_END_STREAM,
      LPromisedID, @LHdrPayload[0], Length(LHdrPayload))
  else
  begin
    _SendFrame(H2_FRAME_HEADERS, H2_FLAG_END_HEADERS,
      LPromisedID, @LHdrPayload[0], Length(LHdrPayload));
    _SendFrame(H2_FRAME_DATA, H2_FLAG_END_STREAM,
      LPromisedID, @APush.Body[0], LBodyLen);
  end;

  // Immediately close the synthetic stream — push responses are half-closed
  FStreams.Remove(LPromisedID);
  LPushStream.Free;
end;

// ===========================================================================
// DispatchH2CInitialRequest — synthetic stream 1 for h2c upgrade
// ===========================================================================

procedure TH2Conn.DispatchH2CInitialRequest(const AMethod, APath, AQueryString,
  ARemoteAddr, AHost, AContentType: string;
  const AHeaders: TArray<TPair<string, string>>;
  const ABody: TBytes);
// Creates a synthetic stream 1 (the initial h2c request) and routes it
// through the normal _H2OnRequest callback + SendResponse pipeline.
var
  LStream: TH2Stream;
  LReq: TH2RequestData;
  LStatus: Integer;
  LCT: string;
  LBody: TBytes;
  LExtra: TArray<TPair<string, string>>;
  LPushResources: TArray<TPoseidonPushResource>;
  I: Integer;
begin
  if FGoAwaySent then Exit;

  // Create synthetic stream 1 with initial flow control windows
  LStream := TH2Stream.Create;
  LStream.StreamID   := 1;
  LStream.State      := hssHalfClosedRemote;
  LStream.SendWindow := FPeerInitWinSize;
  LStream.RecvWindow := Integer(FInitialWindowSize);
  FStreams.Add(1, LStream);
  FLastStreamID := 1;

  // Build the request data
  LReq.Method      := AMethod;
  LReq.Path        := APath;
  LReq.QueryString := AQueryString;
  LReq.RemoteAddr  := ARemoteAddr;
  LReq.Host        := AHost;
  LReq.ContentType := AContentType;
  LReq.Protocol    := 'h2c';
  LReq.StreamID    := 1;
  LReq.Headers     := AHeaders;
  LReq.Body        := ABody;

  LStatus := 200;
  LCT := 'application/json';
  SetLength(LBody, 0);
  SetLength(LExtra, 0);
  SetLength(LPushResources, 0);

  TInterlocked.Increment(FActiveStreams);
  try
    try
      if Assigned(FOnRequest) then
        FOnRequest(LReq, LStatus, LCT, LBody, LExtra, LPushResources);
    except
      on E: Exception do
      begin
        Writeln(ErrOutput, '[h2] dispatch error: ', E.Message);
        LStatus := 500;
        LCT := 'application/json';
        SetLength(LBody, 0);
        SetLength(LPushResources, 0);
      end;
    end;
    if FClientEnablePush then
      for I := 0 to Length(LPushResources) - 1 do
        _SendPushPromiseAndResponse(1, LPushResources[I], 'http', AHost);
    SendResponse(1, LStatus, LCT, LBody, LExtra);
  finally
    // Keep stream alive if pending body; otherwise clean up
    if Length(LStream.PendingBody) = 0 then
    begin
      FStreams.Remove(1);
      LStream.Free;
      if TInterlocked.Decrement(FActiveStreams) = 0 then
        if FDeferClose and Assigned(FCloseProc) then
          FCloseProc(FConn);
    end;
    // else: cleanup deferred to _CloseStreamAfterSend via _DrainPendingStream
  end;
end;

end.
