unit Poseidon.Serializer.AOT;

// AOT (ahead-of-time) JSON serializer for DTOs — OPT-IN UTILITY.
//
// Status: NOT the default path for TPoseidonResponse.Json. Benchmarks
// (bombardier 60s c=100, 2-field DTO) showed this implementation ~20%
// slower than Delphi's TJSONObject + ToString for small payloads. The
// gap is dominated by TStringBuilder overhead, the lock per request, and
// the final ToString allocation. TJSONObject's internal writer is highly
// tuned and hard to beat without a UTF-8 direct byte writer (future work).
//
// Why keep this unit anyway:
//   - The field-offset capture pattern (TFieldDesc with Kind + Offset)
//     eliminates per-call TValue boxing — useful for further optimization.
//   - For DTOs with many fields (20+) or deep nesting, AOT may catch up;
//     not yet measured.
//   - The fast-scan WriteJsonString is a reusable building block.
//
// Iteration history kept in commit log + AGENTS.md hot-path principle.
//
// Optimizations applied:
//   - Field-offset capture: direct PInteger/PUnicodeString reads, no TValue.
//   - Per-type closure cached after first compile.
//   - Pre-built name literals: `,"Name":` materialized once.
//   - Fast-scan WriteJsonString: bulk-Append clean strings.
//
// Usage when opting in:
//   uses Poseidon.Serializer.AOT;
//   var Json := TPoseidonSerializer.ToJson(MyDTO);

interface

uses
  System.SysUtils,
  System.Classes,
  System.Rtti,
  System.TypInfo,
  System.SyncObjs,
  System.Generics.Collections;

type
  TPoseidonWriteProc = reference to procedure(
    const AObj: TObject; ABuilder: TStringBuilder);

  TFieldKind = (
    fkUnsupported,
    fkInt32,
    fkInt64,
    fkSingle,
    fkDouble,
    fkExtended,
    fkUnicodeString,
    fkBoolean,
    fkEnumOrdinal,
    fkObject
  );

  TFieldDesc = record
    PreName:    string;        // ',"Name":' for non-first, '"Name":' for first
    Offset:     Integer;       // byte offset of the field in the instance
    Kind:       TFieldKind;
    NestedType: TRttiType;     // only for fkObject — nested type for recursion
  end;

  TPoseidonSerializer = class
  private
    class var FLock:     TCriticalSection;
    class var FCompiled: TDictionary<PTypeInfo, TPoseidonWriteProc>;

    class function  CompileWriter(AType: TRttiType): TPoseidonWriteProc; static;
    class function  CachedOrCompile(AType: TRttiType;
      AInfo: PTypeInfo): TPoseidonWriteProc; static;
    class function  ClassifyField(AField: TRttiField): TFieldKind; static;
    class procedure WriteJsonString(ABuilder: TStringBuilder;
      const AStr: string); static;
    class procedure WriteFloat(ABuilder: TStringBuilder; AValue: Extended); static;

    class constructor Create;
    class destructor  Destroy;
  public
    // Serializes AObj to a UTF-16 JSON string. Returns 'null' if AObj = nil.
    class function ToJson(AObj: TObject): string; static;
  end;

implementation

class constructor TPoseidonSerializer.Create;
begin
  FLock     := TCriticalSection.Create;
  FCompiled := TDictionary<PTypeInfo, TPoseidonWriteProc>.Create;
end;

class destructor TPoseidonSerializer.Destroy;
begin
  FCompiled.Free;
  FLock.Free;
end;

class procedure TPoseidonSerializer.WriteJsonString(ABuilder: TStringBuilder;
  const AStr: string);
var
  LLen, I, LChunkStart: Integer;
  C: Char;
  HasSpecial: Boolean;
begin
  ABuilder.Append('"');
  LLen := Length(AStr);
  if LLen = 0 then
  begin
    ABuilder.Append('"');
    Exit;
  end;

  // Fast scan: most strings have no escape-needing chars. Detect once.
  HasSpecial := False;
  for I := 1 to LLen do
  begin
    C := AStr[I];
    if (C = '"') or (C = '\') or (C < #32) then
    begin
      HasSpecial := True;
      Break;
    end;
  end;

  if not HasSpecial then
  begin
    // Common case — append the whole string as a single chunk.
    ABuilder.Append(AStr);
  end
  else
  begin
    LChunkStart := 1;
    for I := 1 to LLen do
    begin
      C := AStr[I];
      if (C = '"') or (C = '\') or (C < #32) then
      begin
        if I > LChunkStart then
          ABuilder.Append(AStr, LChunkStart - 1, I - LChunkStart);
        case C of
          '"':  ABuilder.Append('\"');
          '\':  ABuilder.Append('\\');
          #8:   ABuilder.Append('\b');
          #9:   ABuilder.Append('\t');
          #10:  ABuilder.Append('\n');
          #12:  ABuilder.Append('\f');
          #13:  ABuilder.Append('\r');
        else
          ABuilder.Append('\u').Append(IntToHex(Ord(C), 4));
        end;
        LChunkStart := I + 1;
      end;
    end;
    if LLen >= LChunkStart then
      ABuilder.Append(AStr, LChunkStart - 1, LLen - LChunkStart + 1);
  end;

  ABuilder.Append('"');
end;

class procedure TPoseidonSerializer.WriteFloat(ABuilder: TStringBuilder;
  AValue: Extended);
var
  LFmt: TFormatSettings;
begin
  LFmt := TFormatSettings.Invariant;
  ABuilder.Append(FloatToStrF(AValue, ffGeneral, 15, 0, LFmt));
end;

class function TPoseidonSerializer.CachedOrCompile(AType: TRttiType;
  AInfo: PTypeInfo): TPoseidonWriteProc;
begin
  FLock.Enter;
  try
    FCompiled.TryGetValue(AInfo, Result);
  finally
    FLock.Leave;
  end;
  if Assigned(Result) then Exit;

  Result := CompileWriter(AType);
  FLock.Enter;
  try
    FCompiled.AddOrSetValue(AInfo, Result);
  finally
    FLock.Leave;
  end;
end;

class function TPoseidonSerializer.ClassifyField(AField: TRttiField): TFieldKind;
var
  LType: TRttiType;
begin
  Result := fkUnsupported;
  LType := AField.FieldType;
  if LType = nil then Exit;

  case LType.TypeKind of
    tkInteger:    Result := fkInt32;
    tkInt64:      Result := fkInt64;
    tkUString,
    tkString,
    tkLString,
    tkWString:    Result := fkUnicodeString;
    tkClass:      Result := fkObject;
    tkEnumeration:
      if LType.Handle = TypeInfo(Boolean) then Result := fkBoolean
      else Result := fkEnumOrdinal;
    tkFloat:
      begin
        case (LType as TRttiFloatType).FloatType of
          ftSingle:   Result := fkSingle;
          ftDouble:   Result := fkDouble;
          ftExtended: Result := fkExtended;
        else
          Result := fkDouble;
        end;
      end;
  end;
end;

class function TPoseidonSerializer.CompileWriter(AType: TRttiType): TPoseidonWriteProc;
var
  LFields: TArray<TRttiField>;
  LDescs:  TArray<TFieldDesc>;
  LCount:  Integer;
  I:       Integer;
begin
  LFields := AType.GetFields;
  LCount  := Length(LFields);
  SetLength(LDescs, LCount);
  for I := 0 to LCount - 1 do
  begin
    if I = 0 then
      LDescs[I].PreName := '"' + LFields[I].Name + '":'
    else
      LDescs[I].PreName := ',"' + LFields[I].Name + '":';
    LDescs[I].Offset := LFields[I].Offset;
    LDescs[I].Kind   := ClassifyField(LFields[I]);
    if LDescs[I].Kind = fkObject then
      LDescs[I].NestedType := LFields[I].FieldType;
  end;

  Result := procedure(const AObj: TObject; ABuilder: TStringBuilder)
  var
    J:        Integer;
    P:        NativeUInt;
    LObj:     TObject;
    LSubProc: TPoseidonWriteProc;
  begin
    ABuilder.Append('{');
    P := NativeUInt(AObj);
    for J := 0 to LCount - 1 do
    begin
      ABuilder.Append(LDescs[J].PreName);
      case LDescs[J].Kind of
        fkInt32:
          ABuilder.Append(PInteger(P + NativeUInt(LDescs[J].Offset))^);

        fkInt64:
          ABuilder.Append(PInt64(P + NativeUInt(LDescs[J].Offset))^);

        fkUnicodeString:
          WriteJsonString(ABuilder, PUnicodeString(P + NativeUInt(LDescs[J].Offset))^);

        fkSingle:
          WriteFloat(ABuilder, PSingle(P + NativeUInt(LDescs[J].Offset))^);

        fkDouble:
          WriteFloat(ABuilder, PDouble(P + NativeUInt(LDescs[J].Offset))^);

        fkExtended:
          WriteFloat(ABuilder, PExtended(P + NativeUInt(LDescs[J].Offset))^);

        fkBoolean:
          if PBoolean(P + NativeUInt(LDescs[J].Offset))^ then
            ABuilder.Append('true')
          else
            ABuilder.Append('false');

        fkEnumOrdinal:
          ABuilder.Append(PInteger(P + NativeUInt(LDescs[J].Offset))^);

        fkObject:
          begin
            LObj := PObject(P + NativeUInt(LDescs[J].Offset))^;
            if LObj = nil then
              ABuilder.Append('null')
            else
            begin
              LSubProc := CachedOrCompile(LDescs[J].NestedType, LObj.ClassInfo);
              LSubProc(LObj, ABuilder);
            end;
          end;
      else
        ABuilder.Append('null');
      end;
    end;
    ABuilder.Append('}');
  end;
end;

class function TPoseidonSerializer.ToJson(AObj: TObject): string;
const
  INITIAL_CAPACITY = 256;
var
  LWriter:   TPoseidonWriteProc;
  LBuilder:  TStringBuilder;
  LCtx:      TRttiContext;
begin
  if AObj = nil then Exit('null');

  LCtx := TRttiContext.Create;
  try
    LWriter := CachedOrCompile(LCtx.GetType(AObj.ClassType), AObj.ClassInfo);
  finally
    LCtx.Free;
  end;

  LBuilder := TStringBuilder.Create(INITIAL_CAPACITY);
  try
    LWriter(AObj, LBuilder);
    Result := LBuilder.ToString;
  finally
    LBuilder.Free;
  end;
end;

end.
