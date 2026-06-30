unit Poseidon.Core.Param;

interface

uses
  System.SysUtils,
  System.Generics.Collections;

type
  TPoseidonParam = class
  private
    FData: TDictionary<string, string>;
    FRequired: Boolean;
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

end.
