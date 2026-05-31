unit Poseidon.Net.ResponseBuilder;

// Pre-encoded HTTP/1.1 response builder (SRP refactoring R-3).
//
// Encapsulates the W3-optimised response assembly logic extracted from
// TPoseidonNativeServer._BuildResponse.
//
// All global byte-arrays are pre-encoded once at unit initialization, so the
// hot path consists only of Move() calls — no UTF-16→ASCII conversion per
// request.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections;

// Assembles a complete HTTP/1.1 response into a single TBytes:
//   Status-Line CRLF
//   Content-Type: ... CRLF
//   Content-Length: ... CRLF
//   Connection: keep-alive|close CRLF
//   [AExtra headers] [security headers] [Server header]
//   CRLF
//   ABody
function BuildHTTPResponse(
  AStatus:          Integer;
  const AContentType: string;
  const ABody:      TBytes;
  AKeepAlive:       Boolean;
  const AExtra:     TArray<TPair<string,string>>;
  ASecureHeaders:   Boolean;
  const AServerBanner: string): TBytes;

// P-4: Pool-backed variant of BuildHTTPResponse.
// Returns a TBytes acquired from TBufferPool (may be larger than AActualLen).
// AActualLen is the number of valid response bytes in the returned buffer.
// Caller must pass AActualLen to the send function and call
// TBufferPool.Release on the returned buffer after the send completes.
function BuildHTTPResponsePooled(
  AStatus:          Integer;
  const AContentType: string;
  const ABody:      TBytes;
  AKeepAlive:       Boolean;
  const AExtra:     TArray<TPair<string,string>>;
  ASecureHeaders:   Boolean;
  const AServerBanner: string;
  out AActualLen:   Integer): TBytes;

// Pre-encoded default error body: {"error":"Internal Server Error"}
// Use as initial value in the dispatch loop before calling the user handler.
function DefaultErrorBody: TBytes;

implementation

uses
  Poseidon.Net.Pool.Buffer;

// ---------------------------------------------------------------------------
// Pre-encoded response fragments — initialized once in `initialization`.
// ---------------------------------------------------------------------------
var
  G_STATUS_200, G_STATUS_201, G_STATUS_204,
  G_STATUS_301, G_STATUS_302, G_STATUS_303, G_STATUS_304,
  G_STATUS_400, G_STATUS_401, G_STATUS_403, G_STATUS_404, G_STATUS_405,
  G_STATUS_409, G_STATUS_413, G_STATUS_422, G_STATUS_429,
  G_STATUS_500, G_STATUS_503: TBytes;
  G_CT_PREFIX:   TBytes;   // 'Content-Type: '
  G_CL_PREFIX:   TBytes;   // 'Content-Length: '
  G_CONN_KA:     TBytes;   // 'Connection: keep-alive'#13#10
  G_CONN_CLOSE:  TBytes;   // 'Connection: close'#13#10
  G_CRLF:        TBytes;   // #13#10
  // Pre-encoded common Content-Type values — Move()'d into Result when the
  // response uses one of these (~95% of REST APIs hit application/json).
  G_CT_JSON, G_CT_TEXT, G_CT_HTML, G_CT_PROBLEM, G_CT_FORM, G_CT_OCTET: TBytes;
  G_DEFAULT_ERROR_BODY: TBytes;

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

// S-3: Sanitize a response header value by truncating at the first CR/LF/NUL.
// Truncating (rather than stripping) ensures injected text never reaches the
// wire — e.g. "value\r\nX-Evil: hdr" → "value", not "valueX-Evil: hdr".
function _SanitizeHeaderValue(const AValue: string): string;
var
  LPos: Integer;
begin
  for LPos := 1 to Length(AValue) do
    if (AValue[LPos] = #13) or (AValue[LPos] = #10) or (AValue[LPos] = #0) then
    begin
      Result := Copy(AValue, 1, LPos - 1);
      Exit;
    end;
  Result := AValue;
end;

function DigitCount(AValue: Integer): Integer; inline;
begin
  if AValue < 10 then Result := 1
  else if AValue < 100 then Result := 2
  else if AValue < 1000 then Result := 3
  else if AValue < 10000 then Result := 4
  else if AValue < 100000 then Result := 5
  else if AValue < 1000000 then Result := 6
  else if AValue < 10000000 then Result := 7
  else if AValue < 100000000 then Result := 8
  else if AValue < 1000000000 then Result := 9
  else Result := 10;
end;

procedure WriteIntToBuffer(var ABuf: TBytes; APos: Integer; AValue: Integer);
// Writes AValue as ASCII digits into ABuf starting at APos. Caller must
// have allocated enough space (see DigitCount). No bounds check.
var
  LScratch: array[0..11] of Byte;
  LLen, I, LV: Integer;
begin
  if AValue = 0 then
  begin
    ABuf[APos] := $30;  // '0'
    Exit;
  end;
  LLen := 0;
  LV   := AValue;
  while LV > 0 do
  begin
    LScratch[LLen] := Byte($30 + (LV mod 10));
    Inc(LLen);
    LV := LV div 10;
  end;
  for I := 0 to LLen - 1 do
    ABuf[APos + I] := LScratch[LLen - 1 - I];
end;

function GetContentTypeValueBytes(const AContentType: string;
  out AAlloc: Boolean): TBytes;
// Returns pre-encoded bytes for the given content-type, or builds on the fly.
// AAlloc = True when the returned TBytes was freshly allocated.
begin
  AAlloc := False;
  if      AContentType = 'application/json'         then Result := G_CT_JSON
  else if AContentType = 'text/plain'               then Result := G_CT_TEXT
  else if AContentType = 'text/html'                then Result := G_CT_HTML
  else if AContentType = 'application/problem+json' then Result := G_CT_PROBLEM
  else if AContentType = 'application/x-www-form-urlencoded' then Result := G_CT_FORM
  else if AContentType = 'application/octet-stream' then Result := G_CT_OCTET
  else
  begin
    Result := TEncoding.ASCII.GetBytes(AContentType);
    AAlloc := True;
  end;
end;

function GetStatusLineBytes(AStatus: Integer): TBytes;
begin
  case AStatus of
    200: Result := G_STATUS_200;
    201: Result := G_STATUS_201;
    204: Result := G_STATUS_204;
    301: Result := G_STATUS_301;
    302: Result := G_STATUS_302;
    303: Result := G_STATUS_303;
    304: Result := G_STATUS_304;
    400: Result := G_STATUS_400;
    401: Result := G_STATUS_401;
    403: Result := G_STATUS_403;
    404: Result := G_STATUS_404;
    405: Result := G_STATUS_405;
    409: Result := G_STATUS_409;
    413: Result := G_STATUS_413;
    422: Result := G_STATUS_422;
    429: Result := G_STATUS_429;
    500: Result := G_STATUS_500;
    503: Result := G_STATUS_503;
  else
    // Slow path for uncommon codes — build inline.
    Result := TEncoding.ASCII.GetBytes(
      'HTTP/1.1 ' + IntToStr(AStatus) + ' Unknown'#13#10);
  end;
end;

// ---------------------------------------------------------------------------
// Internal core: writes the response into ABuf starting at offset 0.
// ABuf must be pre-allocated with Length >= result of the sizing pass.
// Returns the number of bytes written.
// ---------------------------------------------------------------------------

function _BuildCore(ABuf: TBytes; AStatus: Integer;
  const AContentType: string; const ABody: TBytes; AKeepAlive: Boolean;
  const AExtra: TArray<TPair<string,string>>;
  ASecureHeaders: Boolean; const AServerBanner: string): Integer;
var
  LStatusBytes: TBytes;
  LConnBytes:   TBytes;
  LCTValue:     TBytes;
  LCTAlloced:   Boolean;
  LExtraStr:    string;
  LBodyLen, LCLLen, LExtraLen: Integer;
  LPos:         Integer;
  I:            Integer;
begin
  LStatusBytes := GetStatusLineBytes(AStatus);
  if AKeepAlive then LConnBytes := G_CONN_KA
  else               LConnBytes := G_CONN_CLOSE;

  LCTValue := GetContentTypeValueBytes(AContentType, LCTAlloced);
  LBodyLen := Length(ABody);
  LCLLen   := DigitCount(LBodyLen);

  LExtraStr := '';
  for I := 0 to High(AExtra) do
    // S-3: truncate header values at first CR/LF/NUL to prevent header injection
    LExtraStr := LExtraStr + AExtra[I].Key + ': ' +
      _SanitizeHeaderValue(AExtra[I].Value) + #13#10;
  // A-1: opt-in security headers
  if ASecureHeaders then
    LExtraStr := LExtraStr
      + 'X-Content-Type-Options: nosniff'#13#10
      + 'X-Frame-Options: DENY'#13#10
      + 'Referrer-Policy: strict-origin-when-cross-origin'#13#10;
  // A-2: configurable Server: banner
  if AServerBanner <> '' then
    LExtraStr := LExtraStr + 'Server: ' + AServerBanner + #13#10;
  LExtraLen := Length(LExtraStr);

  LPos := 0;

  Move(LStatusBytes[0], ABuf[LPos], Length(LStatusBytes));
  Inc(LPos, Length(LStatusBytes));

  Move(G_CT_PREFIX[0], ABuf[LPos], Length(G_CT_PREFIX));
  Inc(LPos, Length(G_CT_PREFIX));
  if Length(LCTValue) > 0 then
  begin
    Move(LCTValue[0], ABuf[LPos], Length(LCTValue));
    Inc(LPos, Length(LCTValue));
  end;
  ABuf[LPos] := $0D; ABuf[LPos + 1] := $0A; Inc(LPos, 2);

  Move(G_CL_PREFIX[0], ABuf[LPos], Length(G_CL_PREFIX));
  Inc(LPos, Length(G_CL_PREFIX));
  WriteIntToBuffer(ABuf, LPos, LBodyLen);
  Inc(LPos, LCLLen);
  ABuf[LPos] := $0D; ABuf[LPos + 1] := $0A; Inc(LPos, 2);

  Move(LConnBytes[0], ABuf[LPos], Length(LConnBytes));
  Inc(LPos, Length(LConnBytes));

  if LExtraLen > 0 then
  begin
    TEncoding.ASCII.GetBytes(LExtraStr, 1, LExtraLen, ABuf, LPos);
    Inc(LPos, LExtraLen);
  end;

  Move(G_CRLF[0], ABuf[LPos], Length(G_CRLF));
  Inc(LPos, Length(G_CRLF));

  if LBodyLen > 0 then
    Move(ABody[0], ABuf[LPos], LBodyLen);

  Result := LPos + LBodyLen;
end;

function _CalcTotal(AStatus: Integer; const AContentType: string;
  const ABody: TBytes; AKeepAlive: Boolean;
  const AExtra: TArray<TPair<string,string>>;
  ASecureHeaders: Boolean; const AServerBanner: string): Integer;
var
  LStatusBytes: TBytes;
  LConnBytes:   TBytes;
  LCTValue:     TBytes;
  LCTAlloced:   Boolean;
  LExtraStr:    string;
  LBodyLen, LCLLen, LExtraLen: Integer;
  I:            Integer;
begin
  LStatusBytes := GetStatusLineBytes(AStatus);
  if AKeepAlive then LConnBytes := G_CONN_KA
  else               LConnBytes := G_CONN_CLOSE;
  LCTValue := GetContentTypeValueBytes(AContentType, LCTAlloced);
  LBodyLen := Length(ABody);
  LCLLen   := DigitCount(LBodyLen);
  LExtraStr := '';
  for I := 0 to High(AExtra) do
    LExtraStr := LExtraStr + AExtra[I].Key + ': ' +
      _SanitizeHeaderValue(AExtra[I].Value) + #13#10;
  if ASecureHeaders then
    LExtraStr := LExtraStr
      + 'X-Content-Type-Options: nosniff'#13#10
      + 'X-Frame-Options: DENY'#13#10
      + 'Referrer-Policy: strict-origin-when-cross-origin'#13#10;
  if AServerBanner <> '' then
    LExtraStr := LExtraStr + 'Server: ' + AServerBanner + #13#10;
  LExtraLen := Length(LExtraStr);
  Result := Length(LStatusBytes)
          + Length(G_CT_PREFIX) + Length(LCTValue) + 2
          + Length(G_CL_PREFIX) + LCLLen + 2
          + Length(LConnBytes)
          + LExtraLen
          + Length(G_CRLF)
          + LBodyLen;
end;

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

function BuildHTTPResponse(AStatus: Integer;
  const AContentType: string; const ABody: TBytes; AKeepAlive: Boolean;
  const AExtra: TArray<TPair<string,string>>;
  ASecureHeaders: Boolean; const AServerBanner: string): TBytes;
// Hot path: pre-cached fragments are Move()'d into Result.
var
  LTotal: Integer;
begin
  LTotal := _CalcTotal(AStatus, AContentType, ABody, AKeepAlive,
    AExtra, ASecureHeaders, AServerBanner);
  SetLength(Result, LTotal);
  _BuildCore(Result, AStatus, AContentType, ABody, AKeepAlive,
    AExtra, ASecureHeaders, AServerBanner);
end;

function BuildHTTPResponsePooled(AStatus: Integer;
  const AContentType: string; const ABody: TBytes; AKeepAlive: Boolean;
  const AExtra: TArray<TPair<string,string>>;
  ASecureHeaders: Boolean; const AServerBanner: string;
  out AActualLen: Integer): TBytes;
// P-4: Acquires a buffer from TBufferPool instead of heap-allocating.
// The returned TBytes may be larger than AActualLen — caller must pass
// AActualLen to the send layer and release the buffer after send.
var
  LTotal: Integer;
begin
  LTotal := _CalcTotal(AStatus, AContentType, ABody, AKeepAlive,
    AExtra, ASecureHeaders, AServerBanner);
  Result := TBufferPool.Acquire(LTotal);
  AActualLen := _BuildCore(Result, AStatus, AContentType, ABody, AKeepAlive,
    AExtra, ASecureHeaders, AServerBanner);
end;

function DefaultErrorBody: TBytes;
begin
  Result := G_DEFAULT_ERROR_BODY;
end;

initialization
  // W3: pre-encode common HTTP response fragments once.
  G_STATUS_200 := TEncoding.ASCII.GetBytes('HTTP/1.1 200 OK'#13#10);
  G_STATUS_201 := TEncoding.ASCII.GetBytes('HTTP/1.1 201 Created'#13#10);
  G_STATUS_204 := TEncoding.ASCII.GetBytes('HTTP/1.1 204 No Content'#13#10);
  G_STATUS_301 := TEncoding.ASCII.GetBytes('HTTP/1.1 301 Moved Permanently'#13#10);
  G_STATUS_302 := TEncoding.ASCII.GetBytes('HTTP/1.1 302 Found'#13#10);
  G_STATUS_303 := TEncoding.ASCII.GetBytes('HTTP/1.1 303 See Other'#13#10);
  G_STATUS_304 := TEncoding.ASCII.GetBytes('HTTP/1.1 304 Not Modified'#13#10);
  G_STATUS_400 := TEncoding.ASCII.GetBytes('HTTP/1.1 400 Bad Request'#13#10);
  G_STATUS_401 := TEncoding.ASCII.GetBytes('HTTP/1.1 401 Unauthorized'#13#10);
  G_STATUS_403 := TEncoding.ASCII.GetBytes('HTTP/1.1 403 Forbidden'#13#10);
  G_STATUS_404 := TEncoding.ASCII.GetBytes('HTTP/1.1 404 Not Found'#13#10);
  G_STATUS_405 := TEncoding.ASCII.GetBytes('HTTP/1.1 405 Method Not Allowed'#13#10);
  G_STATUS_409 := TEncoding.ASCII.GetBytes('HTTP/1.1 409 Conflict'#13#10);
  G_STATUS_413 := TEncoding.ASCII.GetBytes('HTTP/1.1 413 Payload Too Large'#13#10);
  G_STATUS_422 := TEncoding.ASCII.GetBytes('HTTP/1.1 422 Unprocessable Entity'#13#10);
  G_STATUS_429 := TEncoding.ASCII.GetBytes('HTTP/1.1 429 Too Many Requests'#13#10);
  G_STATUS_500 := TEncoding.ASCII.GetBytes('HTTP/1.1 500 Internal Server Error'#13#10);
  G_STATUS_503 := TEncoding.ASCII.GetBytes('HTTP/1.1 503 Service Unavailable'#13#10);
  G_CT_PREFIX  := TEncoding.ASCII.GetBytes('Content-Type: ');
  G_CL_PREFIX  := TEncoding.ASCII.GetBytes('Content-Length: ');
  G_CONN_KA    := TEncoding.ASCII.GetBytes('Connection: keep-alive'#13#10);
  G_CONN_CLOSE := TEncoding.ASCII.GetBytes('Connection: close'#13#10);
  G_CRLF       := TEncoding.ASCII.GetBytes(#13#10);
  // W3+: pre-encode common content-type values
  G_CT_JSON    := TEncoding.ASCII.GetBytes('application/json');
  G_CT_TEXT    := TEncoding.ASCII.GetBytes('text/plain');
  G_CT_HTML    := TEncoding.ASCII.GetBytes('text/html');
  G_CT_PROBLEM := TEncoding.ASCII.GetBytes('application/problem+json');
  G_CT_FORM    := TEncoding.ASCII.GetBytes('application/x-www-form-urlencoded');
  G_CT_OCTET   := TEncoding.ASCII.GetBytes('application/octet-stream');
  G_DEFAULT_ERROR_BODY := TEncoding.UTF8.GetBytes('{"error":"Internal Server Error"}');

end.
