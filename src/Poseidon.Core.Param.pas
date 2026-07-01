unit Poseidon.Core.Param;

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
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
  end;

implementation

constructor TPoseidonParam.Create;
begin
  FData := TDictionary<string, string>.Create;
  FRequired := False;
end;

destructor TPoseidonParam.Destroy;
begin
  FData.Free;
  inherited;
end;

function TPoseidonParam.Get(const AKey: string): string;
begin
  if not FData.TryGetValue(AKey, Result) then
  begin
    if FRequired then
      raise Exception.CreateFmt('Parameter "%s" is required but not found', [AKey]);
    Result := '';
  end;
end;

function TPoseidonParam.GetOrDefault(const AKey, ADefault: string): string;
begin
  if not FData.TryGetValue(AKey, Result) then
    Result := ADefault;
end;

function TPoseidonParam.TryGet(const AKey: string; out AValue: string): Boolean;
begin
  Result := FData.TryGetValue(AKey, AValue);
end;

function TPoseidonParam.Has(const AKey: string): Boolean;
begin
  Result := FData.ContainsKey(AKey);
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
end;

function TPoseidonParam.GetItem(const AKey: string): string;
begin
  Result := Get(AKey);
end;

function TPoseidonParam.ContainsKey(const AKey: string): Boolean;
begin
  Result := FData.ContainsKey(AKey);
end;

function TPoseidonParam.TryGetValue(const AKey: string; out AValue: string): Boolean;
begin
  Result := FData.TryGetValue(AKey, AValue);
end;

function TPoseidonParam.Field(const AKey: string): TPoseidonParamField;
begin
  Result.FExists := FData.TryGetValue(AKey, Result.FValue);
  if not Result.FExists then
    Result.FValue := '';
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
