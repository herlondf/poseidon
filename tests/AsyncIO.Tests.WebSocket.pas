unit AsyncIO.Tests.WebSocket;

// DUnitX tests for TWebSocketUtils.
// These tests exercise pure protocol functions — no network I/O required.
// All assertions are based on RFC 6455 semantics and known test vectors.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TAsyncIOWebSocketTests = class
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
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  System.NetEncoding,
  AsyncIO.Net.WebSocket;

{ TAsyncIOWebSocketTests }

procedure TAsyncIOWebSocketTests.HandshakeAccept_RFC6455TestVector_ReturnsExpectedBase64;
const
  // RFC 6455 §1.3 example
  CLIENT_KEY = 'dGhlIHNhbXBsZSBub25jZQ==';
  EXPECTED   = 's3pPLMBiTxaQ9kYGzzhZRbK+xOo=';
begin
  Assert.AreEqual(EXPECTED, TWebSocketUtils.HandshakeAccept(CLIENT_KEY));
end;

procedure TAsyncIOWebSocketTests.BuildFrame_TextOpcode_FirstByteIs81Hex;
var
  LFrame: TBytes;
begin
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_TEXT, True, TEncoding.UTF8.GetBytes('hi'));
  // FIN=1, Opcode=1 → $80 or $01 = $81
  Assert.AreEqual(Byte($81), LFrame[0]);
end;

procedure TAsyncIOWebSocketTests.BuildFrame_BinaryOpcode_FirstByteIs82Hex;
var
  LFrame: TBytes;
begin
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, TBytes.Create(1, 2, 3));
  // FIN=1, Opcode=2 → $82
  Assert.AreEqual(Byte($82), LFrame[0]);
end;

procedure TAsyncIOWebSocketTests.BuildFrame_CloseOpcode_FirstByteIs88Hex;
var
  LFrame: TBytes;
begin
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_CLOSE, True, TBytes.Create(3, 232));
  // FIN=1, Opcode=8 → $88
  Assert.AreEqual(Byte($88), LFrame[0]);
end;

procedure TAsyncIOWebSocketTests.BuildFrame_PayloadUnder126_UsesOneByteLengthField;
var
  LPayload: TBytes;
  LFrame:   TBytes;
begin
  SetLength(LPayload, 10);
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, LPayload);
  // Header = 2 bytes; total = 12
  Assert.AreEqual(12, Length(LFrame));
  Assert.AreEqual(Byte(10), LFrame[1]);  // length byte = 10 (no mask bit for server frames)
end;

procedure TAsyncIOWebSocketTests.BuildFrame_Payload126Bytes_Uses16BitLengthEncoding;
var
  LPayload: TBytes;
  LFrame:   TBytes;
begin
  SetLength(LPayload, 126);
  LFrame := TWebSocketUtils.BuildFrame(OPCODE_BINARY, True, LPayload);
  // Header = 4 bytes (byte0, byte1=126, 2-byte big-endian length)
  Assert.AreEqual(130, Length(LFrame));
  Assert.AreEqual(Byte(126), LFrame[1]);          // length indicator = 126
  Assert.AreEqual(Byte(0),   LFrame[2]);           // high byte
  Assert.AreEqual(Byte(126), LFrame[3]);           // low byte
end;

procedure TAsyncIOWebSocketTests.TextFrame_EncodesTextAsUTF8WithOpcodeText;
var
  LFrame:  TBytes;
  LParsed: TWebSocketFrame;
  LConsumed: Integer;
begin
  LFrame := TWebSocketUtils.TextFrame('hello');
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  Assert.AreEqual(OPCODE_TEXT, LParsed.Opcode);
  Assert.AreEqual('hello', TEncoding.UTF8.GetString(LParsed.Payload));
end;

procedure TAsyncIOWebSocketTests.BinaryFrame_PreservesPayloadWithOpcodeBinary;
var
  LInput:    TBytes;
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LInput := TBytes.Create(10, 20, 30, 40);
  LFrame := TWebSocketUtils.BinaryFrame(LInput);
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  Assert.AreEqual(OPCODE_BINARY, LParsed.Opcode);
  Assert.AreEqual(4, Length(LParsed.Payload));
  Assert.AreEqual(Byte(10), LParsed.Payload[0]);
  Assert.AreEqual(Byte(40), LParsed.Payload[3]);
end;

procedure TAsyncIOWebSocketTests.CloseFrame_Code1000_PayloadContainsBigEndianCode;
var
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LFrame := TWebSocketUtils.CloseFrame(1000);
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  Assert.AreEqual(OPCODE_CLOSE, LParsed.Opcode);
  Assert.AreEqual(2, Length(LParsed.Payload));
  // 1000 = $03E8 big-endian
  Assert.AreEqual(Byte($03), LParsed.Payload[0]);
  Assert.AreEqual(Byte($E8), LParsed.Payload[1]);
end;

procedure TAsyncIOWebSocketTests.ParseFrame_UnmaskedTextFrame_RoundTripMatchesOriginal;
var
  LFrame:    TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  LFrame := TWebSocketUtils.TextFrame('AsyncIO');
  Assert.IsTrue(TWebSocketUtils.ParseFrame(@LFrame[0], Length(LFrame), LParsed, LConsumed));
  Assert.AreEqual(Length(LFrame), LConsumed);
  Assert.IsTrue(LParsed.FinFlag);
  Assert.AreEqual(OPCODE_TEXT, LParsed.Opcode);
  Assert.AreEqual('AsyncIO', TEncoding.UTF8.GetString(LParsed.Payload));
end;

procedure TAsyncIOWebSocketTests.ParseFrame_MaskedFrame_UnmasksPayloadCorrectly;
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
  Assert.AreEqual(8, LConsumed);
end;

procedure TAsyncIOWebSocketTests.ParseFrame_InsufficientBytes_ReturnsFalse;
var
  LRaw:      TBytes;
  LParsed:   TWebSocketFrame;
  LConsumed: Integer;
begin
  // Only 1 byte — minimum header is 2
  LRaw := TBytes.Create($81);
  Assert.IsFalse(TWebSocketUtils.ParseFrame(@LRaw[0], Length(LRaw), LParsed, LConsumed));
  Assert.AreEqual(0, LConsumed);
end;

end.
