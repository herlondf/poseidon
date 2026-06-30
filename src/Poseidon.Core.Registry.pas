unit Poseidon.Core.Registry;

// Keeps a flat list of every route registered in the framework.
// Used by the OpenAPI generator — does not affect routing behavior.

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  System.TypInfo,
  Web.HTTPApp,
  Poseidon.Commons;

type
  TPoseidonRouteEntry = record
    Method: string;        // uppercase: GET, POST, etc.
    Path: string;          // original path: /users/:id
    OpenAPIPath: string;   // converted: /users/{id}
    Summary: string;
    Description: string;
    Tags: TArray<string>;
    IsDeprecated: Boolean;
    ProducesJSON: Boolean;
    ConsumesJSON: Boolean;
  end;

  TPoseidonRouteRegistry = class
  private
    class var FEntries: TList<TPoseidonRouteEntry>;
    class function GetList: TList<TPoseidonRouteEntry>;
  public
    class procedure Register(AMethod: TMethodType; const APath: string);
    class procedure SetMeta(const APath, AMethod, ASummary, ADescription: string;
      ATags: TArray<string>; ADeprecated: Boolean = False);
    class function GetAll: TArray<TPoseidonRouteEntry>;
    class function ToOpenAPIPath(const APoseidonPath: string): string;
    class destructor UnInitialize;
  end;

implementation

class function TPoseidonRouteRegistry.GetList: TList<TPoseidonRouteEntry>;
begin
  if FEntries = nil then
    FEntries := TList<TPoseidonRouteEntry>.Create;
  Result := FEntries;
end;

class procedure TPoseidonRouteRegistry.Register(AMethod: TMethodType; const APath: string);
var
  LEntry: TPoseidonRouteEntry;
  LMethod: string;
begin
  LMethod := UpperCase(Copy(GetEnumName(TypeInfo(TMethodType), Ord(AMethod)), 3, MaxInt));

  // Skip wildcard catch-all entries
  if APath.Contains('*') then
    Exit;

  LEntry.Method      := LMethod;
  LEntry.Path        := APath;
  LEntry.OpenAPIPath := ToOpenAPIPath(APath);
  LEntry.Summary     := '';
  LEntry.Description := '';
  LEntry.Tags        := [];
  LEntry.IsDeprecated := False;
  LEntry.ProducesJSON := True;
  LEntry.ConsumesJSON := (LMethod = 'POST') or (LMethod = 'PUT') or (LMethod = 'PATCH');

  GetList.Add(LEntry);
end;

class procedure TPoseidonRouteRegistry.SetMeta(const APath, AMethod, ASummary,
  ADescription: string; ATags: TArray<string>; ADeprecated: Boolean);
var
  I: Integer;
  LEntry: TPoseidonRouteEntry;
begin
  for I := 0 to GetList.Count - 1 do
  begin
    LEntry := GetList[I];
    if (LEntry.Path = APath) and (LEntry.Method = AMethod.ToUpper) then
    begin
      LEntry.Summary     := ASummary;
      LEntry.Description := ADescription;
      LEntry.Tags        := ATags;
      LEntry.IsDeprecated := ADeprecated;
      GetList[I] := LEntry;
      Exit;
    end;
  end;
end;

class function TPoseidonRouteRegistry.GetAll: TArray<TPoseidonRouteEntry>;
begin
  Result := GetList.ToArray;
end;

class function TPoseidonRouteRegistry.ToOpenAPIPath(const APoseidonPath: string): string;
var
  LParts: TArray<string>;
  I: Integer;
begin
  LParts := APoseidonPath.Split(['/']);
  for I := 0 to High(LParts) do
    if LParts[I].StartsWith(':') then
      LParts[I] := '{' + LParts[I].Substring(1) + '}';
  Result := string.Join('/', LParts);
end;

class destructor TPoseidonRouteRegistry.UnInitialize;
begin
  FreeAndNil(FEntries);
end;

end.
