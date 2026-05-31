unit Poseidon.Tests.ProxyProtocol;

// DUnitX unit tests for Poseidon.Net.ProxyProtocol.
// All functions operate on raw byte arrays — no network I/O required.
//
// Coverage: TryParseProxyProtocolV1, TryParseProxyProtocolV2,
//           TryParseProxyProtocolAuto across all branches.

interface

uses
  DUnitX.TestFramework;

type
  {$M+}
  [TestFixture]
  TProxyProtocolV2Tests = class
  private
    function BuildV2Header(ACmd: Byte; AFamily: Byte;
      const ASrcIP, ADstIP: array of Byte;
      ASrcPort, ADstPort: Word): TBytes;
  public
    [Test] procedure V2_IPv4_ProxyCmd_ParsesAddrAndPort;
    [Test] procedure V2_IPv6_ProxyCmd_ParsesAddrAndPort;
    [Test] procedure V2_LocalCmd_ConsumesHeaderNoAddr;
    [Test] procedure V2_TooShort_Incomplete;
    [Test] procedure V2_SignatureMismatch_ReturnsFalseNotIncomplete;
    [Test] procedure V2_InvalidVersion_Invalid;
    [Test] procedure V2_IncompleteAddrBlock_Incomplete;
    [Test] procedure V2_AF_UNSPEC_ConsumesHeader;
  end;

  [TestFixture]
  TProxyProtocolV1Tests = class
  private
    function MakeV1(const ALine: string): TBytes;
  public
    [Test] procedure V1_TCP4_ParsesAddrAndPort;
    [Test] procedure V1_TCP6_ParsesAddrAndPort;
    [Test] procedure V1_UNKNOWN_ConsumesHeader;
    [Test] procedure V1_NoCRLF_Short_Incomplete;
    [Test] procedure V1_NoCRLF_TooLong_Invalid;
    [Test] procedure V1_TooFewParts_Invalid;
    [Test] procedure V1_NoSignature_ReturnsFalse;
    [Test] procedure V1_TruncatedSignature_Incomplete;
    [Test] procedure V1_ConsumedBytesIncludesCRLF;
  end;

  [TestFixture]
  TProxyProtocolAutoTests = class
  public
    [Test] procedure Auto_V2Signature_ParsesAsV2;
    [Test] procedure Auto_V1Signature_ParsesAsV1;
    [Test] procedure Auto_NoSignature_SetsNoSignatureFlag;
    [Test] procedure Auto_Incomplete_SetsIncompleteFlag;
    [Test] procedure ModeV1_V2Data_ReturnsFalse;
    [Test] procedure ModeV2_V1Data_ReturnsFalse;
    [Test] procedure ModeDisabled_SetsNoSignature;
  end;
  {$M-}

implementation

uses
  System.SysUtils,
  Poseidon.Net.ProxyProtocol;

// ---------------------------------------------------------------------------
// V2 builder helper
// ---------------------------------------------------------------------------

function TProxyProtocolV2Tests.BuildV2Header(ACmd: Byte; AFamily: Byte;
  const ASrcIP, ADstIP: array of Byte;
  ASrcPort, ADstPort: Word): TBytes;
const
  SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
var
  LAddrLen: Integer;
  LPos:     Integer;
begin
  // For AF_INET: src_addr(4) + dst_addr(4) + src_port(2) + dst_port(2) = 12
  // For AF_INET6: src_addr(16) + dst_addr(16) + src_port(2) + dst_port(2) = 36
  LAddrLen := Length(ASrcIP) + Length(ADstIP) + 4;
  SetLength(Result, 16 + LAddrLen);
  Move(SIG[0], Result[0], 12);
  Result[12] := ($02 shl 4) or ACmd;  // version=2, cmd
  Result[13] := AFamily;               // family/protocol
  Result[14] := Byte(LAddrLen shr 8);
  Result[15] := Byte(LAddrLen);
  LPos := 16;
  Move(ASrcIP[0], Result[LPos], Length(ASrcIP)); Inc(LPos, Length(ASrcIP));
  Move(ADstIP[0], Result[LPos], Length(ADstIP)); Inc(LPos, Length(ADstIP));
  Result[LPos]     := Byte(ASrcPort shr 8);
  Result[LPos + 1] := Byte(ASrcPort);
  Result[LPos + 2] := Byte(ADstPort shr 8);
  Result[LPos + 3] := Byte(ADstPort);
end;

// ---------------------------------------------------------------------------
// V2 tests
// ---------------------------------------------------------------------------

procedure TProxyProtocolV2Tests.V2_IPv4_ProxyCmd_ParsesAddrAndPort;
var
  LBuf:       TBytes;
  LAddr:      string;
  LPort:      Word;
  LConsumed:  Integer;
  LIncomp, LInvalid: Boolean;
begin
  // src=192.168.1.5:12345, dst=10.0.0.1:80, AF_INET (family=$11, PROXY cmd=$01)
  LBuf := BuildV2Header($01, $11,
    [192, 168, 1, 5], [10, 0, 0, 1], 12345, 80);

  Assert.IsTrue(TryParseProxyProtocolV2(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  Assert.AreEqual('192.168.1.5', LAddr);
  Assert.AreEqual(Word(12345), LPort);
  Assert.AreEqual(Length(LBuf), LConsumed);
  Assert.IsFalse(LIncomp);
  Assert.IsFalse(LInvalid);
end;

procedure TProxyProtocolV2Tests.V2_IPv6_ProxyCmd_ParsesAddrAndPort;
var
  LBuf:       TBytes;
  LAddr:      string;
  LPort:      Word;
  LConsumed:  Integer;
  LIncomp, LInvalid: Boolean;
  LSrcIP, LDstIP: array[0..15] of Byte;
  I: Integer;
begin
  // Build IPv6 src = 2001:db8::1, dst = ::1, AF_INET6 ($21)
  FillChar(LSrcIP, 16, 0);
  LSrcIP[0]  := $20; LSrcIP[1]  := $01;
  LSrcIP[2]  := $0D; LSrcIP[3]  := $B8;
  LSrcIP[15] := $01;
  FillChar(LDstIP, 16, 0);
  LDstIP[15] := $01;
  LBuf := BuildV2Header($01, $21, LSrcIP, LDstIP, 443, 8080);

  Assert.IsTrue(TryParseProxyProtocolV2(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  Assert.AreEqual(Word(443), LPort);
  Assert.IsFalse(LInvalid);
end;

procedure TProxyProtocolV2Tests.V2_LocalCmd_ConsumesHeaderNoAddr;
var
  LBuf:      array[0..15] of Byte;
  LAddr:     string;
  LPort:     Word;
  LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
const
  SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
begin
  Move(SIG[0], LBuf[0], 12);
  LBuf[12] := $20;  // version=2, cmd=LOCAL
  LBuf[13] := $00;  // unspec
  LBuf[14] := $00;
  LBuf[15] := $00;  // addr_len = 0

  Assert.IsTrue(TryParseProxyProtocolV2(@LBuf[0], 16,
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  Assert.AreEqual(16, LConsumed);
  Assert.AreEqual('', LAddr);
end;

procedure TProxyProtocolV2Tests.V2_TooShort_Incomplete;
var
  LBuf: array[0..5] of Byte;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
begin
  FillChar(LBuf, 6, 0);
  TryParseProxyProtocolV2(@LBuf[0], 6,
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsTrue(LIncomp);
  Assert.IsFalse(LInvalid);
end;

procedure TProxyProtocolV2Tests.V2_SignatureMismatch_ReturnsFalseNotIncomplete;
var
  LBuf: array[0..15] of Byte;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
  LResult: Boolean;
begin
  FillChar(LBuf, 16, $FF);  // no valid signature
  LResult := TryParseProxyProtocolV2(@LBuf[0], 16,
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsFalse(LResult);
  Assert.IsFalse(LIncomp);
  Assert.IsFalse(LInvalid);
end;

procedure TProxyProtocolV2Tests.V2_InvalidVersion_Invalid;
var
  LBuf: TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
const
  SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
begin
  SetLength(LBuf, 16);
  Move(SIG[0], LBuf[0], 12);
  LBuf[12] := $31;  // version=3 (invalid), cmd=LOCAL
  LBuf[13] := $00;
  LBuf[14] := $00;
  LBuf[15] := $00;

  TryParseProxyProtocolV2(@LBuf[0], 16,
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsTrue(LInvalid);
end;

procedure TProxyProtocolV2Tests.V2_IncompleteAddrBlock_Incomplete;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
const
  SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
begin
  // Header says addr_len=12 (AF_INET) but buffer only contains 16 bytes
  SetLength(LBuf, 16);
  Move(SIG[0], LBuf[0], 12);
  LBuf[12] := $21;  // version=2, PROXY
  LBuf[13] := $11;  // AF_INET
  LBuf[14] := $00;
  LBuf[15] := $0C;  // addr_len = 12 — needs 28 bytes total

  TryParseProxyProtocolV2(@LBuf[0], 16,
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsTrue(LIncomp);
  Assert.IsFalse(LInvalid);
end;

procedure TProxyProtocolV2Tests.V2_AF_UNSPEC_ConsumesHeader;
var
  LBuf: TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
const
  SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
begin
  SetLength(LBuf, 16);
  Move(SIG[0], LBuf[0], 12);
  LBuf[12] := $21;  // version=2, PROXY
  LBuf[13] := $00;  // AF_UNSPEC
  LBuf[14] := $00;
  LBuf[15] := $00;  // addr_len = 0

  Assert.IsTrue(TryParseProxyProtocolV2(@LBuf[0], 16,
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  Assert.AreEqual(16, LConsumed);
end;

// ---------------------------------------------------------------------------
// V1 builder + tests
// ---------------------------------------------------------------------------

function TProxyProtocolV1Tests.MakeV1(const ALine: string): TBytes;
var
  LFull: string;
begin
  LFull  := ALine + #13#10;
  Result := TEncoding.ASCII.GetBytes(LFull);
end;

procedure TProxyProtocolV1Tests.V1_TCP4_ParsesAddrAndPort;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
begin
  LBuf := MakeV1('PROXY TCP4 192.168.1.5 10.0.0.1 12345 80');
  Assert.IsTrue(TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  Assert.AreEqual('192.168.1.5', LAddr);
  Assert.AreEqual(Word(12345), LPort);
  Assert.AreEqual(Length(LBuf), LConsumed);
end;

procedure TProxyProtocolV1Tests.V1_TCP6_ParsesAddrAndPort;
var
  LBuf:  TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
begin
  LBuf := MakeV1('PROXY TCP6 2001:db8::1 ::1 443 8080');
  Assert.IsTrue(TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  Assert.AreEqual('2001:db8::1', LAddr);
  Assert.AreEqual(Word(443), LPort);
end;

procedure TProxyProtocolV1Tests.V1_UNKNOWN_ConsumesHeader;
var
  LBuf:  TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
begin
  LBuf := MakeV1('PROXY UNKNOWN');
  Assert.IsTrue(TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  Assert.AreEqual('', LAddr);
  Assert.AreEqual(Length(LBuf), LConsumed);
end;

procedure TProxyProtocolV1Tests.V1_NoCRLF_Short_Incomplete;
var
  LBuf:  TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
begin
  LBuf := TEncoding.ASCII.GetBytes('PROXY TCP4 1.2.3.4 5.6.7.8 100 80');
  TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsTrue(LIncomp);
  Assert.IsFalse(LInvalid);
end;

procedure TProxyProtocolV1Tests.V1_NoCRLF_TooLong_Invalid;
var
  LBuf:  TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
  LLine: string;
begin
  // >108 bytes without CRLF
  LLine := 'PROXY TCP4 ' + StringOfChar('1', 60) + ' 2.2.2.2 80 80';
  LBuf  := TEncoding.ASCII.GetBytes(LLine);  // > 108 bytes, no CRLF
  TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsTrue(LInvalid);
end;

procedure TProxyProtocolV1Tests.V1_TooFewParts_Invalid;
var
  LBuf:  TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
begin
  LBuf := MakeV1('PROXY TCP4 1.2.3.4');  // only 3 parts, needs 6
  TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsTrue(LInvalid);
end;

procedure TProxyProtocolV1Tests.V1_NoSignature_ReturnsFalse;
var
  LBuf:   TBytes;
  LAddr:  string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
  LResult: Boolean;
begin
  LBuf    := TEncoding.ASCII.GetBytes('GET / HTTP/1.1'#13#10#13#10);
  LResult := TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsFalse(LResult);
  Assert.IsFalse(LIncomp);
  Assert.IsFalse(LInvalid);
end;

procedure TProxyProtocolV1Tests.V1_TruncatedSignature_Incomplete;
var
  LBuf:  TBytes;
  LAddr: string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
begin
  LBuf := TEncoding.ASCII.GetBytes('PROX');  // only 4 bytes, need 6
  TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid);
  Assert.IsTrue(LIncomp);
end;

procedure TProxyProtocolV1Tests.V1_ConsumedBytesIncludesCRLF;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid: Boolean;
  LLine:     string;
begin
  LLine  := 'PROXY TCP4 1.2.3.4 5.6.7.8 100 80';
  LBuf   := TEncoding.ASCII.GetBytes(LLine + #13#10);
  Assert.IsTrue(TryParseProxyProtocolV1(@LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid));
  // Consumed = line length + 2 (CRLF)
  Assert.AreEqual(Length(LLine) + 2, LConsumed);
end;

// ---------------------------------------------------------------------------
// Auto tests
// ---------------------------------------------------------------------------

procedure TProxyProtocolAutoTests.Auto_V2Signature_ParsesAsV2;
const
  SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid, LNoSig: Boolean;
begin
  // Build minimal LOCAL command (v2) to auto-detect as v2
  SetLength(LBuf, 16);
  Move(SIG[0], LBuf[0], 12);
  LBuf[12] := $20; LBuf[13] := $00; LBuf[14] := $00; LBuf[15] := $00;

  Assert.IsTrue(TryParseProxyProtocolAuto(ppAuto, @LBuf[0], 16,
    LAddr, LPort, LConsumed, LIncomp, LInvalid, LNoSig));
  Assert.IsFalse(LNoSig);
end;

procedure TProxyProtocolAutoTests.Auto_V1Signature_ParsesAsV1;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid, LNoSig: Boolean;
begin
  LBuf := TEncoding.ASCII.GetBytes('PROXY TCP4 1.2.3.4 5.6.7.8 100 80'#13#10);
  Assert.IsTrue(TryParseProxyProtocolAuto(ppAuto, @LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid, LNoSig));
  Assert.AreEqual('1.2.3.4', LAddr);
  Assert.IsFalse(LNoSig);
end;

procedure TProxyProtocolAutoTests.Auto_NoSignature_SetsNoSignatureFlag;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid, LNoSig: Boolean;
begin
  LBuf := TEncoding.ASCII.GetBytes('GET / HTTP/1.1'#13#10'Host: x'#13#10#13#10);
  TryParseProxyProtocolAuto(ppAuto, @LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid, LNoSig);
  Assert.IsTrue(LNoSig);
end;

procedure TProxyProtocolAutoTests.Auto_Incomplete_SetsIncompleteFlag;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid, LNoSig: Boolean;
begin
  // Only 3 bytes — could be the start of either PROXY or a v2 signature
  LBuf := TEncoding.ASCII.GetBytes('PRO');
  TryParseProxyProtocolAuto(ppAuto, @LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid, LNoSig);
  Assert.IsTrue(LIncomp);
  Assert.IsFalse(LNoSig);
end;

procedure TProxyProtocolAutoTests.ModeV1_V2Data_ReturnsFalse;
const
  SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid, LNoSig: Boolean;
begin
  SetLength(LBuf, 16);
  Move(SIG[0], LBuf[0], 12);
  LBuf[12] := $20; LBuf[13] := $00; LBuf[14] := $00; LBuf[15] := $00;
  // ppV1 mode + v2 data → v1 parser finds no "PROXY " signature → False
  Assert.IsFalse(TryParseProxyProtocolAuto(ppV1, @LBuf[0], 16,
    LAddr, LPort, LConsumed, LIncomp, LInvalid, LNoSig));
end;

procedure TProxyProtocolAutoTests.ModeV2_V1Data_ReturnsFalse;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid, LNoSig: Boolean;
begin
  LBuf := TEncoding.ASCII.GetBytes('PROXY TCP4 1.2.3.4 5.6.7.8 100 80'#13#10);
  // ppV2 mode + v1 data → v2 parser finds no binary signature → False
  Assert.IsFalse(TryParseProxyProtocolAuto(ppV2, @LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid, LNoSig));
end;

procedure TProxyProtocolAutoTests.ModeDisabled_SetsNoSignature;
var
  LBuf:      TBytes;
  LAddr:     string; LPort: Word; LConsumed: Integer;
  LIncomp, LInvalid, LNoSig: Boolean;
begin
  LBuf := TEncoding.ASCII.GetBytes('anything');
  TryParseProxyProtocolAuto(ppDisabled, @LBuf[0], Length(LBuf),
    LAddr, LPort, LConsumed, LIncomp, LInvalid, LNoSig);
  Assert.IsTrue(LNoSig);
end;

initialization
  TDUnitX.RegisterTestFixture(TProxyProtocolV2Tests);
  TDUnitX.RegisterTestFixture(TProxyProtocolV1Tests);
  TDUnitX.RegisterTestFixture(TProxyProtocolAutoTests);

end.
