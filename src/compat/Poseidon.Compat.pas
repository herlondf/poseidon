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
  SysUtils;

type
  // Delphi's System.SysUtils.TProc (= reference to procedure). FPC 3.2.2 has no
  // anonymous methods; the HPACK decoder only ever invokes this callback with
  // no arguments and never captures state (`if Assigned(cb) then cb;`), so a
  // plain parameterless procedure type is behaviourally sufficient here.
  // Callers that pass a capturing closure belong to a later slice (needs FPC
  // 3.3.1 {$modeswitch functionreferences}).
  TProc = procedure;

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
  end;
{$ENDIF}

implementation

{$IFDEF FPC}

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
