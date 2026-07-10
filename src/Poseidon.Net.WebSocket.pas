unit Poseidon.Net.WebSocket;

// WebSocket (RFC 6455) protocol utilities for the Poseidon Native provider.
// This unit provides the protocol-level building blocks:
//   - HandshakeAccept: derives the Sec-WebSocket-Accept response value
//   - ParseFrame:      decodes a single inbound frame from a byte buffer
//   - BuildFrame:      encodes a frame for outbound transmission
//   - BuildHandshakeResponse: 101 Switching Protocols response bytes
//
// Integration: the application code (provider/middleware) detects the
// `Upgrade: websocket` header in the HTTP request, sends the handshake
// response via TPoseidonNativeServer raw send hooks, and from that point on
// drives ParseFrame/BuildFrame on the raw socket bytes.

interface

uses
  System.SysUtils,
  System.SyncObjs;

const
  OPCODE_CONTINUATION = $0;
  OPCODE_TEXT = $1;
  OPCODE_BINARY = $2;
  OPCODE_CLOSE = $8;
  OPCODE_PING = $9;
  OPCODE_PONG = $A;

  WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

  // Maximum accepted WebSocket payload (128 MB). Frames exceeding this are
  // rejected to prevent OOM from malicious 64-bit length values.
  CMaxWSPayloadSize = 128 * 1024 * 1024;

  // Ceiling for decompressed permessage-deflate output (16 MB). A malicious
  // peer can inflate a tiny compressed frame into gigabytes ("deflate bomb").
  // TryDecompress aborts as soon as the running output size exceeds this.
  CMaxDecompressedFrame = 16 * 1024 * 1024;

type
  TWebSocketFrame = record
    FinFlag: Boolean;
    RSV1: Boolean;   // permessage-deflate: True when payload is compressed
    RSV2: Boolean;   // RFC 6455 §5.2 — must be 0 (no negotiated extension uses it)
    RSV3: Boolean;   // RFC 6455 §5.2 — must be 0
    Masked: Boolean; // RFC 6455 §5.3 — client→server frames MUST have MASK=1
    Opcode: Byte;
    Payload: TBytes;
  end;

  // Codec for WebSocket permessage-deflate (RFC 7692).
  // Uses raw DEFLATE (windowBits = -15, no zlib/gzip header or checksum).
  // Compress strips the trailing 00 00 FF FF sync-flush marker.
  // Decompress appends it back before inflating.
  TWSDeflateUtils = class
  public
    class function Compress(const AData: TBytes): TBytes; static;
    // Legacy API — inflates without ceiling. Retained for callers that
    // enforce their own bounds. Raises on stream error.
    class function Decompress(const AData: TBytes): TBytes; static;
    // Bounded inflate — checks the running output size on EVERY iteration
    // against CMaxDecompressedFrame. Returns False and clears AOutput when
    // the ceiling is exceeded or the stream is malformed. Callers MUST
    // treat False as a fatal protocol error and close with 1009.
    class function TryDecompress(const AData: TBytes;
      out AOutput: TBytes): Boolean; static;
  end;

  TWebSocketUtils = class
  strict private
    // Zero-copy frame builder kernel.
    // Extends APayload at the front (shifts data right),
    // then writes the RFC 6455 frame header in place — no second allocation.
    class procedure _PrependHeader(AOpcode: Byte; AFin: Boolean;
      var APayload: TBytes); static;
  public
    // Compute Sec-WebSocket-Accept = base64(SHA1(ClientKey + WS_GUID))
    class function HandshakeAccept(const AClientKey: string): string; static;

    // Build the full HTTP/1.1 101 Switching Protocols response bytes.
    // When ADeflateEnabled=True, includes the permessage-deflate extension
    // negotiation with no-context-takeover on both sides (stateless compression).
    class function BuildHandshakeResponse(const AClientKey: string;
      ADeflateEnabled: Boolean = False): TBytes; static;

    // Decode one frame from ABuf starting at index 0.
    // Returns True if a complete frame was decoded; AConsumed indicates how
    // many bytes to discard from ABuf afterwards. False (AConsumed=0) means
    // more bytes are needed.
    class function ParseFrame(const ABuf: PByte; ABufLen: Integer;
      out AFrame: TWebSocketFrame; out AConsumed: Integer): Boolean; static;

    // Apply permessage-deflate inflate to a received frame (RFC 7692 §7.2.2).
    // If AFrame.RSV1 = True and the payload is non-empty, decompresses
    // AFrame.Payload in place and clears AFrame.RSV1.
    // No-op when RSV1 = False (uncompressed frame).
    // Legacy API — no size ceiling. Use TryApplyRXDeflate on hot paths.
    class procedure ApplyRXDeflate(var AFrame: TWebSocketFrame); static;

    // Bounded variant of ApplyRXDeflate — enforces CMaxDecompressedFrame.
    // Returns False when the inflated payload would exceed the ceiling or
    // the stream is malformed; caller MUST close the connection with 1009.
    // On True, AFrame.Payload is replaced with the inflated content and
    // AFrame.RSV1 is cleared. No-op when RSV1 = False (returns True).
    class function TryApplyRXDeflate(var AFrame: TWebSocketFrame): Boolean; static;

    // Encode an outbound frame. Server frames are never masked (per RFC 6455).
    class function BuildFrame(AOpcode: Byte; AFin: Boolean;
      const APayload: TBytes): TBytes; overload; static;
    // Deflate variant: sets RSV1 in the first byte (permessage-deflate compressed frame).
    class function BuildFrame(AOpcode: Byte; AFin: Boolean; ADeflate: Boolean;
      const APayload: TBytes): TBytes; overload; static;

    // Convenience helpers
    class function TextFrame(const AText: string): TBytes; static;
    class function BinaryFrame(const AData: TBytes): TBytes; static;
    class function CloseFrame(ACode: Word = 1000): TBytes; static;
    class function PongFrame(const APingPayload: TBytes): TBytes; static;
  end;

  TWSRawSendProc = reference to procedure(const AData: TBytes);
  TWSCloseProc = reference to procedure;

  IPoseidonWSConn = interface
    ['{B2C3D4E5-F607-8901-BCDE-F01234567891}']
    procedure Send(const AText: string);
    procedure SendBinary(const AData: TBytes);
    procedure Close(ACode: Word = 1000);
    function GetRemoteAddr: string;
    function GetClosed: Boolean;
    function GetDeflateEnabled: Boolean;
    property RemoteAddr: string read GetRemoteAddr;
    property Closed: Boolean read GetClosed;
    property DeflateEnabled: Boolean read GetDeflateEnabled;
  end;

  TWSMessageCallback = reference to procedure(AConn: IPoseidonWSConn; const AFrame: TWebSocketFrame);
  TWSCloseCallback   = reference to procedure(AConn: IPoseidonWSConn);

  TPoseidonWSConn = class(TInterfacedObject, IPoseidonWSConn)
  private
    FRemoteAddr: string;
    FSend: TWSRawSendProc;
    FCloseConn: TWSCloseProc;
    FClosed: Boolean;
    FDeflateEnabled: Boolean;
    FLock: TCriticalSection;
  public
    constructor Create(const ARemoteAddr: string; const ASend: TWSRawSendProc;
      const AClose: TWSCloseProc; ADeflateEnabled: Boolean = False);
    destructor Destroy; override;
    procedure Invalidate;
    procedure Send(const AText: string);
    procedure SendBinary(const AData: TBytes);
    procedure Close(ACode: Word = 1000);
    function GetRemoteAddr: string;
    function GetClosed: Boolean;
    function GetDeflateEnabled: Boolean;
  end;

implementation

uses
  System.Classes,
  System.NetEncoding,
  System.Hash,
  System.ZLib;

{ TPoseidonWSConn }

constructor TPoseidonWSConn.Create(const ARemoteAddr: string;
  const ASend: TWSRawSendProc; const AClose: TWSCloseProc;
  ADeflateEnabled: Boolean);
begin
  inherited Create;
  FRemoteAddr := ARemoteAddr;
  FSend := ASend;
  FCloseConn := AClose;
  FClosed := False;
  FDeflateEnabled := ADeflateEnabled;
  FLock := TCriticalSection.Create;
end;

destructor TPoseidonWSConn.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TPoseidonWSConn.Invalidate;
begin
  FLock.Enter;
  try
    FClosed := True;
    FSend := nil;
    FCloseConn := nil;
  finally
    FLock.Leave;
  end;
end;

procedure TPoseidonWSConn.Send(const AText: string);
var
  LRaw: TBytes;
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
  if FDeflateEnabled then
  begin
    LRaw := TEncoding.UTF8.GetBytes(AText);
    LData := TWebSocketUtils.BuildFrame(OPCODE_TEXT, True, True,
               TWSDeflateUtils.Compress(LRaw));
  end
  else
    LData := TWebSocketUtils.TextFrame(AText);
  LSend(LData);
end;

procedure TPoseidonWSConn.SendBinary(const AData: TBytes);
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
  if FDeflateEnabled then
    LData := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, True,
               TWSDeflateUtils.Compress(AData))
  else
    LData := TWebSocketUtils.BinaryFrame(AData);
  LSend(LData);
end;

procedure TPoseidonWSConn.Close(ACode: Word);
var
  LData: TBytes;
  LSend: TWSRawSendProc;
  LClose: TWSCloseProc;
begin
  FLock.Enter;
  try
    if FClosed then Exit;
    FClosed := True;
    LSend := FSend;
    LClose := FCloseConn;
    FSend := nil;
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

function TPoseidonWSConn.GetRemoteAddr: string;
begin
  Result := FRemoteAddr;
end;

function TPoseidonWSConn.GetClosed: Boolean;
begin
  FLock.Enter;
  try
    Result := FClosed;
  finally
    FLock.Leave;
  end;
end;

function TPoseidonWSConn.GetDeflateEnabled: Boolean;
begin
  Result := FDeflateEnabled;
end;

// ===========================================================================
// TWSDeflateUtils — raw DEFLATE codec (RFC 7692 §7.2)
// ===========================================================================

class function TWSDeflateUtils.Compress(const AData: TBytes): TBytes;
// Uses the raw zlib deflate API with Z_SYNC_FLUSH so that the output ends with
// the 00 00 FF FF sync-flush marker required by RFC 7692 §7.2.1.
// TZCompressionStream uses Z_FINISH on destruction, which does NOT produce
// the sync-flush marker, so we bypass the stream wrapper here.
const
  CHUNK = 32768;
var
  LStrm: z_stream;
  LOut:  TBytesStream;
  LBuf:  array[0..CHUNK - 1] of Byte;
  LRet:  Integer;
  LLen:  Integer;
  LSize: Integer;
begin
  SetLength(Result, 0);
  if Length(AData) = 0 then Exit;

  FillChar(LStrm, SizeOf(LStrm), 0);
  // windowBits = -15: raw DEFLATE (no zlib/gzip wrapper)
  if deflateInit2(LStrm, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
       Z_DEFAULT_STRATEGY) <> Z_OK then
    raise Exception.Create('WSDeflate: deflateInit2 failed');

  LOut := TBytesStream.Create;
  try
    try
      LStrm.next_in  := @AData[0];
      LStrm.avail_in := Length(AData);
      // Z_SYNC_FLUSH: flushes all pending output and appends 00 00 FF FF
      repeat
        LStrm.next_out  := @LBuf[0];
        LStrm.avail_out := CHUNK;
        LRet := deflate(LStrm, Z_SYNC_FLUSH);
        if LRet < Z_OK then
          raise Exception.CreateFmt('WSDeflate: deflate error %d', [LRet]);
        LLen := CHUNK - LStrm.avail_out;
        if LLen > 0 then
          LOut.Write(LBuf[0], LLen);
      until LStrm.avail_out > 0;  // avail_out > 0 means no more pending output
    finally
      deflateEnd(LStrm);
    end;

    // Strip trailing 00 00 FF FF (4 bytes) per RFC 7692 §7.2.1
    LSize := LOut.Size;
    if LSize >= 4 then
      Dec(LSize, 4);
    SetLength(Result, LSize);
    if LSize > 0 then
      Move(LOut.Bytes[0], Result[0], LSize);
  finally
    LOut.Free;
  end;
end;

class function TWSDeflateUtils.TryDecompress(const AData: TBytes;
  out AOutput: TBytes): Boolean;
const
  // Sync-flush marker that was stripped before sending (RFC 7692 §7.2.2)
  SYNC_FLUSH: array[0..3] of Byte = ($00, $00, $FF, $FF);
  CInflateChunk = 32768;
var
  LIn: TBytesStream;
  LData: TBytes;
  LOut: TBytesStream;
  LZ: TZDecompressionStream;
  LBuf: TBytes;
  LRead: Integer;
  LOK: Boolean;
begin
  SetLength(AOutput, 0);
  Result := True;
  if Length(AData) = 0 then Exit;
  // Reconstruct the sync-flush tail before inflating
  SetLength(LData, Length(AData) + 4);
  Move(AData[0], LData[0], Length(AData));
  Move(SYNC_FLUSH[0], LData[Length(AData)], 4);
  LIn  := TBytesStream.Create(LData);
  LOut := TBytesStream.Create;
  SetLength(LBuf, CInflateChunk);
  LOK := True;
  try
    // WindowBits = -15: raw INFLATE. Errors bubble as exceptions from
    // TZDecompressionStream; catch them and convert to Result=False so
    // the caller (Manager) can close with 1009 without a silent swallow.
    try
      LZ := TZDecompressionStream.Create(LIn, -15);
      try
        // Read in a loop until EOF — do NOT pass 0 to CopyFrom because that
        // uses LZ.Size (= compressed size) as the byte count, which stops
        // short of the full decompressed output.
        repeat
          LRead := LZ.Read(LBuf[0], Length(LBuf));
          if LRead > 0 then
          begin
            LOut.Write(LBuf[0], LRead);
            // Enforce the ceiling on EVERY iteration — a bomb inflates
            // fast, we must abort before allocating the whole payload.
            if LOut.Size > CMaxDecompressedFrame then
            begin
              LOK := False;
              Break;
            end;
          end;
        until LRead = 0;
      finally
        LZ.Free;
      end;
    except
      // Malformed DEFLATE stream — convert to explicit failure result so
      // the caller can close with 1009. NOT a silent swallow: Result=False
      // is a hard signal upstream.
      on Exception do
        LOK := False;
    end;
    if not LOK then
    begin
      SetLength(AOutput, 0);
      Exit(False);
    end;
    SetLength(AOutput, LOut.Size);
    if LOut.Size > 0 then
      Move(LOut.Bytes[0], AOutput[0], LOut.Size);
  finally
    LIn.Free;
    LOut.Free;
  end;
end;

class function TWSDeflateUtils.Decompress(const AData: TBytes): TBytes;
begin
  // Legacy path — delegates to bounded variant. On failure raises so
  // existing callers that do not check status still notice the error.
  if not TryDecompress(AData, Result) then
    raise Exception.Create('WSDeflate: decompression failed or exceeded ceiling');
end;

class procedure TWebSocketUtils.ApplyRXDeflate(var AFrame: TWebSocketFrame);
begin
  if not AFrame.RSV1 then Exit;
  if Length(AFrame.Payload) > 0 then
    AFrame.Payload := TWSDeflateUtils.Decompress(AFrame.Payload);
  AFrame.RSV1 := False;
end;

class function TWebSocketUtils.TryApplyRXDeflate(
  var AFrame: TWebSocketFrame): Boolean;
var
  LInflated: TBytes;
begin
  if not AFrame.RSV1 then Exit(True);
  if Length(AFrame.Payload) = 0 then
  begin
    AFrame.RSV1 := False;
    Exit(True);
  end;
  if not TWSDeflateUtils.TryDecompress(AFrame.Payload, LInflated) then
    Exit(False);
  AFrame.Payload := LInflated;
  AFrame.RSV1 := False;
  Result := True;
end;

class function TWebSocketUtils.HandshakeAccept(const AClientKey: string): string;
var
  LSrc: string;
  LHash: TBytes;
begin
  LSrc := AClientKey + WS_GUID;
  LHash := THashSHA1.GetHashBytes(LSrc);
  Result := TNetEncoding.Base64.EncodeBytesToString(LHash);
end;

class function TWebSocketUtils.BuildHandshakeResponse(const AClientKey: string;
  ADeflateEnabled: Boolean): TBytes;
const
  CRLF = #13#10;
var
  LHdr: string;
begin
  LHdr := 'HTTP/1.1 101 Switching Protocols' + CRLF
        + 'Upgrade: websocket'                + CRLF
        + 'Connection: Upgrade'               + CRLF
        + 'Sec-WebSocket-Accept: ' + HandshakeAccept(AClientKey) + CRLF;
  if ADeflateEnabled then
    // Negotiate stateless compression: no context shared across messages
    LHdr := LHdr + 'Sec-WebSocket-Extensions: permessage-deflate; '
          + 'client_no_context_takeover; server_no_context_takeover' + CRLF;
  LHdr := LHdr + CRLF;
  Result := TEncoding.ASCII.GetBytes(LHdr);
end;

class function TWebSocketUtils.ParseFrame(const ABuf: PByte; ABufLen: Integer;
  out AFrame: TWebSocketFrame; out AConsumed: Integer): Boolean;
var
  LPos: Integer;
  LMasked: Boolean;
  LPLen: Int64;
  LPayloadLen: Byte;
  LMaskKey: array[0..3] of Byte;
  I: Integer;
begin
  Result := False;
  AConsumed := 0;
  AFrame.FinFlag := False;
  AFrame.Masked := False;
  AFrame.Opcode := 0;
  SetLength(AFrame.Payload, 0);

  if ABufLen < 2 then Exit;

  AFrame.FinFlag := (ABuf[0] and $80) <> 0;
  AFrame.RSV1 := (ABuf[0] and $40) <> 0;  // permessage-deflate compressed
  AFrame.RSV2 := (ABuf[0] and $20) <> 0;
  AFrame.RSV3 := (ABuf[0] and $10) <> 0;
  AFrame.Opcode := ABuf[0] and $0F;
  LMasked := (ABuf[1] and $80) <> 0;
  AFrame.Masked := LMasked;
  LPayloadLen := ABuf[1] and $7F;
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

  // RFC 6455 §5.2 — MSB of 64-bit payload length must be 0
  if LPLen < 0 then Exit;

  // Reject oversized payloads to prevent OOM from near-MaxInt64 values
  // that would overflow the LPos + LPLen bounds check below.
  if LPLen > CMaxWSPayloadSize then Exit;

  if LMasked then
  begin
    if ABufLen < LPos + 4 then Exit;
    LMaskKey[0] := ABuf[LPos];
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
  Result := True;
end;

class procedure TWebSocketUtils._PrependHeader(AOpcode: Byte; AFin: Boolean;
  var APayload: TBytes);
var
  LLen: Int64;
  LHdrLen: Integer;
  LB0: Byte;
begin
  LLen := Length(APayload);

  if LLen < 126 then
    LHdrLen := 2
  else if LLen <= $FFFF then
    LHdrLen := 4
  else
    LHdrLen := 10;

  // Extend the existing buffer and shift payload right — no second allocation.
  SetLength(APayload, LHdrLen + LLen);
  if LLen > 0 then
    Move(APayload[0], APayload[LHdrLen], LLen);

  LB0 := AOpcode and $0F;
  if AFin then LB0 := LB0 or $80;
  APayload[0] := LB0;

  if LLen < 126 then
    APayload[1] := Byte(LLen)
  else if LLen <= $FFFF then
  begin
    APayload[1] := 126;
    APayload[2] := Byte((LLen shr 8) and $FF);
    APayload[3] := Byte( LLen        and $FF);
  end
  else
  begin
    APayload[1] := 127;
    APayload[2] := Byte((LLen shr 56) and $FF);
    APayload[3] := Byte((LLen shr 48) and $FF);
    APayload[4] := Byte((LLen shr 40) and $FF);
    APayload[5] := Byte((LLen shr 32) and $FF);
    APayload[6] := Byte((LLen shr 24) and $FF);
    APayload[7] := Byte((LLen shr 16) and $FF);
    APayload[8] := Byte((LLen shr  8) and $FF);
    APayload[9] := Byte( LLen         and $FF);
  end;
end;

class function TWebSocketUtils.BuildFrame(AOpcode: Byte; AFin: Boolean;
  const APayload: TBytes): TBytes;
var
  LLen: Int64;
  LHdrLen: Integer;
  LB0: Byte;
begin
  LLen := Length(APayload);

  // RFC 6455 §5.2 — opcodes 0x3-0x7 and 0xB-0xF are reserved
  if (AOpcode > $0A) or ((AOpcode > $02) and (AOpcode < $08)) then
    raise EArgumentException.Create(
      'Invalid WebSocket opcode: 0x' + IntToHex(AOpcode, 2));

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

class function TWebSocketUtils.BuildFrame(AOpcode: Byte; AFin: Boolean;
  ADeflate: Boolean; const APayload: TBytes): TBytes;
var
  LLen: Int64;
  LHdrLen: Integer;
  LB0: Byte;
begin
  if not ADeflate then
  begin
    Result := BuildFrame(AOpcode, AFin, APayload);
    Exit;
  end;

  LLen := Length(APayload);

  if LLen < 126 then
    LHdrLen := 2
  else if LLen <= $FFFF then
    LHdrLen := 4
  else
    LHdrLen := 10;

  SetLength(Result, LHdrLen + Integer(LLen));

  LB0 := AOpcode and $0F;
  if AFin     then LB0 := LB0 or $80;  // FIN bit
  LB0 := LB0 or $40;                   // RSV1 = permessage-deflate
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
  Result := TEncoding.UTF8.GetBytes(AText);
  _PrependHeader(OPCODE_TEXT, True, Result);
end;

class function TWebSocketUtils.BinaryFrame(const AData: TBytes): TBytes;
begin
  Result := BuildFrame(OPCODE_BINARY, True, AData);
end;

class function TWebSocketUtils.CloseFrame(ACode: Word): TBytes;
begin
  SetLength(Result, 2);
  Result[0] := Byte(ACode shr 8);
  Result[1] := Byte(ACode and $FF);
  _PrependHeader(OPCODE_CLOSE, True, Result);
end;

class function TWebSocketUtils.PongFrame(const APingPayload: TBytes): TBytes;
begin
  Result := BuildFrame(OPCODE_PONG, True, APingPayload);
end;

end.
