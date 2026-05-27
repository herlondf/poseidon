unit AsyncIO.Net.WebSocket;

// WebSocket (RFC 6455) protocol utilities for the AsyncIO Native provider.
// This unit provides the protocol-level building blocks:
//   - HandshakeAccept: derives the Sec-WebSocket-Accept response value
//   - ParseFrame:      decodes a single inbound frame from a byte buffer
//   - BuildFrame:      encodes a frame for outbound transmission
//   - BuildHandshakeResponse: 101 Switching Protocols response bytes
//
// Integration: the application code (provider/middleware) detects the
// `Upgrade: websocket` header in the HTTP request, sends the handshake
// response via TAsyncIONativeServer raw send hooks, and from that point on
// drives ParseFrame/BuildFrame on the raw socket bytes.

interface

uses
  System.SysUtils,
  System.SyncObjs;

const
  OPCODE_CONTINUATION = $0;
  OPCODE_TEXT         = $1;
  OPCODE_BINARY       = $2;
  OPCODE_CLOSE        = $8;
  OPCODE_PING         = $9;
  OPCODE_PONG         = $A;

  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

type
  TWebSocketFrame = record
    FinFlag:  Boolean;
    Opcode:   Byte;
    Payload:  TBytes;
  end;

  TWebSocketUtils = class
  public
    // Compute Sec-WebSocket-Accept = base64(SHA1(ClientKey + WS_GUID))
    class function HandshakeAccept(const AClientKey: string): string; static;

    // Build the full HTTP/1.1 101 Switching Protocols response bytes.
    class function BuildHandshakeResponse(const AClientKey: string): TBytes; static;

    // Decode one frame from ABuf starting at index 0.
    // Returns True if a complete frame was decoded; AConsumed indicates how
    // many bytes to discard from ABuf afterwards. False (AConsumed=0) means
    // more bytes are needed.
    class function ParseFrame(const ABuf: PByte; ABufLen: Integer;
      out AFrame: TWebSocketFrame; out AConsumed: Integer): Boolean; static;

    // Encode an outbound frame. Server frames are never masked (per RFC 6455).
    class function BuildFrame(AOpcode: Byte; AFin: Boolean;
      const APayload: TBytes): TBytes; static;

    // Convenience helpers
    class function TextFrame(const AText: string): TBytes; static;
    class function BinaryFrame(const AData: TBytes): TBytes; static;
    class function CloseFrame(ACode: Word = 1000): TBytes; static;
    class function PongFrame(const APingPayload: TBytes): TBytes; static;
  end;

  TWSRawSendProc = reference to procedure(const AData: TBytes);
  TWSCloseProc   = reference to procedure;

  IAsyncIOWSConn = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    procedure Send(const AText: string);
    procedure SendBinary(const AData: TBytes);
    procedure Close(ACode: Word = 1000);
    function GetRemoteAddr: string;
    function GetClosed: Boolean;
    property RemoteAddr: string read GetRemoteAddr;
    property Closed: Boolean read GetClosed;
  end;

  TWSMessageCallback = reference to procedure(AConn: IAsyncIOWSConn; const AFrame: TWebSocketFrame);
  TWSCloseCallback   = reference to procedure(AConn: IAsyncIOWSConn);

  TAsyncIOWSConn = class(TInterfacedObject, IAsyncIOWSConn)
  private
    FRemoteAddr: string;
    FSend:       TWSRawSendProc;
    FCloseConn:  TWSCloseProc;
    FClosed:     Boolean;
    FLock:       TCriticalSection;
  public
    constructor Create(const ARemoteAddr: string; const ASend: TWSRawSendProc; const AClose: TWSCloseProc);
    destructor Destroy; override;
    procedure Invalidate;
    procedure Send(const AText: string);
    procedure SendBinary(const AData: TBytes);
    procedure Close(ACode: Word = 1000);
    function GetRemoteAddr: string;
    function GetClosed: Boolean;
  end;

implementation

uses
  System.Classes,
  System.NetEncoding,
  System.Hash;

{ TAsyncIOWSConn }

constructor TAsyncIOWSConn.Create(const ARemoteAddr: string;
  const ASend: TWSRawSendProc; const AClose: TWSCloseProc);
begin
  inherited Create;
  FRemoteAddr := ARemoteAddr;
  FSend       := ASend;
  FCloseConn  := AClose;
  FClosed     := False;
  FLock       := TCriticalSection.Create;
end;

destructor TAsyncIOWSConn.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TAsyncIOWSConn.Invalidate;
begin
  FLock.Enter;
  try
    FClosed    := True;
    FSend      := nil;
    FCloseConn := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TAsyncIOWSConn.Send(const AText: string);
var
  LData: TBytes;
  LSend: TWSRawSendProc;
begin
  FLock.Enter;
  try
    if FClosed then Exit;
    LSend := FSend;
  finally
    FLock.Leave;
  end;
  LData := TWebSocketUtils.TextFrame(AText);
  LSend(LData);
end;

procedure TAsyncIOWSConn.SendBinary(const AData: TBytes);
var
  LData: TBytes;
  LSend: TWSRawSendProc;
begin
  FLock.Enter;
  try
    if FClosed then Exit;
    LSend := FSend;
  finally
    FLock.Leave;
  end;
  LData := TWebSocketUtils.BinaryFrame(AData);
  LSend(LData);
end;

procedure TAsyncIOWSConn.Close(ACode: Word);
var
  LData:  TBytes;
  LSend:  TWSRawSendProc;
  LClose: TWSCloseProc;
begin
  FLock.Enter;
  try
    if FClosed then Exit;
    FClosed    := True;
    LSend      := FSend;
    LClose     := FCloseConn;
    FSend      := nil;
    FCloseConn := nil;
  finally
    FLock.Leave;
  end;
  if Assigned(LSend) then
  begin
    LData := TWebSocketUtils.CloseFrame(ACode);
    LSend(LData);
  end;
  if Assigned(LClose) then
    LClose;
end;

function TAsyncIOWSConn.GetRemoteAddr: string;
begin
  Result := FRemoteAddr;
end;

function TAsyncIOWSConn.GetClosed: Boolean;
begin
  FLock.Enter;
  try
    Result := FClosed;
  finally
    FLock.Leave;
  end;
end;

class function TWebSocketUtils.HandshakeAccept(const AClientKey: string): string;
var
  LSrc:   string;
  LHash:  TBytes;
begin
  LSrc  := AClientKey + WS_GUID;
  LHash := THashSHA1.GetHashBytes(LSrc);
  Result := TNetEncoding.Base64.EncodeBytesToString(LHash);
end;

class function TWebSocketUtils.BuildHandshakeResponse(const AClientKey: string): TBytes;
const
  CRLF = #13#10;
var
  LHdr: string;
begin
  LHdr := 'HTTP/1.1 101 Switching Protocols' + CRLF
        + 'Upgrade: websocket'                + CRLF
        + 'Connection: Upgrade'               + CRLF
        + 'Sec-WebSocket-Accept: ' + HandshakeAccept(AClientKey) + CRLF
        + CRLF;
  Result := TEncoding.ASCII.GetBytes(LHdr);
end;

class function TWebSocketUtils.ParseFrame(const ABuf: PByte; ABufLen: Integer;
  out AFrame: TWebSocketFrame; out AConsumed: Integer): Boolean;
var
  LPos:        Integer;
  LMasked:     Boolean;
  LPLen:       Int64;
  LPayloadLen: Byte;
  LMaskKey:    array[0..3] of Byte;
  I:           Integer;
begin
  Result    := False;
  AConsumed := 0;
  AFrame.FinFlag := False;
  AFrame.Opcode  := 0;
  SetLength(AFrame.Payload, 0);

  if ABufLen < 2 then Exit;

  AFrame.FinFlag := (ABuf[0] and $80) <> 0;
  AFrame.Opcode  := ABuf[0] and $0F;
  LMasked        := (ABuf[1] and $80) <> 0;
  LPayloadLen    := ABuf[1] and $7F;
  LPos := 2;

  if LPayloadLen < 126 then
    LPLen := LPayloadLen
  else if LPayloadLen = 126 then
  begin
    if ABufLen < LPos + 2 then Exit;
    LPLen := (Int64(ABuf[LPos]) shl 8) or Int64(ABuf[LPos + 1]);
    Inc(LPos, 2);
  end
  else  // 127 → 64-bit length
  begin
    if ABufLen < LPos + 8 then Exit;
    LPLen := (Int64(ABuf[LPos    ]) shl 56) or
             (Int64(ABuf[LPos + 1]) shl 48) or
             (Int64(ABuf[LPos + 2]) shl 40) or
             (Int64(ABuf[LPos + 3]) shl 32) or
             (Int64(ABuf[LPos + 4]) shl 24) or
             (Int64(ABuf[LPos + 5]) shl 16) or
             (Int64(ABuf[LPos + 6]) shl  8) or
              Int64(ABuf[LPos + 7]);
    Inc(LPos, 8);
  end;

  if LMasked then
  begin
    if ABufLen < LPos + 4 then Exit;
    LMaskKey[0] := ABuf[LPos    ];
    LMaskKey[1] := ABuf[LPos + 1];
    LMaskKey[2] := ABuf[LPos + 2];
    LMaskKey[3] := ABuf[LPos + 3];
    Inc(LPos, 4);
  end;

  if ABufLen < LPos + LPLen then Exit;

  SetLength(AFrame.Payload, LPLen);
  if LPLen > 0 then
  begin
    Move(ABuf[LPos], AFrame.Payload[0], LPLen);
    if LMasked then
      for I := 0 to LPLen - 1 do
        AFrame.Payload[I] := AFrame.Payload[I] xor LMaskKey[I and 3];
  end;

  AConsumed := LPos + Integer(LPLen);
  Result    := True;
end;

class function TWebSocketUtils.BuildFrame(AOpcode: Byte; AFin: Boolean;
  const APayload: TBytes): TBytes;
var
  LLen:    Int64;
  LHdrLen: Integer;
  LB0:     Byte;
begin
  LLen := Length(APayload);

  if LLen < 126 then
    LHdrLen := 2
  else if LLen <= $FFFF then
    LHdrLen := 4
  else
    LHdrLen := 10;

  SetLength(Result, LHdrLen + Integer(LLen));

  LB0 := AOpcode and $0F;
  if AFin then LB0 := LB0 or $80;
  Result[0] := LB0;

  if LLen < 126 then
    Result[1] := Byte(LLen)
  else if LLen <= $FFFF then
  begin
    Result[1] := 126;
    Result[2] := Byte((LLen shr 8) and $FF);
    Result[3] := Byte( LLen        and $FF);
  end
  else
  begin
    Result[1] := 127;
    Result[2] := Byte((LLen shr 56) and $FF);
    Result[3] := Byte((LLen shr 48) and $FF);
    Result[4] := Byte((LLen shr 40) and $FF);
    Result[5] := Byte((LLen shr 32) and $FF);
    Result[6] := Byte((LLen shr 24) and $FF);
    Result[7] := Byte((LLen shr 16) and $FF);
    Result[8] := Byte((LLen shr  8) and $FF);
    Result[9] := Byte( LLen         and $FF);
  end;

  if LLen > 0 then
    Move(APayload[0], Result[LHdrLen], LLen);
end;

class function TWebSocketUtils.TextFrame(const AText: string): TBytes;
begin
  Result := BuildFrame(OPCODE_TEXT, True, TEncoding.UTF8.GetBytes(AText));
end;

class function TWebSocketUtils.BinaryFrame(const AData: TBytes): TBytes;
begin
  Result := BuildFrame(OPCODE_BINARY, True, AData);
end;

class function TWebSocketUtils.CloseFrame(ACode: Word): TBytes;
var
  LBody: TBytes;
begin
  SetLength(LBody, 2);
  LBody[0] := Byte(ACode shr 8);
  LBody[1] := Byte(ACode and $FF);
  Result   := BuildFrame(OPCODE_CLOSE, True, LBody);
end;

class function TWebSocketUtils.PongFrame(const APingPayload: TBytes): TBytes;
begin
  Result := BuildFrame(OPCODE_PONG, True, APingPayload);
end;

end.
