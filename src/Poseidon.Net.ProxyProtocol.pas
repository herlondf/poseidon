unit Poseidon.Net.ProxyProtocol;

// Proxy Protocol v1 (text) and v2 (binary) header parsing.
// No I/O — operates on raw byte buffers already in the connection's AccumBuf.
//
// v2 binary signature (12 bytes):
//   0D 0A 0D 0A 00 0D 0A 51 55 49 54 0A
// v1 text signature:
//   "PROXY " (6 bytes)
//
// Usage pattern (called once per connection, before HTTP parsing):
//   if TryParseProxyProtocolAuto(Buf, BufLen, Addr, Port, Consumed) then
//     update RemoteAddr/Port and strip Consumed bytes from AccumBuf
//   else if result is incomplete: wait for more data
//   else: handle error

interface

uses
  System.SysUtils,
  System.Math,
  Poseidon.Net.Security;

type
  TProxyProtocolMode = (ppDisabled, ppV1, ppV2, ppAuto);

// Parse a Proxy Protocol v2 binary header.
// Returns True when a complete, valid v2 header was found.
// ARemoteAddr: dotted-decimal IPv4 or colon-hex IPv6 source address.
// ARemotePort: source port in host byte order.
// AConsumed:   total bytes consumed (fixed 16-byte header + addr block).
// AIncomplete: set to True when the buffer holds the signature but not the
//              full addr block yet (caller should wait for more data).
// AInvalid:    set to True when bytes look like v2 but are malformed.
function TryParseProxyProtocolV2(ABuf: PByte; ABufLen: Integer;
  out ARemoteAddr: string; out ARemotePort: Word;
  out AConsumed: Integer;
  out AIncomplete, AInvalid: Boolean): Boolean;

// Parse a Proxy Protocol v1 text header.
// Returns True when a complete, valid v1 header was found.
// AIncomplete: set when CRLF not yet received.
// AInvalid:    set when header is present but malformed.
function TryParseProxyProtocolV1(ABuf: PByte; ABufLen: Integer;
  out ARemoteAddr: string; out ARemotePort: Word;
  out AConsumed: Integer;
  out AIncomplete, AInvalid: Boolean): Boolean;

// Auto-detect version by signature and delegate.
// When no known signature is found in the first 6+ bytes and AMode=ppAuto,
// sets ANoSignature=True — caller treats the connection as non-PP.
//
// APeerAddr:       real socket-level peer address (bare "IP" or "IP:port").
//                  Used to enforce the trusted-proxy allowlist below.
// ATrustedProxies: list of IPv4 CIDR blocks whose peers are allowed to send
//                  a Proxy Protocol header. If APeerAddr does NOT match any
//                  CIDR in this list, the header is NOT parsed and the caller
//                  MUST fall back to the real socket peer — ANoSignature is
//                  set True so the caller treats it as non-PP.
//                  Empty (or nil) list = fail-close: Proxy Protocol is never
//                  accepted (safe default against IP-spoofing).
function TryParseProxyProtocolAuto(AMode: TProxyProtocolMode;
  ABuf: PByte; ABufLen: Integer;
  out ARemoteAddr: string; out ARemotePort: Word;
  out AConsumed: Integer;
  out AIncomplete, AInvalid, ANoSignature: Boolean;
  const APeerAddr: string = '';
  const ATrustedProxies: TArray<string> = nil): Boolean;

implementation

const
  PP2_SIG: array[0..11] of Byte = (
    $0D, $0A, $0D, $0A, $00, $0D, $0A, $51, $55, $49, $54, $0A);
  CPP2SigSize = 12;
  PP2_HDR_SIZE = 16;  // 12 sig + 1 ver/cmd + 1 fam + 2 addr_len
  PP1_SIG = 'PROXY ';
  CPP1SigSize = 6;
  CPP2IPv6AddrSize = 36;
  CPP1MaxLineLen = 108;

function TryParseProxyProtocolV2(ABuf: PByte; ABufLen: Integer;
  out ARemoteAddr: string; out ARemotePort: Word;
  out AConsumed: Integer;
  out AIncomplete, AInvalid: Boolean): Boolean;
var
  I: Integer;
  LVerCmd: Byte;
  LFamProt: Byte;
  LFamily: Byte;
  LAddrLen: Word;
  LTotal: Integer;
  LAddr: PByte;
  LIP: array[0..3] of Byte;
  LPort: Word;
  LIPv6: array[0..15] of Byte;
begin
  Result := False;
  ARemoteAddr := '';
  ARemotePort := 0;
  AConsumed := 0;
  AIncomplete := False;
  AInvalid := False;

  if ABufLen < CPP2SigSize then
  begin
    AIncomplete := True;
    Exit;
  end;
  for I := 0 to CPP2SigSize - 1 do
    if ABuf[I] <> PP2_SIG[I] then Exit;

  if ABufLen < PP2_HDR_SIZE then
  begin
    AIncomplete := True;
    Exit;
  end;

  LVerCmd := ABuf[12];
  LFamProt := ABuf[13];
  LAddrLen := (Word(ABuf[14]) shl 8) or ABuf[15];
  LTotal := PP2_HDR_SIZE + LAddrLen;

  if (LVerCmd shr 4) <> 2 then
  begin
    AInvalid := True;
    Exit;
  end;

  if ABufLen < LTotal then
  begin
    AIncomplete := True;
    Exit;
  end;

  LFamily := LFamProt shr 4;
  LAddr := ABuf + PP2_HDR_SIZE;

  if (LVerCmd and $0F) = 0 then
  begin
    AConsumed := LTotal;
    Result := True;
    Exit;
  end;

  case LFamily of
    1: // AF_INET
    begin
      if LAddrLen < 12 then begin AInvalid := True; Exit; end;
      Move(LAddr[0], LIP[0], 4);
      Move(LAddr[8], LPort, 2);
      ARemoteAddr := Format('%d.%d.%d.%d', [LIP[0], LIP[1], LIP[2], LIP[3]]);
      ARemotePort := (Word(LAddr[8]) shl 8) or LAddr[9];
    end;
    2: // AF_INET6
    begin
      if LAddrLen < CPP2IPv6AddrSize then begin AInvalid := True; Exit; end;
      Move(LAddr[0], LIPv6[0], 16);
      ARemoteAddr := Format(
        '%x:%x:%x:%x:%x:%x:%x:%x',
        [(Word(LIPv6[0])  shl 8) or LIPv6[1],
         (Word(LIPv6[2])  shl 8) or LIPv6[3],
         (Word(LIPv6[4])  shl 8) or LIPv6[5],
         (Word(LIPv6[6])  shl 8) or LIPv6[7],
         (Word(LIPv6[8])  shl 8) or LIPv6[9],
         (Word(LIPv6[10]) shl 8) or LIPv6[11],
         (Word(LIPv6[12]) shl 8) or LIPv6[13],
         (Word(LIPv6[14]) shl 8) or LIPv6[15]]);
      ARemotePort := (Word(LAddr[32]) shl 8) or LAddr[33];
    end;
    else
    begin
      // AF_UNSPEC or AF_UNIX — consume but keep original addr
      AConsumed := LTotal;
      Result := True;
      Exit;
    end;
  end;

  AConsumed := LTotal;
  Result := True;
end;

function TryParseProxyProtocolV1(ABuf: PByte; ABufLen: Integer;
  out ARemoteAddr: string; out ARemotePort: Word;
  out AConsumed: Integer;
  out AIncomplete, AInvalid: Boolean): Boolean;
var
  I: Integer;
  LCRLF: Integer;
  LLine: AnsiString;
  LParts: TArray<string>;
  LPortNum: Integer;
begin
  Result := False;
  ARemoteAddr := '';
  ARemotePort := 0;
  AConsumed := 0;
  AIncomplete := False;
  AInvalid := False;

  if ABufLen < CPP1SigSize then
  begin
    AIncomplete := True;
    Exit;
  end;
  if (ABuf[0] <> Ord('P')) or (ABuf[1] <> Ord('R')) or
     (ABuf[2] <> Ord('O')) or (ABuf[3] <> Ord('X')) or
     (ABuf[4] <> Ord('Y')) or (ABuf[5] <> Ord(' ')) then
    Exit;

  LCRLf := -1;
  for I := 0 to Min(ABufLen - 2, CPP1MaxLineLen - 2) do
    if (ABuf[I] = $0D) and (ABuf[I + 1] = $0A) then
    begin
      LCRLf := I;
      Break;
    end;

  if LCRLf < 0 then
  begin
    if ABufLen > CPP1MaxLineLen then AInvalid := True
    else AIncomplete := True;
    Exit;
  end;

  SetString(LLine, PAnsiChar(ABuf), LCRLf);
  LParts := string(LLine).Split([' ']);

  if (Length(LParts) >= 2) and SameText(LParts[1], 'UNKNOWN') then
  begin
    AConsumed := LCRLf + 2;
    Result := True;
    Exit;
  end;

  // #M10: require EXACTLY the 6 fields — reject trailing garbage after the port.
  if Length(LParts) <> 6 then begin AInvalid := True; Exit; end;
  if not (SameText(LParts[1], 'TCP4') or SameText(LParts[1], 'TCP6')) then
  begin
    AInvalid := True;
    Exit;
  end;

  // #M10: cross-check the address family against the declared protocol so a
  // TCP4 line cannot smuggle an IPv6 address (and vice-versa).
  if SameText(LParts[1], 'TCP4') then
  begin
    if (Pos('.', LParts[2]) = 0) or (Pos(':', LParts[2]) > 0) then
    begin AInvalid := True; Exit; end;
  end
  else
    if Pos(':', LParts[2]) = 0 then
    begin AInvalid := True; Exit; end;

  // #M11: reject a port outside 0..65535 instead of silently truncating to 16 bits.
  LPortNum := StrToIntDef(LParts[4], -1);
  if (LPortNum < 0) or (LPortNum > 65535) then
  begin AInvalid := True; Exit; end;

  ARemoteAddr := LParts[2];
  ARemotePort := Word(LPortNum);
  AConsumed := LCRLf + 2;
  Result := True;
end;

function TryParseProxyProtocolAuto(AMode: TProxyProtocolMode;
  ABuf: PByte; ABufLen: Integer;
  out ARemoteAddr: string; out ARemotePort: Word;
  out AConsumed: Integer;
  out AIncomplete, AInvalid, ANoSignature: Boolean;
  const APeerAddr: string;
  const ATrustedProxies: TArray<string>): Boolean;
var
  I: Integer;
  LTrusted: Boolean;
begin
  Result := False;
  ARemoteAddr := '';
  ARemotePort := 0;
  AConsumed := 0;
  AIncomplete := False;
  AInvalid := False;
  ANoSignature := False;

  // Allowlist enforcement: only peers inside a trusted CIDR may inject a
  // Proxy Protocol header. Empty allowlist = fail-close (never accept PP).
  // Without this check any client could forge a source IP by sending PROXY.
  if AMode <> ppDisabled then
  begin
    LTrusted := False;
    if Length(ATrustedProxies) > 0 then
      for I := 0 to High(ATrustedProxies) do
        if IsIPInCIDR(APeerAddr, ATrustedProxies[I]) then
        begin
          LTrusted := True;
          Break;
        end;
    if not LTrusted then
    begin
      // Peer is not an allowed proxy — do NOT parse the header. Signal the
      // caller to use the real socket peer address instead.
      ANoSignature := True;
      Exit;
    end;
  end;

  case AMode of
    ppV2:
      Result := TryParseProxyProtocolV2(ABuf, ABufLen, ARemoteAddr, ARemotePort,
        AConsumed, AIncomplete, AInvalid);
    ppV1:
      Result := TryParseProxyProtocolV1(ABuf, ABufLen, ARemoteAddr, ARemotePort,
        AConsumed, AIncomplete, AInvalid);
    ppAuto:
    begin
      Result := TryParseProxyProtocolV2(ABuf, ABufLen, ARemoteAddr, ARemotePort,
        AConsumed, AIncomplete, AInvalid);
      if Result or AIncomplete or AInvalid then Exit;
      Result := TryParseProxyProtocolV1(ABuf, ABufLen, ARemoteAddr, ARemotePort,
        AConsumed, AIncomplete, AInvalid);
      if Result or AIncomplete or AInvalid then Exit;
      if ABufLen >= CPP1SigSize then
        ANoSignature := True
      else
        AIncomplete := True;
    end;
    else
    begin
      Result := False;
      ANoSignature := True;
    end;
  end;
end;

end.
