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
  SysUtils,
  Classes,
  RegExpr;

type
  // Delphi's System.NetEncoding.TNetEncoding.URL.Decode does percent-decoding
  // with UTF-8. The Poseidon routing layer only needs URL.Decode; this mirrors
  // it via a nested record so `TNetEncoding.URL.Decode(s)` compiles unchanged.
  TPoseidonURLEncoding = record
    function Decode(const AInput: string): string;
  end;

  TNetEncoding = record
    class function URL: TPoseidonURLEncoding; static;
  end;

  // Delphi's System.RegularExpressions.TRegEx exposes a static IsMatch; FPC ships
  // RegExpr.TRegExpr (an instance API with different semantics). This record
  // mirrors the tiny static slice Poseidon.Validation relies on. IsMatch is
  // "matches anywhere in the input", matching Delphi's TRegEx.IsMatch.
  TRegEx = record
    class function IsMatch(const AInput, APattern: string): Boolean; static;
  end;

  // Delphi's System.SysUtils.TProc (= reference to procedure). FPC 3.2.2 has no
  // anonymous methods; the HPACK decoder only ever invokes this callback with
  // no arguments and never captures state (`if Assigned(cb) then cb;`), so a
  // plain parameterless procedure type is behaviourally sufficient here.
  // Callers that pass a capturing closure belong to a later slice (needs FPC
  // 3.3.1 {$modeswitch functionreferences}).
  TProc = procedure;

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
