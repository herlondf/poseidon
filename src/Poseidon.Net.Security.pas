unit Poseidon.Net.Security;

// Pure validation functions for HTTP security checks.
// No I/O, no server state — fully unit-testable in isolation.
//
// S-1  IsMethodAllowed  — enforces an allowlist of HTTP verbs
// S-2  IsPathSafe       — rejects path-traversal sequences
// S-3  StripCRLF        — removes CR/LF/NUL from response header values
// S-4  HasRequestSmuggling — detects Content-Length + chunked conflict (RFC 7230 §3.3.3)
// Metrics  IsIPInCIDR   — checks whether a remote address string falls inside a CIDR block

interface

uses
  System.SysUtils;

// S-1: Returns True when AMethod is in AAllowed (case-insensitive).
// When AAllowed is empty every method is accepted (backward-compatible default).
function IsMethodAllowed(const AMethod: string;
  const AAllowed: TArray<string>): Boolean;

// S-2: Returns True when APath contains no directory-traversal sequences.
// Rejects: "..", "%2e%2e", backslash, NUL bytes.
function IsPathSafe(const APath: string): Boolean;

// S-3: Returns AValue with all CR (#13), LF (#10) and NUL (#0) removed.
// Apply to every response header value supplied by the application handler.
function StripCRLF(const AValue: string): string;

// S-4: Returns True when both Content-Length and Transfer-Encoding: chunked are
// present in the same request — a classic request-smuggling vector (RFC 7230 §3.3.3).
// ACLPresent: whether a Content-Length header was found.
// AIsChunked:  whether Transfer-Encoding contains "chunked".
function HasRequestSmuggling(ACLPresent: Boolean; AIsChunked: Boolean): Boolean;

// Returns True when ARemoteAddr (format "IP:port" or bare "IP") falls inside
// the IPv4 CIDR block ACIDR (e.g. "10.0.0.0/8", "192.168.1.0/24").
// Returns True on any parse error so as not to block scraping silently.
function IsIPInCIDR(const ARemoteAddr, ACIDR: string): Boolean;

implementation

function IsMethodAllowed(const AMethod: string;
  const AAllowed: TArray<string>): Boolean;
var
  I: Integer;
begin
  if Length(AAllowed) = 0 then
  begin
    Result := True;
    Exit;
  end;
  for I := 0 to High(AAllowed) do
    if SameText(AMethod, AAllowed[I]) then
    begin
      Result := True;
      Exit;
    end;
  Result := False;
end;

function IsPathSafe(const APath: string): Boolean;
var
  LLower: string;
begin
  // NUL byte
  if Pos(#0, APath) > 0 then
  begin
    Result := False;
    Exit;
  end;
  // Backslash (Windows path separator used in traversal)
  if Pos('\', APath) > 0 then
  begin
    Result := False;
    Exit;
  end;
  LLower := LowerCase(APath);
  // URL-encoded dot-dot
  if Pos('%2e%2e', LLower) > 0 then
  begin
    Result := False;
    Exit;
  end;
  // Traversal segments: /../ inside path, /.. at end, ../ at start, or bare ..
  if Pos('/../', LLower) > 0 then
  begin
    Result := False;
    Exit;
  end;
  if (Length(LLower) >= 3) and
     (LLower[Length(LLower) - 2] = '/') and
     (LLower[Length(LLower) - 1] = '.') and
     (LLower[Length(LLower)]     = '.') then
  begin
    Result := False;
    Exit;
  end;
  if (Length(LLower) >= 3) and
     (LLower[1] = '.') and
     (LLower[2] = '.') and
     (LLower[3] = '/') then
  begin
    Result := False;
    Exit;
  end;
  if LLower = '..' then
  begin
    Result := False;
    Exit;
  end;
  Result := True;
end;

function StripCRLF(const AValue: string): string;
begin
  Result := StringReplace(AValue, #13, '', [rfReplaceAll]);
  Result := StringReplace(Result, #10, '', [rfReplaceAll]);
  Result := StringReplace(Result, #0,  '', [rfReplaceAll]);
end;

function HasRequestSmuggling(ACLPresent: Boolean; AIsChunked: Boolean): Boolean;
begin
  Result := ACLPresent and AIsChunked;
end;

function IsIPInCIDR(const ARemoteAddr, ACIDR: string): Boolean;
var
  LSlash:    Integer;
  LPrefix:   Integer;
  LCIDRHost: string;
  LIPStr:    string;
  LColonPos: Integer;
  LMask:     LongWord;
  LIPParts:  TArray<string>;
  LNParts:   TArray<string>;
  LIPNum:    LongWord;
  LNetNum:   LongWord;
  LByte:     LongWord;
  I:         Integer;
begin
  Result := True;  // fail-open: parse errors do not block scraping
  try
    // Strip port from ARemoteAddr ("1.2.3.4:port" → "1.2.3.4")
    LColonPos := ARemoteAddr.LastDelimiter(':');
    if LColonPos > 0 then
      LIPStr := Copy(ARemoteAddr, 1, LColonPos - 1)
    else
      LIPStr := ARemoteAddr;
    // Remove brackets from IPv6 literal "[::1]" — CIDR check only works for IPv4
    LIPStr := StringReplace(LIPStr, '[', '', []);
    LIPStr := StringReplace(LIPStr, ']', '', []);

    // Parse CIDR "a.b.c.d/prefix"
    LSlash := Pos('/', ACIDR);
    if LSlash <= 0 then Exit;  // not a valid CIDR — fail-open
    LCIDRHost := Copy(ACIDR, 1, LSlash - 1);
    LPrefix   := StrToIntDef(Copy(ACIDR, LSlash + 1, MaxInt), -1);
    if (LPrefix < 0) or (LPrefix > 32) then Exit;

    // Convert dotted-decimal to 32-bit big-endian
    LIPParts := LIPStr.Split(['.']);
    LNParts  := LCIDRHost.Split(['.']);
    if (Length(LIPParts) <> 4) or (Length(LNParts) <> 4) then Exit;

    LIPNum  := 0;
    LNetNum := 0;
    for I := 0 to 3 do
    begin
      LByte   := StrToIntDef(LIPParts[I], 256);
      if LByte > 255 then Exit;
      LIPNum  := (LIPNum  shl 8) or LByte;
      LByte   := StrToIntDef(LNParts[I],  256);
      if LByte > 255 then Exit;
      LNetNum := (LNetNum shl 8) or LByte;
    end;

    if LPrefix = 0 then
      LMask := 0
    else
      LMask := not ((1 shl (32 - LPrefix)) - 1);

    Result := (LIPNum and LMask) = (LNetNum and LMask);
  except
    Result := True;  // never raise — fail-open
  end;
end;

end.
