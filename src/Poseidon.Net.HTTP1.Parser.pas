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
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
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
    if LLen > 16 then begin AMalformed := True; Exit; end;  // hex size cap

    SetLength(LSize, LLen);
    Move(LBytes[LPos], LSize[1], LLen);

    LSemi := 0;
    for I := 1 to LLen do
      if LSize[I] = ';' then begin LSemi := I; Break; end;
    if LSemi > 0 then SetLength(LSize, LSemi - 1);

    if not TryStrToInt64('$' + string(LSize), LChunk) or (LChunk < 0) then
    begin
      AMalformed := True;
      Exit;
    end;

    if LChunk = 0 then
    begin
      // Last chunk — consume optional trailing CRLF
      LPos := LCRLFP + 2;
      I := LPos;
      while I < ABufLen - 1 do
      begin
        if (LBytes[I] = $0D) and (LBytes[I + 1] = $0A) then
        begin
          Inc(I, 2);
          LPos := I;
          Break;
        end;
        Inc(I);
      end;
      AConsumed := LPos;
      Result    := True;
      Exit;
    end;

    if LChunk > AMaxBodySize then begin AMalformed := True; Exit; end;

    LDataStart := LCRLFP + 2;
    if Int64(LDataStart) + LChunk + 2 > Int64(ABufLen) then Exit;

    LOldLen := Length(ABody);
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
  MAX_HEADER_COUNT = 100;
  SP               = $20;
  HT               = $09;
  CR               = $0D;
  LF               = $0A;

  function BufToStr(AStart, ALen: Integer): string;
  begin
    if ALen <= 0 then Result := ''
    else Result := TEncoding.ASCII.GetString(ABuf, AStart, ALen);
  end;

var
  I:             Integer;
  LHdrEnd:       Integer;
  LScanEnd:      Integer;
  LLineStart:    Integer;
  LLineEnd:      Integer;
  LSpace1:       Integer;
  LSpace2:       Integer;
  LColonPos:     Integer;
  LQPos:         Integer;
  LValStart:     Integer;
  LName, LValue: string;
  LCL:           Int64;
  LBodyStart:    Integer;
  LConsumed:     Integer;
  LHdrCount:     Integer;
  LIsHttp11:     Boolean;
  LIsChunked:    Boolean;
  LChunkBody:    TBytes;
  LChunkBytes:   Integer;
  LChunkBad:     Boolean;
begin
  Result      := False;
  ABadRequest := False;
  AConsumed   := 0;

  // Scan for CRLFCRLF (end of headers)
  LHdrEnd  := -1;
  LScanEnd := ABufLen - 4;
  if LScanEnd > AMaxHeaderSize then LScanEnd := AMaxHeaderSize;
  for I := 0 to LScanEnd do
    if (ABuf[I]   = CR) and (ABuf[I+1] = LF) and
       (ABuf[I+2] = CR) and (ABuf[I+3] = LF) then
    begin
      LHdrEnd := I;
      Break;
    end;

  if LHdrEnd < 0 then
  begin
    if ABufLen > AMaxHeaderSize then ABadRequest := True;
    Exit;
  end;

  // --- Parse request line: METHOD SP PATH[?QUERY] [SP HTTP/x.y] CRLF ---
  LLineEnd := -1;
  for I := 0 to LHdrEnd - 1 do
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
  LIsChunked := False;
  LHdrCount  := 0;
  SetLength(AHeaders, MAX_HEADER_COUNT);

  LLineStart := LLineEnd + 2;
  while LLineStart < LHdrEnd do
  begin
    if LHdrCount >= MAX_HEADER_COUNT then Break;

    LLineEnd := -1;
    for I := LLineStart to LHdrEnd do
      if (ABuf[I] = CR) and (ABuf[I+1] = LF) then
      begin
        LLineEnd := I;
        Break;
      end;
    if LLineEnd < 0 then Break;
    if LLineEnd = LLineStart then  // empty line — skip
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    LColonPos := -1;
    for I := LLineStart to LLineEnd - 1 do
      if ABuf[I] = Byte(':') then begin LColonPos := I; Break; end;
    if LColonPos < 0 then
    begin
      LLineStart := LLineEnd + 2;
      Continue;
    end;

    // Skip OWS after colon
    LValStart := LColonPos + 1;
    while (LValStart < LLineEnd) and
          ((ABuf[LValStart] = SP) or (ABuf[LValStart] = HT)) do
      Inc(LValStart);

    LName  := BufToStr(LLineStart, LColonPos - LLineStart);
    LValue := BufToStr(LValStart,  LLineEnd  - LValStart);

    AHeaders[LHdrCount] := TPair<string,string>.Create(LName, LValue);
    Inc(LHdrCount);

    if SameText(LName, 'Connection') then
    begin
      if Pos('keep-alive', LowerCase(LValue)) > 0 then AKeepAlive := True;
      if Pos('close',      LowerCase(LValue)) > 0 then AKeepAlive := False;
    end
    else if SameText(LName, 'Content-Length') then
      LCL := StrToInt64Def(LValue, 0)
    else if SameText(LName, 'Transfer-Encoding') then
      LIsChunked := Pos('chunked', LowerCase(LValue)) > 0;

    LLineStart := LLineEnd + 2;
  end;
  SetLength(AHeaders, LHdrCount);

  // S-4: request smuggling — Content-Length + Transfer-Encoding: chunked (RFC 7230 §3.3.3)
  if HasRequestSmuggling(LCL > 0, LIsChunked) then
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

end.
