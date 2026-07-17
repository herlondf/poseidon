unit Poseidon.Compat;

// Free Pascal compatibility layer for Poseidon (issue #5).
//
// Delphi's System.SysUtils ships a `TStringHelper` record helper for `string`
// with a rich fluent API (`.Split`, `.LastDelimiter`, ...). FPC's RTL does not
// provide these under the same names, so code that calls them fails to compile
// with "Illegal qualifier".
//
// This unit supplies the (small) subset of that API the Poseidon core relies
// on, with semantics matching Delphi exactly, and is pulled into the FPC branch
// of a unit's `uses` clause. It is a no-op under Delphi (the whole body is
// guarded by {$IFDEF FPC}), so it never affects the Delphi build.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$MODESWITCH TYPEHELPERS}
{$ENDIF}

interface

{$IFDEF FPC}
uses
  {$IFDEF MSWINDOWS}
  Windows,
  {$ENDIF}
  SysUtils,
  Classes,
  sha1,
  RegExpr;

type
  // Delphi's System.NetEncoding.TNetEncoding.URL.Decode does percent-decoding
  // with UTF-8. The Poseidon routing layer only needs URL.Decode; this mirrors
  // it via a nested record so `TNetEncoding.URL.Decode(s)` compiles unchanged.
  TPoseidonURLEncoding = record
    function Decode(const AInput: string): string;
  end;

  // Mirrors System.NetEncoding.TBase64Encoding.EncodeBytesToString — used by the
  // WebSocket handshake (Sec-WebSocket-Accept = base64(SHA1(...))). Standard
  // RFC 4648 base64 with '=' padding.
  TPoseidonBase64Encoding = record
    function EncodeBytesToString(const AInput: TBytes): string;
  end;

  TNetEncoding = record
    class function URL: TPoseidonURLEncoding; static;
    class function Base64: TPoseidonBase64Encoding; static;
  end;

  // Delphi's System.RegularExpressions.TRegEx exposes a static IsMatch; FPC ships
  // RegExpr.TRegExpr (an instance API with different semantics). This record
  // mirrors the tiny static slice Poseidon.Validation relies on. IsMatch is
  // "matches anywhere in the input", matching Delphi's TRegEx.IsMatch.
  TRegEx = record
    class function IsMatch(const AInput, APattern: string): Boolean; static;
  end;

  // Delphi's System.SysUtils.TProc (= reference to procedure). Under FPC 3.3.1
  // (-Mfunctionreferences) this maps to a real function reference, so capturing
  // closures — e.g. the Listen `AOnListen` continuation in Native.Server — work
  // exactly as in Delphi.
  TProc = reference to procedure;
  TProc<T> = reference to procedure(Arg1: T);

  {$SCOPEDENUMS ON}
  // Mirrors System.SysUtils.TStringSplitOptions (scoped: TStringSplitOptions.X).
  TStringSplitOptions = (None, ExcludeEmpty, ExcludeLastEmpty);
  {$SCOPEDENUMS OFF}

  // Mirrors the slice of System.SysUtils.TStringHelper that the Poseidon core
  // uses. Keep additions in lock-step with Delphi semantics — this is a
  // compatibility shim, not a place to invent behaviour.
  TPoseidonStringHelper = type helper for string
    // 0-based index of the last character that matches any char in ADelimiters,
    // or -1 if none. Matches Delphi's TStringHelper.LastDelimiter.
    function LastDelimiter(const ADelimiters: string): Integer;
    // Splits on any of ASeparators, keeping empty segments (N separators yield
    // N+1 parts). Matches Delphi's TStringHelper.Split(array of Char) default.
    function Split(const ASeparators: array of Char): TArray<string>; overload;
    // Splits into at most ACount parts; the final part holds the unsplit
    // remainder. Matches Delphi's TStringHelper.Split(separators, Count).
    function Split(const ASeparators: array of Char; ACount: Integer): TArray<string>; overload;
    // Splits, applying the empty-segment options. Matches Delphi's
    // TStringHelper.Split(separators, TStringSplitOptions).
    function Split(const ASeparators: array of Char; AOptions: TStringSplitOptions): TArray<string>; overload;
    // True when Self begins with AValue (case-sensitive). Matches StartsWith.
    function StartsWith(const AValue: string): Boolean;
    // True when the string has zero length. Matches Delphi's TStringHelper.IsEmpty.
    function IsEmpty: Boolean;
    // Concatenates AValues separated by ASeparator. Matches Delphi's static
    // TStringHelper.Join (invoked as `string.Join(...)`).
    class function Join(const ASeparator: string; const AValues: array of string): string; static;
  end;

  // Minimal System.JSON-compatible serialization shim. Poseidon.Problem builds
  // an RFC 7807 object from a few string/number fields and serialises it via
  // ToString; it never PARSES JSON. This mirrors only that write path
  // (TJSONObject.AddPair + TJSONString/TJSONNumber.Create + ToString) so
  // Poseidon.Problem compiles unchanged under FPC. Not a general JSON library —
  // Serialize() is the virtual worker; ToString delegates to it.
  TJSONValue = class
  protected
    function Serialize: string; virtual;
  public
    function ToString: string; reintroduce;
  end;

  TJSONString = class(TJSONValue)
  private
    FValue: string;
  protected
    function Serialize: string; override;
  public
    constructor Create(const AValue: string);
  end;

  TJSONNumber = class(TJSONValue)
  private
    FValue: string;
  protected
    function Serialize: string; override;
  public
    constructor Create(AValue: Integer);
  end;

  TJSONObjectPair = record
    Name: string;
    Value: TJSONValue;
  end;

  TJSONObject = class(TJSONValue)
  private
    FPairs: array of TJSONObjectPair;
  protected
    function Serialize: string; override;
  public
    destructor Destroy; override;
    function AddPair(const AName: string; AValue: TJSONValue): TJSONObject;
  end;

  // Mirrors the slice of System.Diagnostics.TStopwatch that the HTTP/2 manager
  // uses for rate-limiting windows (RST/PING flood): a monotonic high-resolution
  // tick source and its frequency. Only deltas and Frequency matter, so this
  // maps to QueryPerformanceCounter/Frequency — same semantics as Delphi's
  // TStopwatch on Windows.
  TStopwatch = record
    class function GetTimeStamp: Int64; static;
    class function Frequency: Int64; static;
  end;

  // Mirrors System.Hash.THashSHA1.GetHashBytes — used to compute
  // Sec-WebSocket-Accept = base64(SHA1(key + GUID)). Backed by FPC's sha1 unit.
  THashSHA1 = record
    class function GetHashBytes(const AData: TBytes): TBytes; static; overload;
    class function GetHashBytes(const AData: string): TBytes; static; overload;
  end;
{$ENDIF}

implementation

{$IFDEF FPC}

function TPoseidonStringHelper.Split(const ASeparators: array of Char; ACount: Integer): TArray<string>;
var
  I: Integer;
  K: Integer;
  LStart: Integer;
  LCount: Integer;
  LIsSep: Boolean;
begin
  SetLength(Result, 0);
  if ACount <= 0 then
    Exit;
  if ACount = 1 then
  begin
    SetLength(Result, 1);
    Result[0] := Self;
    Exit;
  end;
  LStart := 1;
  LCount := 0;
  for I := 1 to Length(Self) do
  begin
    if LCount = ACount - 1 then
      Break; // reached the split cap; the remainder stays whole
    LIsSep := False;
    for K := Low(ASeparators) to High(ASeparators) do
      if Self[I] = ASeparators[K] then
      begin
        LIsSep := True;
        Break;
      end;
    if LIsSep then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(Self, LStart, I - LStart);
      Inc(LCount);
      LStart := I + 1;
    end;
  end;
  SetLength(Result, LCount + 1);
  Result[LCount] := Copy(Self, LStart, Length(Self) - LStart + 1);
end;

function TPoseidonStringHelper.Split(const ASeparators: array of Char; AOptions: TStringSplitOptions): TArray<string>;
var
  LAll: TArray<string>;
  I: Integer;
  LCount: Integer;
begin
  LAll := Self.Split(ASeparators);
  if AOptions = TStringSplitOptions.None then
    Exit(LAll);
  SetLength(Result, Length(LAll));
  LCount := 0;
  for I := 0 to High(LAll) do
  begin
    if (AOptions = TStringSplitOptions.ExcludeEmpty) and (LAll[I] = '') then
      Continue;
    if (AOptions = TStringSplitOptions.ExcludeLastEmpty) and
       (I = High(LAll)) and (LAll[I] = '') then
      Continue;
    Result[LCount] := LAll[I];
    Inc(LCount);
  end;
  SetLength(Result, LCount);
end;

function TPoseidonStringHelper.StartsWith(const AValue: string): Boolean;
begin
  Result := (Length(AValue) <= Length(Self)) and
            (Copy(Self, 1, Length(AValue)) = AValue);
end;

function TPoseidonStringHelper.IsEmpty: Boolean;
begin
  Result := Length(Self) = 0;
end;

class function TPoseidonStringHelper.Join(const ASeparator: string;
  const AValues: array of string): string;
var
  I: Integer;
begin
  Result := '';
  for I := Low(AValues) to High(AValues) do
  begin
    if I > Low(AValues) then
      Result := Result + ASeparator;
    Result := Result + AValues[I];
  end;
end;

function TPoseidonURLEncoding.Decode(const AInput: string): string;
var
  I: Integer;
  LLen: Integer;
  LBytes: TBytes;
  LCount: Integer;
  LHexVal: Integer;
  LChBytes: TBytes;
  J: Integer;
begin
  LLen := Length(AInput);
  SetLength(LBytes, LLen * 4); // worst case: every char is multi-byte UTF-8
  LCount := 0;
  I := 1;
  while I <= LLen do
  begin
    if (AInput[I] = '%') and (I + 2 <= LLen) and
       TryStrToInt('$' + Copy(AInput, I + 1, 2), LHexVal) then
    begin
      LBytes[LCount] := Byte(LHexVal);
      Inc(LCount);
      Inc(I, 3);
    end
    else
    begin
      // A non-escaped character: emit its UTF-8 byte(s) (ASCII => 1 byte).
      LChBytes := TEncoding.UTF8.GetBytes(AInput[I]);
      for J := 0 to High(LChBytes) do
      begin
        LBytes[LCount] := LChBytes[J];
        Inc(LCount);
      end;
      Inc(I);
    end;
  end;
  SetLength(LBytes, LCount);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

class function TNetEncoding.URL: TPoseidonURLEncoding;
begin
  Result := Default(TPoseidonURLEncoding);
end;

class function TNetEncoding.Base64: TPoseidonBase64Encoding;
begin
  Result := Default(TPoseidonBase64Encoding);
end;

function TPoseidonBase64Encoding.EncodeBytesToString(const AInput: TBytes): string;
const
  CB64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
var
  I: Integer;
  LN: Integer;
  LB0, LB1, LB2: Byte;
begin
  Result := '';
  LN := Length(AInput);
  I := 0;
  while I < LN do
  begin
    LB0 := AInput[I];
    Result := Result + CB64[(LB0 shr 2) + 1];
    if I + 1 < LN then
    begin
      LB1 := AInput[I + 1];
      Result := Result + CB64[(((LB0 and 3) shl 4) or (LB1 shr 4)) + 1];
      if I + 2 < LN then
      begin
        LB2 := AInput[I + 2];
        Result := Result + CB64[(((LB1 and 15) shl 2) or (LB2 shr 6)) + 1];
        Result := Result + CB64[(LB2 and 63) + 1];
      end
      else
      begin
        Result := Result + CB64[((LB1 and 15) shl 2) + 1];
        Result := Result + '=';
      end;
    end
    else
    begin
      Result := Result + CB64[((LB0 and 3) shl 4) + 1];
      Result := Result + '==';
    end;
    Inc(I, 3);
  end;
end;

class function TRegEx.IsMatch(const AInput, APattern: string): Boolean;
var
  LRe: TRegExpr;
begin
  LRe := TRegExpr.Create;
  try
    LRe.Expression := APattern;
    Result := LRe.Exec(AInput);
  finally
    LRe.Free;
  end;
end;

function TPoseidonStringHelper.LastDelimiter(const ADelimiters: string): Integer;
var
  I: Integer;
  J: Integer;
begin
  Result := -1;
  for I := Length(Self) downto 1 do
    for J := 1 to Length(ADelimiters) do
      if Self[I] = ADelimiters[J] then
        Exit(I - 1);
end;

function _JSONEscape(const AInput: string): string;
var
  I: Integer;
  LCh: Char;
begin
  Result := '';
  for I := 1 to Length(AInput) do
  begin
    LCh := AInput[I];
    case LCh of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #8:  Result := Result + '\b';
      #9:  Result := Result + '\t';
      #10: Result := Result + '\n';
      #12: Result := Result + '\f';
      #13: Result := Result + '\r';
    else
      if LCh < #32 then
        Result := Result + '\u' + LowerCase(IntToHex(Ord(LCh), 4))
      else
        Result := Result + LCh;
    end;
  end;
end;

function TJSONValue.Serialize: string;
begin
  Result := '';
end;

function TJSONValue.ToString: string;
begin
  Result := Serialize;
end;

constructor TJSONString.Create(const AValue: string);
begin
  inherited Create;
  FValue := AValue;
end;

function TJSONString.Serialize: string;
begin
  Result := '"' + _JSONEscape(FValue) + '"';
end;

constructor TJSONNumber.Create(AValue: Integer);
begin
  inherited Create;
  FValue := IntToStr(AValue);
end;

function TJSONNumber.Serialize: string;
begin
  Result := FValue;
end;

destructor TJSONObject.Destroy;
var
  I: Integer;
begin
  for I := 0 to High(FPairs) do
    FPairs[I].Value.Free;
  inherited Destroy;
end;

function TJSONObject.AddPair(const AName: string; AValue: TJSONValue): TJSONObject;
var
  L: Integer;
begin
  L := Length(FPairs);
  SetLength(FPairs, L + 1);
  FPairs[L].Name := AName;
  FPairs[L].Value := AValue;
  Result := Self;
end;

function TJSONObject.Serialize: string;
var
  I: Integer;
begin
  Result := '{';
  for I := 0 to High(FPairs) do
  begin
    if I > 0 then
      Result := Result + ',';
    Result := Result + '"' + _JSONEscape(FPairs[I].Name) + '":' + FPairs[I].Value.Serialize;
  end;
  Result := Result + '}';
end;

class function TStopwatch.GetTimeStamp: Int64;
begin
  {$IFDEF MSWINDOWS}
  if not QueryPerformanceCounter(Result) then
    Result := 0;
  {$ELSE}
  Result := 0;
  {$ENDIF}
end;

class function TStopwatch.Frequency: Int64;
begin
  {$IFDEF MSWINDOWS}
  if not QueryPerformanceFrequency(Result) then
    Result := 1;
  {$ELSE}
  Result := 1;
  {$ENDIF}
end;

class function THashSHA1.GetHashBytes(const AData: TBytes): TBytes;
var
  LDigest: TSHA1Digest;
  LDummy: Byte;
begin
  if Length(AData) > 0 then
    LDigest := SHA1Buffer(AData[0], Length(AData))
  else
    LDigest := SHA1Buffer(LDummy, 0);
  SetLength(Result, SizeOf(LDigest));
  Move(LDigest[0], Result[0], SizeOf(LDigest));
end;

class function THashSHA1.GetHashBytes(const AData: string): TBytes;
begin
  Result := GetHashBytes(TEncoding.UTF8.GetBytes(AData));
end;

function TPoseidonStringHelper.Split(const ASeparators: array of Char): TArray<string>;
var
  I: Integer;
  K: Integer;
  LStart: Integer;
  LCount: Integer;
  LIsSep: Boolean;
begin
  SetLength(Result, 0);
  if Length(Self) = 0 then
  begin
    SetLength(Result, 1);
    Result[0] := '';
    Exit;
  end;
  LStart := 1;
  LCount := 0;
  for I := 1 to Length(Self) do
  begin
    LIsSep := False;
    for K := Low(ASeparators) to High(ASeparators) do
      if Self[I] = ASeparators[K] then
      begin
        LIsSep := True;
        Break;
      end;
    if LIsSep then
    begin
      SetLength(Result, LCount + 1);
      Result[LCount] := Copy(Self, LStart, I - LStart);
      Inc(LCount);
      LStart := I + 1;
    end;
  end;
  SetLength(Result, LCount + 1);
  Result[LCount] := Copy(Self, LStart, Length(Self) - LStart + 1);
end;

{$ENDIF}

end.
