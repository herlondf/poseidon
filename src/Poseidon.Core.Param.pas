unit Poseidon.Core.Param;

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TParamMissCallback = reference to procedure;

  // Forward declaration for Field helper
  TPoseidonParamField = record
  private
    FValue: string;
    FExists: Boolean;
  public
    function AsString: string;
    function AsInteger: Integer;
    function AsInt64: Int64;
    function AsBoolean: Boolean;
    function Exists: Boolean;
  end;

  TPoseidonParam = class
  private
    FData: TDictionary<string, string>;
    FRequired: Boolean;
    FOnMiss: TParamMissCallback;
    FMissFired: Boolean;
    function GetItem(const AKey: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    function Get(const AKey: string): string;
    function GetOrDefault(const AKey, ADefault: string): string;
    function TryGet(const AKey: string; out AValue: string): Boolean;
    function Has(const AKey: string): Boolean;
    procedure Add(const AKey, AValue: string);
    procedure AddOrSet(const AKey, AValue: string);
    procedure Clear;

    // Horse compatibility
    function ContainsKey(const AKey: string): Boolean;
    function TryGetValue(const AKey: string; out AValue: string): Boolean;
    function Field(const AKey: string): TPoseidonParamField;
    property Items[const AKey: string]: string read GetItem; default;
    property Dictionary: TDictionary<string, string> read FData;

    property Required: Boolean read FRequired write FRequired;
    property Data: TDictionary<string, string> read FData;
    property OnMiss: TParamMissCallback read FOnMiss write FOnMiss;
  end;

implementation

constructor TPoseidonParam.Create;
begin
  FData := TDictionary<string, string>.Create;
  FRequired := False;
  FMissFired := False;
end;

destructor TPoseidonParam.Destroy;
begin
  FData.Free;
  inherited;
end;

function TPoseidonParam.Get(const AKey: string): string;
var
  LPair: TPair<string, string>;
begin
  if FData.TryGetValue(AKey, Result) then
    Exit;
  // Case-insensitive fallback
  for LPair in FData do
    if SameText(LPair.Key, AKey) then
      Exit(LPair.Value);
  // Lazy load: fire OnMiss once to populate additional data (e.g. ALL_RAW headers)
  if (not FMissFired) and Assigned(FOnMiss) then
  begin
    FMissFired := True;
    FOnMiss();
    // Retry after miss callback populated new data
    if FData.TryGetValue(AKey, Result) then
      Exit;
    for LPair in FData do
      if SameText(LPair.Key, AKey) then
        Exit(LPair.Value);
  end;
  if FRequired then
    raise Exception.CreateFmt('Parameter "%s" is required but not found', [AKey]);
  Result := '';
end;

function TPoseidonParam.GetOrDefault(const AKey, ADefault: string): string;
var
  LPair: TPair<string, string>;
begin
  if FData.TryGetValue(AKey, Result) then
    Exit;
  for LPair in FData do
    if SameText(LPair.Key, AKey) then
      Exit(LPair.Value);
  Result := ADefault;
end;

function TPoseidonParam.TryGet(const AKey: string; out AValue: string): Boolean;
var
  LPair: TPair<string, string>;
begin
  Result := FData.TryGetValue(AKey, AValue);
  if not Result then
    for LPair in FData do
      if SameText(LPair.Key, AKey) then
      begin
        AValue := LPair.Value;
        Exit(True);
      end;
end;

function TPoseidonParam.Has(const AKey: string): Boolean;
var
  LPair: TPair<string, string>;
begin
  Result := FData.ContainsKey(AKey);
  if not Result then
    for LPair in FData do
      if SameText(LPair.Key, AKey) then
        Exit(True);
end;

procedure TPoseidonParam.Add(const AKey, AValue: string);
begin
  FData.Add(AKey, AValue);
end;

procedure TPoseidonParam.AddOrSet(const AKey, AValue: string);
begin
  FData.AddOrSetValue(AKey, AValue);
end;

procedure TPoseidonParam.Clear;
begin
  FData.Clear;
  FMissFired := False;
end;

function TPoseidonParam.GetItem(const AKey: string): string;
begin
  Result := Get(AKey);
end;

function TPoseidonParam.ContainsKey(const AKey: string): Boolean;
var
  LPair: TPair<string, string>;
begin
  Result := FData.ContainsKey(AKey);
  if not Result then
    for LPair in FData do
      if SameText(LPair.Key, AKey) then
        Exit(True);
end;

function TPoseidonParam.TryGetValue(const AKey: string; out AValue: string): Boolean;
var
  LPair: TPair<string, string>;
begin
  Result := FData.TryGetValue(AKey, AValue);
  if not Result then
    for LPair in FData do
      if SameText(LPair.Key, AKey) then
      begin
        AValue := LPair.Value;
        Exit(True);
      end;
end;

function TPoseidonParam.Field(const AKey: string): TPoseidonParamField;
var
  LPair: TPair<string, string>;
begin
  Result.FExists := FData.TryGetValue(AKey, Result.FValue);
  if not Result.FExists then
  begin
    for LPair in FData do
      if SameText(LPair.Key, AKey) then
      begin
        Result.FValue := LPair.Value;
        Result.FExists := True;
        Exit;
      end;
    Result.FValue := '';
  end;
end;

{ TPoseidonParamField }

function TPoseidonParamField.AsString: string;
begin
  Result := FValue;
end;

function TPoseidonParamField.AsInteger: Integer;
begin
  Result := StrToIntDef(FValue, 0);
end;

function TPoseidonParamField.AsInt64: Int64;
begin
  Result := StrToInt64Def(FValue, 0);
end;

function TPoseidonParamField.AsBoolean: Boolean;
begin
  Result := SameText(FValue, 'true') or (FValue = '1');
end;

function TPoseidonParamField.Exists: Boolean;
begin
  Result := FExists;
end;

end.
