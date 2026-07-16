unit Poseidon.Net.HTTP1.Parser;

// HTTP/1.1 request parser (SRP refactoring R-2).
//
// Zero-split parser: scans a raw byte buffer using integer indices,
// materialising Delphi strings only for the final field values. Eliminates
// the large GetString + 2×Split TArray allocations per request that the
// original inline code had before extraction.
//
// Entry points:
//   ParseHTTP1Request  — parse one complete request from a raw byte buffer
//   DecodeHTTP1Chunked — decode chunked Transfer-Encoding body

interface

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  Generics.Collections,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  {$ENDIF}
  Poseidon.Net.Security;

// Parses one HTTP/1.1 request from ABuf[0..ABufLen-1].
//
// Returns True when a complete, valid request was parsed.
//   AConsumed   — bytes consumed from ABuf; caller must shift its buffer.
//   ABadRequest — True when the request is definitively malformed (→ 400).
//
// Returns False + ABadRequest=False when more data is needed (→ wait).
// Returns False + ABadRequest=True  when the request is malformed (→ close).
function ParseHTTP1Request(
  const ABuf:         TBytes;
  ABufLen:            Integer;
  AMaxHeaderSize:     Integer;
  AMaxBodySize:       Integer;
  out AMethod:        string;
  out APath:          string;
  out AQueryString:   string;
  out AHeaders:       TArray<TPair<string,string>>;
  out ARawBody:       TBytes;
  out AKeepAlive:     Boolean;
  out AConsumed:      Integer;
  out ABadRequest:    Boolean): Boolean;

// Lightweight parser — zero string allocations for headers.
// Parses only request line (method, path, query) and detects Content-Length,
// Connection and Transfer-Encoding by byte scan.  Headers are stored as raw
// byte range (AHdrStart..AHdrEnd) for lazy materialization by the caller.
// Used when SyncDispatch is active for maximum throughput.
function ParseHTTP1Lightweight(
  const ABuf:         TBytes;
  ABufLen:            Integer;
  AMaxHeaderSize:     Integer;
  AMaxBodySize:       Integer;
  out AMethod:        string;
  out APath:          string;
  out AQueryString:   string;
  out ARawBody:       TBytes;
  out AKeepAlive:     Boolean;
  out AConsumed:      Integer;
  out ABadRequest:    Boolean;
  out AHdrStart:      Integer;
  out AHdrEnd:        Integer): Boolean;

// Materializes headers from raw buffer range.  Called on-demand when the
// handler or middleware actually accesses headers.
function MaterializeHeaders(const ABuf: TBytes;
  AHdrStart, AHdrEnd: Integer): TArray<TPair<string,string>>;

// Decodes chunked Transfer-Encoding body from ABuf[0..ABufLen-1].
// AMaxBodySize caps the total decoded size (raises malformed on excess).
//
// Result=True  → complete; AConsumed = bytes consumed from ABuf.
// Result=False, AMalformed=False → incomplete, wait for more data.
// Result=False, AMalformed=True  → malformed, close connection.
function DecodeHTTP1Chunked(
  ABuf:          PByte;
  ABufLen:       Integer;
  AMaxBodySize:  Integer;
  out ABody:     TBytes;
  out AConsumed: Integer;
  out AMalformed: Boolean): Boolean;

implementation

// ---------------------------------------------------------------------------
// Byte classification lookup table
//
// Pre-computed flags per byte value — replaces per-byte comparisons in the
// parsing hot loops with a single indexed read + bitmask test.
// ---------------------------------------------------------------------------

const
  BF_CR    = $01;  // $0D
  BF_LF    = $02;  // $0A
  BF_SP    = $04;  // $20
  BF_HT    = $08;  // $09
  BF_COLON = $10;  // $3A
  BF_QMARK = $20;  // $3F
  BF_OWS   = $0C;  // SP or HT (BF_SP or BF_HT)
  // Maximum number of request headers accepted. Exceeding this is rejected
  // (400) rather than silently truncated — see issue #164.
  CMaxHeaderCount = 100;
  // Max digits accepted for Content-Length; 18 decimal digits always fit an
  // Int64 without overflow (Int64 max has 19 digits) — overflow guard (#158).
  CMaxCLDigits = 18;
  // Max hex digits accepted for a chunk size (16 hex digits = 64-bit space).
  CMaxChunkHexDigits = 16;
  // Cap for the entire chunk-size line (hex size + optional chunk extensions).
  // RFC 7230 §4.1.1 permits `size[;ext-name[=ext-val]]` — the parser accepts
  // extensions but skips them without semantic validation; the cap bounds the
  // work per line and prevents a chunk-ext DoS.
  CMaxChunkLineSize = 8192;

var
  GLUT: array[0..255] of Byte;

procedure _InitLUT;
begin
  FillChar(GLUT, SizeOf(GLUT), 0);
  GLUT[$0D] := BF_CR;
  GLUT[$0A] := BF_LF;
  GLUT[$20] := BF_SP;
  GLUT[$09] := BF_HT;
  GLUT[$3A] := BF_COLON;
  GLUT[$3F] := BF_QMARK;
end;

// ---------------------------------------------------------------------------
// Perfect hash for common HTTP headers
// ---------------------------------------------------------------------------

type
  THeaderId = (
    hiUnknown,
    hiContentLength, hiContentType, hiConnection, hiHost,
    hiAccept, hiAcceptEncoding, hiAuthorization, hiCacheControl,
    hiUserAgent, hiCookie, hiSecWebSocketKey, hiSecWebSocketExtensions,
    hiUpgrade, hiTransferEncoding, hiContentEncoding,
    hiXForwardedFor, hiXRealIP, hiOrigin, hiReferer
  );

  THeaderHashEntry = record
    Name: AnsiString;
    Id: THeaderId;
  end;

const
  CHeaderHashSize = 256;

var
  GHeaderHash: array[0..CHeaderHashSize - 1] of THeaderHashEntry;

function _QuickHeaderHash(AName: PByte; ALen: Integer): Byte; inline;
begin
  Result := Byte(ALen) xor (AName[0] or $20) xor (AName[ALen - 1] or $20);
end;

function _HeaderBytesMatch(A: PByte; ALen: Integer;
  const ATarget: AnsiString): Boolean;
var
  LI: Integer;
begin
  if ALen <> Length(ATarget) then Exit(False);
  for LI := 1 to ALen do
    if (A[LI - 1] or $20) <> Byte(ATarget[LI]) then Exit(False);
  Result := True;
end;

// Open-addressed lookup: the byte hash is lossy, so several distinct header
// names collide on the same slot (e.g. content-length vs x-forwarded-for,
// connection vs referer). Linear probing walks the collision cluster until a
// name match or an empty slot is found. With <20 entries in a 256-slot table
// there is always an empty slot, so the loop always terminates (issue #156).
function LookupHeaderId(AName: PByte; ALen: Integer): THeaderId;
var
  LSlot: Integer;
begin
  if ALen <= 0 then Exit(hiUnknown);
  LSlot := _QuickHeaderHash(AName, ALen);
  while GHeaderHash[LSlot].Id <> hiUnknown do
  begin
    if _HeaderBytesMatch(AName, ALen, GHeaderHash[LSlot].Name) then
      Exit(GHeaderHash[LSlot].Id);
    LSlot := (LSlot + 1) and (CHeaderHashSize - 1);
  end;
  Result := hiUnknown;
end;

procedure _RegisterHeader(const AName: AnsiString; AId: THeaderId);
var
  LSlot: Integer;
begin
  LSlot := Byte(Length(AName)) xor (Byte(AName[1]) or $20) xor
           (Byte(AName[Length(AName)]) or $20);
  // Probe to the next free slot on collision so no header overwrites another.
  while GHeaderHash[LSlot].Id <> hiUnknown do
    LSlot := (LSlot + 1) and (CHeaderHashSize - 1);
  GHeaderHash[LSlot].Name := AName;
  GHeaderHash[LSlot].Id := AId;
end;

procedure _InitHeaderHash;
var
  LI: Integer;
begin
  for LI := 0 to CHeaderHashSize - 1 do
  begin
    GHeaderHash[LI].Name := '';
    GHeaderHash[LI].Id := hiUnknown;
  end;
  _RegisterHeader('content-length', hiContentLength);
  _RegisterHeader('content-type', hiContentType);
  _RegisterHeader('connection', hiConnection);
  _RegisterHeader('host', hiHost);
  _RegisterHeader('accept', hiAccept);
  _RegisterHeader('accept-encoding', hiAcceptEncoding);
  _RegisterHeader('authorization', hiAuthorization);
  _RegisterHeader('cache-control', hiCacheControl);
  _RegisterHeader('user-agent', hiUserAgent);
  _RegisterHeader('cookie', hiCookie);
  _RegisterHeader('sec-websocket-key', hiSecWebSocketKey);
  _RegisterHeader('sec-websocket-extensions', hiSecWebSocketExtensions);
  _RegisterHeader('upgrade', hiUpgrade);
  _RegisterHeader('transfer-encoding', hiTransferEncoding);
  _RegisterHeader('content-encoding', hiContentEncoding);
  _RegisterHeader('x-forwarded-for', hiXForwardedFor);
  _RegisterHeader('x-real-ip', hiXRealIP);
  _RegisterHeader('origin', hiOrigin);
  _RegisterHeader('referer', hiReferer);
end;

// ---------------------------------------------------------------------------
// Word-scan CRLF — process 4 bytes at a time
// ---------------------------------------------------------------------------

function _FindCRLFCRLF(ABuf: PByte; ALen: Integer): Integer;
var
  LI: Integer;
  LWord: UInt32;
begin
  LI := 0;
  while LI + 4 <= ALen do
  begin
    LWord := PUInt32(@ABuf[LI])^;
    if LWord = $0A0D0A0D then begin Result := LI; Exit; end;
    Inc(LI);
  end;
  Result := -1;
end;

// Module-level fast ASCII→string conversion (no TEncoding overhead)
function _FastBufToStr(const ABuf: TBytes; AStart, ALen: Integer): string;
var
  LI: Integer;
begin
  if ALen <= 0 then begin Result := ''; Exit; end;
  SetLength(Result, ALen);
  for LI := 0 to ALen - 1 do
    PWord(@PChar(Pointer(Result))[LI])^ := ABuf[AStart + LI];
end;

// Validates a Content-Length string value: trims OWS, then requires a
// non-empty run of decimal digits no longer than CMaxCLDigits (overflow guard).
// Returns False for empty, non-numeric, or over-long values (issue #158).
function _ParseContentLength(const AValue: string; out AVal: Int64): Boolean;
var
  LI, LStart, LEnd: Integer;
begin
  Result := False;
  AVal   := 0;
  LStart := 1;
  LEnd   := Length(AValue);
  while (LStart <= LEnd) and
        ((AValue[LStart] = ' ') or (AValue[LStart] = #9)) do Inc(LStart);
  while (LEnd >= LStart) and
        ((AValue[LEnd] = ' ') or (AValue[LEnd] = #9)) do Dec(LEnd);
  if LStart > LEnd then Exit;
  if (LEnd - LStart + 1) > CMaxCLDigits then Exit;
  for LI := LStart to LEnd do
  begin
    if (AValue[LI] < '0') or (AValue[LI] > '9') then Exit;
    AVal := AVal * 10 + (Ord(AValue[LI]) - Ord('0'));
  end;
  Result := True;
end;

// Byte-range variant of _ParseContentLength for the lightweight parser.
// ABuf[AStart..AEnd-1] is the value (leading OWS already skipped by caller);
// trailing OWS is trimmed here.
function _ParseContentLengthBytes(const ABuf: TBytes;
  AStart, AEnd: Integer; out AVal: Int64): Boolean;
var
  LI: Integer;
begin
  Result := False;
  AVal   := 0;
  while (AEnd > AStart) and
        ((ABuf[AEnd - 1] = $20) or (ABuf[AEnd - 1] = $09)) do Dec(AEnd);
  if AEnd <= AStart then Exit;
  if (AEnd - AStart) > CMaxCLDigits then Exit;
  for LI := AStart to AEnd - 1 do
  begin
    if (ABuf[LI] < Ord('0')) or (ABuf[LI] > Ord('9')) then Exit;
    AVal := AVal * 10 + (ABuf[LI] - Ord('0'));
  end;
  Result := True;
end;

// Case-insensitive equality of ABuf[AStart..AEnd-1] (trailing OWS trimmed)
// against a lowercase ASCII target. Used to require Transfer-Encoding to be
// exactly "chunked" in the lightweight parser (issue #160).
function _BytesEqualCI(const ABuf: TBytes; AStart, AEnd: Integer;
  const ATarget: AnsiString): Boolean;
var
  LI: Integer;
begin
  Result := False;
  while (AEnd > AStart) and
        ((ABuf[AEnd - 1] = $20) or (ABuf[AEnd - 1] = $09)) do Dec(AEnd);
  if (AEnd - AStart) <> Length(ATarget) then Exit;
  for LI := 0 to (AEnd - AStart) - 1 do
    if (ABuf[AStart + LI] or $20) <> Byte(ATarget[LI + 1]) then Exit;
  Result := True;
end;

function DecodeHTTP1Chunked(ABuf: PByte; ABufLen, AMaxBodySize: Integer;
  out ABody: TBytes; out AConsumed: Integer; out AMalformed: Boolean): Boolean;
var
  LPos:       Integer;
  LCRLFP:     Integer;
  LSize:      AnsiString;
  LSemi:      Integer;
  LChunk:     Int64;
  LOldLen:    Integer;
  LDataStart: Integer;
  LBytes:     PByte;
  I, LLen:    Integer;
begin
  Result     := False;
  AMalformed := False;
  AConsumed  := 0;
  SetLength(ABody, 0);
  LPos   := 0;
  LBytes := ABuf;

  while True do
  begin
    // Find CRLF after chunk-size line
    LCRLFP := -1;
    I := LPos;
    while I < ABufLen - 1 do
    begin
      if (LBytes[I] = $0D) and (LBytes[I + 1] = $0A) then
      begin
        LCRLFP := I;
        Break;
      end;
      Inc(I);
    end;
    if LCRLFP < 0 then Exit;

    LLen := LCRLFP - LPos;
    if LLen < 1 then begin AMalformed := True; Exit; end;
    // Whole chunk-size line (hex + optional chunk extensions) is capped to
    // bound per-line work and prevent a chunk-ext DoS (RFC 7230 §4.1.1).
    if LLen > CMaxChunkLineSize then begin AMalformed := True; Exit; end;

    // Locate first ';' separating hex size from chunk extensions; extensions
    // are accepted but ignored (skipped up to CRLF) without semantic parsing.
    LSemi := 0;
    for I := 0 to LLen - 1 do
      if LBytes[LPos + I] = Byte(';') then begin LSemi := I + 1; Break; end;
    if LSemi > 0 then
      LLen := LSemi - 1;

    if LLen < 1 then begin AMalformed := True; Exit; end;
    // Hex-only portion cap (16 hex digits fits a 64-bit chunk size).
    if LLen > CMaxChunkHexDigits then begin AMalformed := True; Exit; end;

    SetLength(LSize, LLen);
    Move(LBytes[LPos], LSize[1], LLen);

    if not TryStrToInt64('$' + string(LSize), LChunk) or (LChunk < 0) then
    begin
      AMalformed := True;
      Exit;
    end;

    if LChunk = 0 then
    begin
      // Last chunk. Consume the (possibly empty) trailer section, which ends
      // with a blank line (a bare CRLF). The terminator MUST be present;
      // otherwise report "need more data" rather than falsely completing and
      // leaving residual bytes that desync the next request (issue #157).
      LPos := LCRLFP + 2;
      while True do
      begin
        if LPos + 1 >= ABufLen then Exit;  // terminator not yet arrived → wait
        if (LBytes[LPos] = $0D) and (LBytes[LPos + 1] = $0A) then
        begin
          AConsumed := LPos + 2;
          Result    := True;
          Exit;
        end;
        // Skip one trailer-field line.
        I      := LPos;
        LCRLFP := -1;
        while I < ABufLen - 1 do
        begin
          if (LBytes[I] = $0D) and (LBytes[I + 1] = $0A) then
          begin LCRLFP := I; Break; end;
          Inc(I);
        end;
        if LCRLFP < 0 then Exit;  // incomplete trailer line → wait
        LPos := LCRLFP + 2;
      end;
    end;

    if LChunk > AMaxBodySize then begin AMalformed := True; Exit; end;

    LDataStart := LCRLFP + 2;
    if Int64(LDataStart) + LChunk + 2 > Int64(ABufLen) then Exit;

    // The two bytes following the chunk data MUST be CRLF.
    if (LBytes[LDataStart + Integer(LChunk)] <> $0D) or
       (LBytes[LDataStart + Integer(LChunk) + 1] <> $0A) then
    begin AMalformed := True; Exit; end;

    LOldLen := Length(ABody);
    if Int64(LOldLen) + LChunk > AMaxBodySize then begin AMalformed := True; Exit; end;
    SetLength(ABody, LOldLen + Integer(LChunk));
    Move(LBytes[LDataStart], ABody[LOldLen], LChunk);

    LPos := LDataStart + Integer(LChunk) + 2;
  end;
end;

function ParseHTTP1Request(
  const ABuf: TBytes; ABufLen, AMaxHeaderSize, AMaxBodySize: Integer;
  out AMethod, APath, AQueryString: string;
  out AHeaders: TArray<TPair<string,string>>;
  out ARawBody: TBytes; out AKeepAlive: Boolean;
  out AConsumed: Integer; out ABadRequest: Boolean): Boolean;
// Zero-Split parser: scans AccumBuf byte-by-byte using indices, materializing
// strings only for the final Method/Path/Headers values. Eliminates the big
// GetString + 2 Split TArray allocations per request.
const
  SP               = $20;
  HT               = $09;
  CR               = $0D;
  LF               = $0A;

  function BufToStr(AStart, ALen: Integer): string;
  var
    LI: Integer;
  begin
    if ALen <= 0 then begin Result := ''; Exit; end;
    SetLength(Result, ALen);
    for LI := 0 to ALen - 1 do
      PWord(@PChar(Pointer(Result))[LI])^ := ABuf[AStart + LI];
  end;

var
  I: Integer;
  LHdrEnd: Integer;
  LScanEnd: Integer;
  LLineStart: Integer;
  LLineEnd: Integer;
  LSpace1: Integer;
  LSpace2: Integer;
  LColonPos: Integer;
  LQPos: Integer;
  LValStart: Integer;
  LName, LValue: string;
  LCL: Int64;
  LThisCL: Int64;
  LCLSeen: Boolean;
  LTEPresent: Boolean;
  LBodyStart: Integer;
  LConsumed: Integer;
  LHdrCount: Integer;
  LIsHttp11: Boolean;
  LIsChunked: Boolean;
  LChunkBody: TBytes;
  LChunkBytes: Integer;
  LChunkBad: Boolean;
begin
  Result      := False;
  ABadRequest := False;
  AConsumed   := 0;

  LScanEnd := ABufLen;
  if LScanEnd > AMaxHeaderSize + 4 then LScanEnd := AMaxHeaderSize + 4;
  LHdrEnd := _FindCRLFCRLF(@ABuf[0], LScanEnd);

  if LHdrEnd < 0 then
  begin
    if ABufLen > AMaxHeaderSize then ABadRequest := True;
    Exit;
  end;

  // --- Parse request line: METHOD SP PATH[?QUERY] [SP HTTP/x.y] CRLF ---
  // Loop bound is LHdrEnd (inclusive): when there are no headers the CRLF
  // that terminates the request line IS at LHdrEnd (first \r of \r\n\r\n).
  LLineEnd := -1;
  for I := 0 to LHdrEnd do
    if (ABuf[I] = CR) and (ABuf[I+1] = LF) then
    begin
      LLineEnd := I;
      Break;
    end;
  if LLineEnd <= 0 then begin ABadRequest := True; Exit; end;

  // First space: METHOD SP PATH
  LSpace1 := -1;
  for I := 0 to LLineEnd - 1 do
    if ABuf[I] = SP then begin LSpace1 := I; Break; end;
  if LSpace1 <= 0 then begin ABadRequest := True; Exit; end;

  // Second space: PATH SP VERSION (optional in HTTP/0.9)
  LSpace2 := -1;
  for I := LSpace1 + 1 to LLineEnd - 1 do
    if ABuf[I] = SP then begin LSpace2 := I; Break; end;
  if LSpace2 < 0 then LSpace2 := LLineEnd;

  AMethod := BufToStr(0, LSpace1);

  // Find '?' inside path to split path/query
  LQPos := -1;
  for I := LSpace1 + 1 to LSpace2 - 1 do
    if ABuf[I] = Byte('?') then begin LQPos := I; Break; end;
  if LQPos > 0 then
  begin
    APath        := BufToStr(LSpace1 + 1, LQPos - LSpace1 - 1);
    AQueryString := BufToStr(LQPos + 1, LSpace2 - LQPos - 1);
  end
  else
  begin
    APath        := BufToStr(LSpace1 + 1, LSpace2 - LSpace1 - 1);
    AQueryString := '';
  end;

  // Detect HTTP/1.1 by raw bytes (no string allocation)
  LIsHttp11 := False;
  if (LLineEnd - LSpace2 - 1) = 8 then
    LIsHttp11 :=
      (ABuf[LSpace2 + 1] = Byte('H')) and
      (ABuf[LSpace2 + 2] = Byte('T')) and
      (ABuf[LSpace2 + 3] = Byte('T')) and
      (ABuf[LSpace2 + 4] = Byte('P')) and
      (ABuf[LSpace2 + 5] = Byte('/')) and
      (ABuf[LSpace2 + 6] = Byte('1')) and
      (ABuf[LSpace2 + 7] = Byte('.')) and
      (ABuf[LSpace2 + 8] = Byte('1'));
  AKeepAlive := LIsHttp11;

  // --- Parse headers ---
  LCL        := 0;
  LThisCL    := 0;
  LCLSeen    := False;
  LTEPresent := False;
  LIsChunked := False;
  LHdrCount  := 0;
  // #M13: start small and grow geometrically instead of pre-allocating (and
  // zeroing) CMaxHeaderCount pairs on every request; trimmed to LHdrCount below.
  SetLength(AHeaders, 16);

  LLineStart := LLineEnd + 2;
  while LLineStart < LHdrEnd do
  begin
    // Reject rather than silently truncate when the header count is exceeded.
    if LHdrCount >= CMaxHeaderCount then begin ABadRequest := True; Exit; end;

    // Single-pass scan: find CRLF and colon in one loop using the LUT
    LLineEnd  := -1;
    LColonPos := -1;
    for I := LLineStart to LHdrEnd do
    begin
      case GLUT[ABuf[I]] of
        BF_COLON:
          if LColonPos < 0 then LColonPos := I;
        BF_CR:
          if ABuf[I+1] = LF then
          begin
            LLineEnd := I;
            Break;
          end;
      end;
    end;
    if LLineEnd < 0 then Break;
    if LLineEnd = LLineStart then  // empty line — skip
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    // Reject obsolete line folding (obs-fold): a header line starting with
    // SP/HT is a continuation — RFC 7230 §3.2.4 requires rejection (issue #162).
    if (GLUT[ABuf[LLineStart]] and BF_OWS) <> 0 then
    begin ABadRequest := True; Exit; end;

    if LColonPos < 0 then
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    // Reject whitespace before the colon ("Name : value") — an HTTP request
    // smuggling vector (RFC 7230 §3.2.4) (issue #160).
    if (LColonPos > LLineStart) and
       ((GLUT[ABuf[LColonPos - 1]] and BF_OWS) <> 0) then
    begin ABadRequest := True; Exit; end;

    // Skip OWS after colon using LUT
    LValStart := LColonPos + 1;
    while (LValStart < LLineEnd) and
          ((GLUT[ABuf[LValStart]] and BF_OWS) <> 0) do
      Inc(LValStart);

    LName  := BufToStr(LLineStart, LColonPos - LLineStart);
    LValue := BufToStr(LValStart,  LLineEnd  - LValStart);

    if LHdrCount = Length(AHeaders) then
      SetLength(AHeaders, Length(AHeaders) * 2);
    AHeaders[LHdrCount] := TPair<string,string>.Create(LName, LValue);
    Inc(LHdrCount);

    case LookupHeaderId(@ABuf[LLineStart], LColonPos - LLineStart) of
      hiConnection:
        begin
          // M24: lower-case once (LValue already copied into AHeaders above).
          LValue := LowerCase(LValue);
          if Pos('keep-alive', LValue) > 0 then AKeepAlive := True;
          if Pos('close',      LValue) > 0 then AKeepAlive := False;
        end;
      hiContentLength:
        begin
          // Validate value; reject conflicting duplicate Content-Length
          // headers (RFC 7230 §3.3.3, CL.CL smuggling) (issue #158).
          if not _ParseContentLength(LValue, LThisCL) then
          begin ABadRequest := True; Exit; end;
          if LCLSeen and (LThisCL <> LCL) then
          begin ABadRequest := True; Exit; end;
          LCL     := LThisCL;
          LCLSeen := True;
        end;
      hiTransferEncoding:
        begin
          LTEPresent := True;
          LIsChunked := SameText(Trim(LValue), 'chunked');
        end;
    end;

    LLineStart := LLineEnd + 2;
  end;
  SetLength(AHeaders, LHdrCount);

  // A Transfer-Encoding whose final coding is not "chunked" leaves the message
  // length undeterminable — reject (RFC 7230 §3.3.3) (issue #160).
  if LTEPresent and not LIsChunked then
  begin ABadRequest := True; Exit; end;

  // Request smuggling guard — Content-Length + Transfer-Encoding: chunked
  // (RFC 7230 §3.3.3). Presence of CL (even "0") conflicts with chunked.
  if HasRequestSmuggling(LCLSeen, LIsChunked) then
  begin
    ABadRequest := True;
    Exit;
  end;

  LBodyStart := LHdrEnd + 4;

  if LIsChunked then
  begin
    if not DecodeHTTP1Chunked(@ABuf[LBodyStart],
         ABufLen - LBodyStart, AMaxBodySize,
         LChunkBody, LChunkBytes, LChunkBad) then
    begin
      ABadRequest := LChunkBad;
      Exit;
    end;
    ARawBody  := LChunkBody;
    LConsumed := LBodyStart + LChunkBytes;
  end
  else
  begin
    // Reject a declared body larger than the configured cap instead of waiting
    // for bytes that would only ever trip the accumulation limit (issue #158).
    if LCLSeen and (LCL > AMaxBodySize) then
    begin ABadRequest := True; Exit; end;
    if LCL > 0 then
    begin
      if ABufLen - LBodyStart < LCL then Exit;
      SetLength(ARawBody, LCL);
      Move(ABuf[LBodyStart], ARawBody[0], LCL);
    end
    else
      SetLength(ARawBody, 0);
    LConsumed := LBodyStart + Integer(LCL);
  end;

  AConsumed := LConsumed;
  Result    := True;
end;

// ---------------------------------------------------------------------------
// ParseHTTP1Lightweight — minimal parse (zero header string allocations)
// ---------------------------------------------------------------------------

function ParseHTTP1Lightweight(
  const ABuf: TBytes; ABufLen, AMaxHeaderSize, AMaxBodySize: Integer;
  out AMethod, APath, AQueryString: string;
  out ARawBody: TBytes; out AKeepAlive: Boolean;
  out AConsumed: Integer; out ABadRequest: Boolean;
  out AHdrStart, AHdrEnd: Integer): Boolean;
const
  SP = $20; CR = $0D; LF = $0A;

  // Direct byte→char widening — avoids TEncoding virtual dispatch + table lookup
  function BufToStr(AStart, ALen: Integer): string;
  var
    LI: Integer;
  begin
    if ALen <= 0 then begin Result := ''; Exit; end;
    SetLength(Result, ALen);
    for LI := 0 to ALen - 1 do
      PWord(@PChar(Pointer(Result))[LI])^ := ABuf[AStart + LI];
  end;

var
  I, LHdrEnd, LScanEnd, LLineEnd, LSpace1, LSpace2, LQPos: Integer;
  LLineStart, LColonPos, LValStart: Integer;
  LCL: Int64;
  LThisCL: Int64;
  LCLSeen: Boolean;
  LTEPresent: Boolean;
  LHdrCount: Integer;
  LIsHttp11, LIsChunked: Boolean;
  LBodyStart, LConsumed: Integer;
  LChunkBody: TBytes;
  LChunkBytes: Integer;
  LChunkBad: Boolean;
  LValLen: Integer;
begin
  Result      := False;
  ABadRequest := False;
  AConsumed   := 0;
  AHdrStart   := 0;
  AHdrEnd     := 0;

  LScanEnd := ABufLen;
  if LScanEnd > AMaxHeaderSize + 4 then LScanEnd := AMaxHeaderSize + 4;
  LHdrEnd := _FindCRLFCRLF(@ABuf[0], LScanEnd);

  if LHdrEnd < 0 then
  begin
    if ABufLen > AMaxHeaderSize then ABadRequest := True;
    Exit;
  end;

  // Parse request line — bound is LHdrEnd inclusive: with no headers the
  // request-line CRLF IS at LHdrEnd (first \r of the \r\n\r\n terminator).
  LLineEnd := -1;
  for I := 0 to LHdrEnd do
    if (ABuf[I] = CR) and (ABuf[I+1] = LF) then
    begin LLineEnd := I; Break; end;
  if LLineEnd <= 0 then begin ABadRequest := True; Exit; end;

  LSpace1 := -1;
  for I := 0 to LLineEnd - 1 do
    if ABuf[I] = SP then begin LSpace1 := I; Break; end;
  if LSpace1 <= 0 then begin ABadRequest := True; Exit; end;

  LSpace2 := -1;
  for I := LSpace1 + 1 to LLineEnd - 1 do
    if ABuf[I] = SP then begin LSpace2 := I; Break; end;
  if LSpace2 < 0 then LSpace2 := LLineEnd;

  // Only 3 string allocations: method, path, query
  AMethod := BufToStr(0, LSpace1);

  LQPos := -1;
  for I := LSpace1 + 1 to LSpace2 - 1 do
    if ABuf[I] = Byte('?') then begin LQPos := I; Break; end;
  if LQPos > 0 then
  begin
    APath        := BufToStr(LSpace1 + 1, LQPos - LSpace1 - 1);
    AQueryString := BufToStr(LQPos + 1, LSpace2 - LQPos - 1);
  end
  else
  begin
    APath        := BufToStr(LSpace1 + 1, LSpace2 - LSpace1 - 1);
    AQueryString := '';
  end;

  // HTTP version detection
  LIsHttp11 := False;
  if (LLineEnd - LSpace2 - 1) = 8 then
    LIsHttp11 :=
      (ABuf[LSpace2+1] = Byte('H')) and (ABuf[LSpace2+2] = Byte('T')) and
      (ABuf[LSpace2+3] = Byte('T')) and (ABuf[LSpace2+4] = Byte('P')) and
      (ABuf[LSpace2+5] = Byte('/')) and (ABuf[LSpace2+6] = Byte('1')) and
      (ABuf[LSpace2+7] = Byte('.')) and (ABuf[LSpace2+8] = Byte('1'));
  AKeepAlive := LIsHttp11;

  // Store header byte range for lazy materialization
  AHdrStart := LLineEnd + 2;
  AHdrEnd   := LHdrEnd;

  // Scan headers by BYTES only — detect Content-Length, Connection,
  // Transfer-Encoding without any string allocation
  LCL        := 0;
  LThisCL    := 0;
  LCLSeen    := False;
  LTEPresent := False;
  LIsChunked := False;
  LHdrCount  := 0;
  LLineStart := LLineEnd + 2;
  while LLineStart < LHdrEnd do
  begin
    // Reject rather than silently ignore when the header count is exceeded.
    if LHdrCount >= CMaxHeaderCount then begin ABadRequest := True; Exit; end;

    // Find end of line
    LLineEnd := -1;
    LColonPos := -1;
    for I := LLineStart to LHdrEnd do
    begin
      case GLUT[ABuf[I]] of
        BF_COLON: if LColonPos < 0 then LColonPos := I;
        BF_CR:
          if ABuf[I+1] = LF then begin LLineEnd := I; Break; end;
      end;
    end;
    if LLineEnd < 0 then Break;
    if LLineEnd = LLineStart then
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    // Reject obsolete line folding (obs-fold) — RFC 7230 §3.2.4 (issue #162).
    if (GLUT[ABuf[LLineStart]] and BF_OWS) <> 0 then
    begin ABadRequest := True; Exit; end;

    if LColonPos < 0 then
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    // Reject whitespace before the colon ("Name : value") (issue #160).
    if (LColonPos > LLineStart) and
       ((GLUT[ABuf[LColonPos - 1]] and BF_OWS) <> 0) then
    begin ABadRequest := True; Exit; end;

    Inc(LHdrCount);

    // Skip OWS
    LValStart := LColonPos + 1;
    while (LValStart < LLineEnd) and
          ((GLUT[ABuf[LValStart]] and BF_OWS) <> 0) do
      Inc(LValStart);
    LValLen := LLineEnd - LValStart;

    case LookupHeaderId(@ABuf[LLineStart], LColonPos - LLineStart) of
      hiContentLength:
        begin
          // Validate; reject conflicting duplicate Content-Length (#158).
          if not _ParseContentLengthBytes(ABuf, LValStart, LLineEnd, LThisCL) then
          begin ABadRequest := True; Exit; end;
          if LCLSeen and (LThisCL <> LCL) then
          begin ABadRequest := True; Exit; end;
          LCL     := LThisCL;
          LCLSeen := True;
        end;
      hiConnection:
        begin
          // Parity with the Full parser: an explicit "keep-alive" enables
          // keep-alive on HTTP/1.0 (default = close), and "close" disables it
          // on HTTP/1.1 (default = keep-alive).
          if LValLen >= 10 then
            for I := LValStart to LLineEnd - 10 do
              if (ABuf[I]   or $20 = Ord('k')) and (ABuf[I+1] or $20 = Ord('e')) and
                 (ABuf[I+2] or $20 = Ord('e')) and (ABuf[I+3] or $20 = Ord('p')) and
                 (ABuf[I+4]       = Ord('-'))  and (ABuf[I+5] or $20 = Ord('a')) and
                 (ABuf[I+6] or $20 = Ord('l')) and (ABuf[I+7] or $20 = Ord('i')) and
                 (ABuf[I+8] or $20 = Ord('v')) and (ABuf[I+9] or $20 = Ord('e')) then
              begin AKeepAlive := True; Break; end;
          if LValLen >= 5 then
            for I := LValStart to LLineEnd - 5 do
              if (ABuf[I] or $20 = Ord('c')) and (ABuf[I+1] or $20 = Ord('l')) and
                 (ABuf[I+2] or $20 = Ord('o')) and (ABuf[I+3] or $20 = Ord('s')) and
                 (ABuf[I+4] or $20 = Ord('e')) then
              begin AKeepAlive := False; Break; end;
        end;
      hiTransferEncoding:
        begin
          // Require the coding to be exactly "chunked"; anything else leaves
          // the message length undeterminable (issue #160).
          LTEPresent := True;
          LIsChunked := _BytesEqualCI(ABuf, LValStart, LLineEnd, 'chunked');
        end;
    end;

    LLineStart := LLineEnd + 2;
  end;

  // TE present but not chunked → reject (RFC 7230 §3.3.3) (issue #160).
  if LTEPresent and not LIsChunked then
  begin ABadRequest := True; Exit; end;

  // Request smuggling check — CL presence (even "0") conflicts with chunked.
  if HasRequestSmuggling(LCLSeen, LIsChunked) then
  begin ABadRequest := True; Exit; end;

  LBodyStart := LHdrEnd + 4;

  if LIsChunked then
  begin
    if not DecodeHTTP1Chunked(@ABuf[LBodyStart],
         ABufLen - LBodyStart, AMaxBodySize,
         LChunkBody, LChunkBytes, LChunkBad) then
    begin
      ABadRequest := LChunkBad;
      Exit;
    end;
    ARawBody  := LChunkBody;
    LConsumed := LBodyStart + LChunkBytes;
  end
  else
  begin
    if LCLSeen and (LCL > AMaxBodySize) then
    begin ABadRequest := True; Exit; end;
    if LCL > 0 then
    begin
      if ABufLen - LBodyStart < LCL then Exit;
      SetLength(ARawBody, LCL);
      Move(ABuf[LBodyStart], ARawBody[0], LCL);
    end
    else
      SetLength(ARawBody, 0);
    LConsumed := LBodyStart + Integer(LCL);
  end;

  AConsumed := LConsumed;
  Result    := True;
end;

// ---------------------------------------------------------------------------
// MaterializeHeaders — on-demand string allocation for headers
// ---------------------------------------------------------------------------

function MaterializeHeaders(const ABuf: TBytes;
  AHdrStart, AHdrEnd: Integer): TArray<TPair<string,string>>;
var
  I, LLineStart, LLineEnd, LColonPos, LValStart, LCount: Integer;
begin
  SetLength(Result, CMaxHeaderCount);
  LCount := 0;
  LLineStart := AHdrStart;
  while (LLineStart < AHdrEnd) and (LCount < CMaxHeaderCount) do
  begin
    LLineEnd := -1;
    LColonPos := -1;
    for I := LLineStart to AHdrEnd do
    begin
      case GLUT[ABuf[I]] of
        BF_COLON: if LColonPos < 0 then LColonPos := I;
        BF_CR:
          if ABuf[I+1] = $0A then begin LLineEnd := I; Break; end;
      end;
    end;
    if LLineEnd < 0 then Break;
    if (LLineEnd = LLineStart) or (LColonPos < 0) then
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;
    LValStart := LColonPos + 1;
    while (LValStart < LLineEnd) and
          ((GLUT[ABuf[LValStart]] and BF_OWS) <> 0) do
      Inc(LValStart);

    Result[LCount] := TPair<string,string>.Create(
      _FastBufToStr(ABuf, LLineStart, LColonPos - LLineStart),
      _FastBufToStr(ABuf, LValStart, LLineEnd - LValStart));
    Inc(LCount);
    LLineStart := LLineEnd + 2;
  end;
  SetLength(Result, LCount);
end;

initialization
  _InitLUT;
  _InitHeaderHash;

end.
