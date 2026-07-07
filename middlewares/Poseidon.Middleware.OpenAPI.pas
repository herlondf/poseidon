unit Poseidon.Middleware.OpenAPI;

// Serves an OpenAPI 3.x spec + Swagger UI.
//
// Note: This middleware generates a basic spec from manually registered
// route metadata. Use AddRoute to describe each endpoint.
//
// Usage:
//   var OA := TPoseidonOpenAPI.Create;
//   OA.Title('My API').Version('1.0.0');
//   OA.AddRoute('GET', '/ping', 'Health check');
//   OA.AddRoute('POST', '/users', 'Create user');
//   App.Use(OA.Build);

interface

uses
  System.SysUtils,
  System.JSON,
  System.Generics.Collections,
  Poseidon.Native.Types;

type
  TOpenAPIRoute = record
    Method: string;
    Path: string;
    Summary: string;
    Tags: TArray<string>;
  end;

  TPoseidonOpenAPI = class
  private
    FTitle: string;
    FVersion: string;
    FDescription: string;
    FSpecPath: string;
    FUIPath: string;
    FRoutes: TList<TOpenAPIRoute>;
    function BuildSpec: string;
    function ExtractPathParams(const APath: string): TJSONArray;
    function SwaggerUIHtml: string;
    function ToOpenAPIPath(const APath: string): string;
  public
    constructor Create;
    destructor Destroy; override;

    function Title(const AValue: string): TPoseidonOpenAPI;
    function Version(const AValue: string): TPoseidonOpenAPI;
    function Description(const AValue: string): TPoseidonOpenAPI;
    function SpecPath(const AValue: string): TPoseidonOpenAPI;
    function AddRoute(const AMethod, APath, ASummary: string;
      const ATags: TArray<string> = nil): TPoseidonOpenAPI;

    function Build: TNativeMiddlewareFunc;
  end;

implementation

constructor TPoseidonOpenAPI.Create;
begin
  inherited Create;
  FTitle := 'Poseidon API';
  FVersion := '1.0.0';
  FDescription := '';
  FSpecPath := '/api-docs';
  FUIPath := '/api-docs/ui';
  FRoutes := TList<TOpenAPIRoute>.Create;
end;

destructor TPoseidonOpenAPI.Destroy;
begin
  FRoutes.Free;
  inherited;
end;

function TPoseidonOpenAPI.Title(const AValue: string): TPoseidonOpenAPI;
begin
  FTitle := AValue;
  Result := Self;
end;

function TPoseidonOpenAPI.Version(const AValue: string): TPoseidonOpenAPI;
begin
  FVersion := AValue;
  Result := Self;
end;

function TPoseidonOpenAPI.Description(const AValue: string): TPoseidonOpenAPI;
begin
  FDescription := AValue;
  Result := Self;
end;

function TPoseidonOpenAPI.SpecPath(const AValue: string): TPoseidonOpenAPI;
begin
  FSpecPath := '/' + AValue.Trim(['/']);
  FUIPath := FSpecPath + '/ui';
  Result := Self;
end;

function TPoseidonOpenAPI.AddRoute(const AMethod, APath, ASummary: string;
  const ATags: TArray<string>): TPoseidonOpenAPI;
var
  LRoute: TOpenAPIRoute;
begin
  LRoute.Method := AMethod;
  LRoute.Path := APath;
  LRoute.Summary := ASummary;
  LRoute.Tags := ATags;
  FRoutes.Add(LRoute);
  Result := Self;
end;

function TPoseidonOpenAPI.ToOpenAPIPath(const APath: string): string;
var
  LSegments: TArray<string>;
  I: Integer;
begin
  LSegments := APath.Split(['/']);
  for I := 0 to High(LSegments) do
    if LSegments[I].StartsWith(':') then
      LSegments[I] := '{' + LSegments[I].Substring(1) + '}';
  Result := string.Join('/', LSegments);
  if not Result.StartsWith('/') then
    Result := '/' + Result;
end;

function TPoseidonOpenAPI.ExtractPathParams(const APath: string): TJSONArray;
var
  LSegments: TArray<string>;
  LSegment: string;
  LParam, LSchema: TJSONObject;
begin
  Result := TJSONArray.Create;
  LSegments := APath.Split(['/']);
  for LSegment in LSegments do
  begin
    if LSegment.StartsWith(':') then
    begin
      LParam := TJSONObject.Create;
      LParam.AddPair('name', LSegment.Substring(1));
      LParam.AddPair('in', 'path');
      LParam.AddPair('required', TJSONBool.Create(True));
      LSchema := TJSONObject.Create;
      LSchema.AddPair('type', 'string');
      LParam.AddPair('schema', LSchema);
      Result.AddElement(LParam);
    end;
  end;
end;

function TPoseidonOpenAPI.BuildSpec: string;
var
  LDoc, LInfo, LPaths, LPathItem, LOperation, LResponses: TJSONObject;
  LTags, LParamArr: TJSONArray;
  LRoute: TOpenAPIRoute;
  LOpenAPIPath, LTag: string;
  LPathItemVal: TJSONValue;
begin
  LDoc := TJSONObject.Create;
  try
    LDoc.AddPair('openapi', '3.0.3');

    LInfo := TJSONObject.Create;
    LInfo.AddPair('title', FTitle);
    LInfo.AddPair('version', FVersion);
    if FDescription <> '' then
      LInfo.AddPair('description', FDescription);
    LDoc.AddPair('info', LInfo);

    LPaths := TJSONObject.Create;
    for LRoute in FRoutes do
    begin
      LOpenAPIPath := ToOpenAPIPath(LRoute.Path);

      if not LPaths.TryGetValue(LOpenAPIPath, LPathItemVal) then
      begin
        LPathItem := TJSONObject.Create;
        LPaths.AddPair(LOpenAPIPath, LPathItem);
      end
      else
        LPathItem := LPathItemVal as TJSONObject;

      LOperation := TJSONObject.Create;

      if Length(LRoute.Tags) > 0 then
      begin
        LTags := TJSONArray.Create;
        for LTag in LRoute.Tags do
          LTags.Add(LTag);
        LOperation.AddPair('tags', LTags);
      end;

      if LRoute.Summary <> '' then
        LOperation.AddPair('summary', LRoute.Summary);

      LParamArr := ExtractPathParams(LRoute.Path);
      if LParamArr.Count > 0 then
        LOperation.AddPair('parameters', LParamArr)
      else
        LParamArr.Free;

      if (LRoute.Method = 'POST') or (LRoute.Method = 'PUT') or (LRoute.Method = 'PATCH') then
        LOperation.AddPair('requestBody',
          TJSONObject.Create
            .AddPair('required', TJSONBool.Create(True))
            .AddPair('content', TJSONObject.Create
              .AddPair('application/json', TJSONObject.Create
                .AddPair('schema', TJSONObject.Create
                  .AddPair('type', 'object')))));

      LResponses := TJSONObject.Create;
      LResponses.AddPair('200', TJSONObject.Create.AddPair('description', 'OK'));
      LOperation.AddPair('responses', LResponses);

      LPathItem.AddPair(LRoute.Method.ToLower, LOperation);
    end;

    LDoc.AddPair('paths', LPaths);
    Result := LDoc.Format;
  finally
    LDoc.Free;
  end;
end;

function TPoseidonOpenAPI.SwaggerUIHtml: string;
begin
  Result :=
    '<!DOCTYPE html>' + sLineBreak +
    '<html lang="en"><head><meta charset="UTF-8"/>' + sLineBreak +
    '<title>Poseidon — API Docs</title>' + sLineBreak +
    '<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"/>' + sLineBreak +
    '</head><body><div id="swagger-ui"></div>' + sLineBreak +
    '<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>' + sLineBreak +
    '<script>SwaggerUIBundle({url:"' + FSpecPath + '",' +
    'dom_id:"#swagger-ui",presets:[SwaggerUIBundle.presets.apis,' +
    'SwaggerUIBundle.SwaggerUIStandalonePreset],layout:"StandaloneLayout"});</script>' + sLineBreak +
    '</body></html>';
end;

function TPoseidonOpenAPI.Build: TNativeMiddlewareFunc;
var
  LSpecJSON, LUIHtml, LSpecPath, LUIPath: string;
begin
  LSpecJSON := BuildSpec;
  LUIHtml := SwaggerUIHtml;
  LSpecPath := FSpecPath;
  LUIPath := FUIPath;
  Self.Free;

  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      if ACtx.Path = LSpecPath then
      begin
        ACtx.Status := 200;
        ACtx.ContentType := 'application/json';
        ACtx.Body := TEncoding.UTF8.GetBytes(LSpecJSON);
        var LLen := Length(ACtx.ExtraHeaders);
        SetLength(ACtx.ExtraHeaders, LLen + 1);
        ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(
          'Access-Control-Allow-Origin', '*');
        ACtx.Handled := True;
      end
      else if ACtx.Path = LUIPath then
      begin
        ACtx.Status := 200;
        ACtx.ContentType := 'text/html; charset=utf-8';
        ACtx.Body := TEncoding.UTF8.GetBytes(LUIHtml);
        ACtx.Handled := True;
      end
      else
        ANext();
    end;
end;

end.
