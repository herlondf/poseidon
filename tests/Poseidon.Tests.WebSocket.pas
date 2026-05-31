unit Poseidon.Tests.WebSocket;

// DUnitX tests for TWebSocketUtils.
// These tests exercise pure protocol functions — no network I/O required.
// All assertions are based on RFC 6455 semantics and known test vectors.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TPoseidonWebSocketTests = class
  public
    // HandshakeAccept
    [Test]
    procedure HandshakeAccept_RFC6455TestVector_ReturnsExpectedBase64;

    // BuildFrame — opcode byte (first byte = opcode | $80 for FIN)
    [Test]
    procedure BuildFrame_TextOpcode_FirstByteIs81Hex;
    [Test]
    procedure BuildFrame_BinaryOpcode_FirstByteIs82Hex;
    [Test]
    procedure BuildFrame_CloseOpcode_FirstByteIs88Hex;

    // BuildFrame — length encoding
    [Test]
    procedure BuildFrame_PayloadUnder126_UsesOneByteLengthField;
    [Test]
    procedure BuildFrame_Payload126Bytes_Uses16BitLengthEncoding;

    // TextFrame / BinaryFrame / CloseFrame helpers
    [Test]
    procedure TextFrame_EncodesTextAsUTF8WithOpcodeText;
    [Test]
    procedure BinaryFrame_PreservesPayloadWithOpcodeBinary;
    [Test]
    procedure CloseFrame_Code1000_PayloadContainsBigEndianCode;

    // ParseFrame round-trip
    [Test]
    procedure ParseFrame_UnmaskedTextFrame_RoundTripMatchesOriginal;
    [Test]
    procedure ParseFrame_MaskedFrame_UnmasksPayloadCorrectly;
    [Test]
    procedure ParseFrame_InsufficientBytes_ReturnsFalse;

    // BuildFrame — 64-bit length encoding (payload >= 65536)
    [Test]
    procedure BuildFrame_Payload65536Bytes_Uses64BitLengthEncoding;

    // BuildFrame — FIN flag variations
    [Test]
    procedure BuildFrame_FinFalse_FirstByteHasNoFinBit;

    // ParseFrame — ping / pong opcodes
    [Test]
    procedure ParseFrame_PingFrame_OpcodeParsedCorrectly;
    [Test]
    procedure ParseFrame_PongFrame_OpcodeParsedCorrectly;

    // ParseFrame — 16-bit length round-trip
    [Test]
    procedure ParseFrame_16BitLength_RoundTripMatchesOriginal;

    // BuildFrame — opcode validation
    [Test]
    procedure BuildFrame_ReservedOpcode_RaisesArgumentException;
    [Test]
    procedure BuildFrame_ReservedOpcode0B_RaisesArgumentException;

    // permessage-deflate (RFC 7692)
    [Test]
    procedure DeflateUtils_CompressDecompress_RoundTrip;
    [Test]
    procedure BuildFrame_DeflateTrue_SetsRSV1Bit;
    [Test]
    procedure ParseFrame_FrameWithRSV1_RSV1IsTrue;
    [Test]
    procedure ParseFrame_FrameWithoutRSV1_RSV1IsFalse;
    [Test]
    procedure BuildHandshakeResponse_DeflateEnabled_ContainsExtensionHeader;
    [Test]
    procedure BuildHandshakeResponse_DeflateDisabled_NoExtensionHeader;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.NetEncoding,
  Poseidon.Net.WebSocket;

{ -- Assertion helpers --------------------------------------------------------
  Wrap Assert.AreEqual with an explicit typed parameter so the Delphi 11
  compiler can resolve the overload without ambiguity. }

procedure CheckInt(AExpected, AActual: Integer; const AMsg: string = '');
begin
  Assert.AreEqual(AExpected, AActual, AMsg);
end;

{ TPoseidonWebSocketTests }

procedure TPoseidonWebSocketTests.HandshakeAccept_RFC6455TestVector_ReturnsExpectedBase64;
const
  // RFC 6455 §1.3 example
  CLIENT_KEY = 'dGhlIHNhbXBsZSBub25jZQ==';
  EXPECTED   = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=';
begin
  Assert.AreEqual(EXPECTED, TWebSocketUtils.HandshakeAccept(CLIENT_KEY));
end;

procedure TPoseidonWebSocketTests.BuildFrame_TextOpcode_FirstByteIs81Hex;
var
  LFrame: TBytes;
begin
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_TEXT, True, TEncoding.UTF8.GetBytes('hi'));
  // FIN=1, Opcode=1 → $80 or $01 = $81
  CheckInt($81, LFrame[0]);
end;

procedure TPoseidonWebSocketTests.BuildFrame_BinaryOpcode_FirstByteIs82Hex;
var
  LFrame: TBytes;
begin
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, TBytes.Create(1, 2, 3));
  // FIN=1, Opcode=2 → $82
  CheckInt($82, LFrame[0]);
end;

procedure TPoseidonWebSocketTests.BuildFrame_CloseOpcode_FirstByteIs88Hex;
var
  LFrame: TBytes;
begin
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_CLOSE, True, TBytes.Create(3, 232));
  // FIN=1, Opcode=8 → $88
  CheckInt($88, LFrame[0]);
end;

procedure TPoseidonWebSocketTests.BuildFrame_PayloadUnder126_UsesOneByteLengthField;
var
  LPayload: TBytes;
  LFrame:   TBytes;
begin
  SetLength(LPayload, 10);
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, LPayload);
  // Header = 2 bytes; total = 12
  CheckInt(12, Length(LFrame));
  CheckInt(10, LFrame[1]);  // length byte = 10 (no mask bit for server frames)
end;

procedure TPoseidonWebSocketTests.BuildFrame_Payload126Bytes_Uses16BitLengthEncoding;
var
  LPayload: TBytes;
  LFrame:   TBytes;
begin
  SetLength(LPayload, 126);
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, LPayload);
  // Header = 4 bytes (byte0, byte1=126, 2-byte big-endian length)
  CheckInt(130, Length(LFrame));
  CheckInt(126, LFrame[1]);  // length indicator = 126
  CheckInt(0,   LFrame[2]);  // high byte
  CheckInt(126, LFrame[3]);  // low byte
end;

procedure TPoseidonWebSocketTests.TextFrame_EncodesTextAsUTF8WithOpcodeText;
var
  LFrame:  TBytes;
  LParsed: TWebSocketFrame;
  LConsumed: Integer;
begin
  LFrame := TWebSocketUtils.TextFrame('hello');
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  CheckInt(OPCODE_TEXT, LParsed.Opcode);
  Assert.AreEqual('hello', TEncoding.UTF8.GetString(LParsed.Payload));
end;

procedure TPoseidonWebSocketTests.BinaryFrame_PreservesPayloadWithOpcodeBinary;
var
  LInput:    TBytes;
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LInput := TBytes.Create(10, 20, 30, 40);
  LFrame := TWebSocketUtils.BinaryFrame(LInput);
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  CheckInt(OPCODE_BINARY, LParsed.Opcode);
  CheckInt(4, Length(LParsed.Payload));
  CheckInt(10, LParsed.Payload[0]);
  CheckInt(40, LParsed.Payload[3]);
end;

procedure TPoseidonWebSocketTests.CloseFrame_Code1000_PayloadContainsBigEndianCode;
var
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LFrame := TWebSocketUtils.CloseFrame(1000);
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  CheckInt(OPCODE_CLOSE, LParsed.Opcode);
  CheckInt(2, Length(LParsed.Payload));
  // 1000 = $03E8 big-endian
  CheckInt($03, LParsed.Payload[0]);
  CheckInt($E8, LParsed.Payload[1]);
end;

procedure TPoseidonWebSocketTests.ParseFrame_UnmaskedTextFrame_RoundTripMatchesOriginal;
var
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LFrame := TWebSocketUtils.TextFrame('Poseidon');
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  CheckInt(Length(LFrame), LConsumed);
  Assert.IsTrue(LParsed.FinFlag);
  CheckInt(OPCODE_TEXT, LParsed.Opcode);
  Assert.AreEqual('Poseidon', TEncoding.UTF8.GetString(LParsed.Payload));
end;

procedure TPoseidonWebSocketTests.ParseFrame_MaskedFrame_UnmasksPayloadCorrectly;
var
  // Manually built masked frame: FIN+Text, payload "Hi", mask key = [1,2,3,4]
  // "H"=$48 xor 1=$49; "i"=$69 xor 2=$6B
  LRaw:      TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LRaw := TBytes.Create(
    $81,        // FIN + OPCODE_TEXT
    $82,        // mask bit set + length 2
    1, 2, 3, 4, // mask key
    $49, $6B    // "H" xor 1, "i" xor 2
  );
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LRaw[0], Length(LRaw), LParsed, LConsumed));
  Assert.AreEqual('Hi', TEncoding.UTF8.GetString(LParsed.Payload));
  CheckInt(8, LConsumed);
end;

procedure TPoseidonWebSocketTests.ParseFrame_InsufficientBytes_ReturnsFalse;
var
  LRaw:      TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  // Only 1 byte — minimum header is 2
  LRaw := TBytes.Create($81);
  Assert.IsFalse(TWebSocketUtils.ParseFrame(@LRaw[0], Length(LRaw), LParsed, LConsumed));
  CheckInt(0, LConsumed);
end;

procedure TPoseidonWebSocketTests.BuildFrame_ReservedOpcode_RaisesArgumentException;
var
  LRaised: Boolean;
begin
  // Opcodes 0x3-0x7 and 0xB-0xF are reserved — RFC 6455 §5.2
  LRaised := False;
  try
    TWebSocketUtils.BuildFrame($03, True, nil);
  except
    on EArgumentException do LRaised := True;
  end;
  Assert.IsTrue(LRaised, 'Expected EArgumentException for reserved opcode $03');
end;

procedure TPoseidonWebSocketTests.BuildFrame_ReservedOpcode0B_RaisesArgumentException;
var
  LRaised: Boolean;
begin
  LRaised := False;
  try
    TWebSocketUtils.BuildFrame($0B, True, nil);
  except
    on EArgumentException do LRaised := True;
  end;
  Assert.IsTrue(LRaised, 'Expected EArgumentException for reserved opcode $0B');
end;

procedure TPoseidonWebSocketTests.BuildFrame_Payload65536Bytes_Uses64BitLengthEncoding;
var
  LPayload: TBytes;
  LFrame:   TBytes;
begin
  SetLength(LPayload, 65536);
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, LPayload);
  // Header = 10 bytes (byte0, byte1=127, 8-byte big-endian length)
  CheckInt(65546, Length(LFrame));
  CheckInt(127, LFrame[1]);  // 127 = 64-bit indicator
  // 8-byte big-endian for 65536 = $0000000000010000
  CheckInt(0, LFrame[2]);
  CheckInt(0, LFrame[3]);
  CheckInt(0, LFrame[4]);
  CheckInt(0, LFrame[5]);
  CheckInt(0, LFrame[6]);
  CheckInt(1, LFrame[7]);
  CheckInt(0, LFrame[8]);
  CheckInt(0, LFrame[9]);
end;

procedure TPoseidonWebSocketTests.BuildFrame_FinFalse_FirstByteHasNoFinBit;
var
  LFrame: TBytes;
begin
  // FIN=0, Opcode=0 (continuation) → first byte = $00
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_CONTINUATION, False, TEncoding.UTF8.GetBytes('frag'));
  CheckInt($00, LFrame[0]);
end;

procedure TPoseidonWebSocketTests.ParseFrame_PingFrame_OpcodeParsedCorrectly;
var
  LRaw:      TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  // FIN=1, Opcode=9 (Ping), no mask, payload "ping"
  LRaw := TBytes.Create($89, $04, $70, $69, $6E, $67);  // $89=FIN+Ping, $04=len 4, "ping"
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LRaw[0], Length(LRaw), LParsed, LConsumed));
  CheckInt(OPCODE_PING, LParsed.Opcode);
  Assert.IsTrue(LParsed.FinFlag);
  CheckInt(4, Length(LParsed.Payload));
  CheckInt(6, LConsumed);
end;

procedure TPoseidonWebSocketTests.ParseFrame_PongFrame_OpcodeParsedCorrectly;
var
  LRaw:      TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  // FIN=1, Opcode=A (Pong), no mask, no payload
  LRaw := TBytes.Create($8A, $00);  // $8A=FIN+Pong, $00=len 0
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LRaw[0], Length(LRaw), LParsed, LConsumed));
  CheckInt(OPCODE_PONG, LParsed.Opcode);
  CheckInt(0, Length(LParsed.Payload));
  CheckInt(2, LConsumed);
end;

procedure TPoseidonWebSocketTests.ParseFrame_16BitLength_RoundTripMatchesOriginal;
var
  LPayload:  TBytes;
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
  I:         Integer;
begin
  SetLength(LPayload, 200);
  for I := 0 to 199 do
    LPayload[I] := Byte(I mod 256);
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, LPayload);
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  CheckInt(Length(LFrame), LConsumed);
  CheckInt(200, Length(LParsed.Payload));
  for I := 0 to 199 do
    CheckInt(I mod 256, LParsed.Payload[I]);
end;

// =============================================================================
// permessage-deflate tests (RFC 7692)
// =============================================================================

procedure TPoseidonWebSocketTests.DeflateUtils_CompressDecompress_RoundTrip;
// Compress then decompress a string; result must match the original.
var
  LOriginal: TBytes;
  LCompressed: TBytes;
  LRestored:   TBytes;
begin
  LOriginal   := TEncoding.UTF8.GetBytes('Hello, WebSocket permessage-deflate! Repeat: Hello Hello Hello.');
  LCompressed := TWSDeflateUtils.Compress(LOriginal);
  Assert.IsTrue(Length(LCompressed) > 0,
    'Compressed output must be non-empty');
  LRestored := TWSDeflateUtils.Decompress(LCompressed);
  Assert.AreEqual(Length(LOriginal), Length(LRestored),
    'Decompressed length must equal original');
  Assert.AreEqual(TEncoding.UTF8.GetString(LOriginal),
                  TEncoding.UTF8.GetString(LRestored),
    'Decompressed content must match original');
end;

procedure TPoseidonWebSocketTests.BuildFrame_DeflateTrue_SetsRSV1Bit;
// BuildFrame with ADeflate=True must set bit 6 (RSV1) in the first byte.
var
  LPayload: TBytes;
  LFrame:   TBytes;
begin
  LPayload := TEncoding.UTF8.GetBytes('test');
  LFrame   := TWebSocketUtils.BuildFrame(OPCODE_TEXT, True, True, LPayload);
  Assert.IsTrue(Length(LFrame) >= 2, 'Frame must have at least 2 bytes');
  Assert.IsTrue((LFrame[0] and $40) <> 0,
    'RSV1 bit (bit 6 = $40) must be set in first byte of deflate frame');
  Assert.AreEqual($C1, Integer(LFrame[0]),  // $80 (FIN) or $40 (RSV1) or $01 (text) = $C1
    'First byte of deflate text frame with FIN must be $C1');
end;

procedure TPoseidonWebSocketTests.ParseFrame_FrameWithRSV1_RSV1IsTrue;
// A manually crafted frame with RSV1 bit set must have RSV1=True after ParseFrame.
var
  LRaw:      TBytes;
  LFrame:    TWebSocketFrame;
  LConsumed: Integer;
begin
  // Build a minimal frame: byte0 = $C1 (FIN|RSV1|text), byte1 = $00 (no mask, len=0)
  LRaw    := TBytes.Create($C1, $00);
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LRaw[0], Length(LRaw), LFrame, LConsumed));
  Assert.IsTrue(LFrame.RSV1,
    'ParseFrame must set RSV1=True when RSV1 bit is present in frame header');
end;

procedure TPoseidonWebSocketTests.ParseFrame_FrameWithoutRSV1_RSV1IsFalse;
// A normal frame (no RSV1) must have RSV1=False after ParseFrame.
var
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LFrame := TWebSocketUtils.TextFrame('hello');
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  Assert.IsFalse(LParsed.RSV1,
    'ParseFrame must set RSV1=False for normal (non-deflate) frame');
end;

procedure TPoseidonWebSocketTests.BuildHandshakeResponse_DeflateEnabled_ContainsExtensionHeader;
// When ADeflateEnabled=True, the 101 response must contain the extension header.
var
  LResp:    TBytes;
  LRespStr: string;
begin
  LResp    := TWebSocketUtils.BuildHandshakeResponse('dGhlIHNhbXBsZSBub25jZQ==', True);
  LRespStr := TEncoding.ASCII.GetString(LResp);
  Assert.IsTrue(Pos('Sec-WebSocket-Extensions', LRespStr) > 0,
    'Deflate-enabled handshake response must contain Sec-WebSocket-Extensions header');
  Assert.IsTrue(Pos('permessage-deflate', LRespStr) > 0,
    'Extensions header must contain permessage-deflate');
end;

procedure TPoseidonWebSocketTests.BuildHandshakeResponse_DeflateDisabled_NoExtensionHeader;
// When ADeflateEnabled=False (default), no extension header should appear.
var
  LResp:    TBytes;
  LRespStr: string;
begin
  LResp    := TWebSocketUtils.BuildHandshakeResponse('dGhlIHNhbXBsZSBub25jZQ==');
  LRespStr := TEncoding.ASCII.GetString(LResp);
  Assert.IsFalse(Pos('Sec-WebSocket-Extensions', LRespStr) > 0,
    'Default handshake response must not contain Sec-WebSocket-Extensions header');
end;

initialization
  TDUnitX.RegisterTestFixture(TPoseidonWebSocketTests);

end.
