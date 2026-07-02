unit Poseidon.OpenAPI;

// Serves an OpenAPI 3.x spec + Swagger UI.
// Usage:
//   TPoseidon.Use(TPoseidonOpenAPI.Middleware('/api-docs'));
//   GET /api-docs      → OpenAPI spec JSON
//   GET /api-docs/ui   → Swagger UI browser page

interface

uses
  System.SysUtils,
  System.JSON,
  Poseidon.Proc,
  Poseidon.Commons,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback,
  Poseidon.Core.Registry;

type
  TPoseidonOpenAPIConfig = record
    Title: string;
    Version: string;
    Description: string;
    ContactName: string;
    ContactEmail: string;
    LicenseName: string;
    SpecPath: string;   // e.g. '/api-docs'
    UIPath: string;     // e.g. '/api-docs/ui'
  end;

  TPoseidonOpenAPI = class
  private
    class function BuildSpec(const AConfig: TPoseidonOpenAPIConfig): string;
    class function ExtractPathParams(const APoseidonPath: string): TJSONArray;
    class function SwaggerUIHtml(const ASpecURL: string): string;
  public
    // Returns a middleware callback that handles SpecPath and UIPath
    class function Middleware(
      const ASpecPath: string = '/api-docs';
      const ATitle: string = 'Poseidon API';
      const AVersion: string = '1.0.0'
    ): TPoseidonCallback;

    // Overload accepting full config
    class function MiddlewareConfig(const AConfig: TPoseidonOpenAPIConfig): TPoseidonCallback;

    // Generate the OpenAPI JSON spec directly (useful for testing)
    class function GenerateSpec(const AConfig: TPoseidonOpenAPIConfig): string;
  end;

implementation

{ TPoseidonOpenAPI }

class function TPoseidonOpenAPI.Middleware(const ASpecPath, ATitle, AVersion: string): TPoseidonCallback;
var
  LConfig: TPoseidonOpenAPIConfig;
begin
  LConfig.Title       := ATitle;
  LConfig.Version     := AVersion;
  LConfig.Description := '';
  LConfig.ContactName := '';
  LConfig.ContactEmail := '';
  LConfig.LicenseName := '';
  LConfig.SpecPath    := '/' + ASpecPath.Trim(['/']);
  LConfig.UIPath      := LConfig.SpecPath + '/ui';
  Result := MiddlewareConfig(LConfig);
end;

class function TPoseidonOpenAPI.MiddlewareConfig(const AConfig: TPoseidonOpenAPIConfig): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LPath: string;
    begin
      LPath := Req.PathInfo;
      if LPath = AConfig.SpecPath then
      begin
        Res.Status(200)
           .Header('Content-Type', 'application/json')
           .Header('Access-Control-Allow-Origin', '*')
           .Send(BuildSpec(AConfig));
      end
      else if LPath = AConfig.UIPath then
      begin
        Res.Status(200)
           .Header('Content-Type', 'text/html; charset=utf-8')
           .Send(SwaggerUIHtml(AConfig.SpecPath));
      end
      else
        Next;
    end;
end;

class function TPoseidonOpenAPI.GenerateSpec(const AConfig: TPoseidonOpenAPIConfig): string;
begin
  Result := BuildSpec(AConfig);
end;

class function TPoseidonOpenAPI.BuildSpec(const AConfig: TPoseidonOpenAPIConfig): string;
var
  LDoc, LInfo, LPaths, LPathItem, LOperation, LResponses, LContact: TJSONObject;
  LTags, LParamArr: TJSONArray;
  LEntries: TArray<TPoseidonRouteEntry>;
  LEntry: TPoseidonRouteEntry;
  LTag: string;
  LDefaultResponse: TJSONObject;
begin
  LDoc := TJSONObject.Create;
  try
    LDoc.AddPair('openapi', '3.0.3');

    // info
    LInfo := TJSONObject.Create;
    LInfo.AddPair('title', AConfig.Title);
    LInfo.AddPair('version', AConfig.Version);
    if not AConfig.Description.IsEmpty then
      LInfo.AddPair('description', AConfig.Description);
    if not AConfig.ContactEmail.IsEmpty then
    begin
      LContact := TJSONObject.Create;
      if not AConfig.ContactName.IsEmpty then
        LContact.AddPair('name', AConfig.ContactName);
      LContact.AddPair('email', AConfig.ContactEmail);
      LInfo.AddPair('contact', LContact);
    end;
    LDoc.AddPair('info', LInfo);

    // paths
    LPaths := TJSONObject.Create;
    LEntries := TPoseidonRouteRegistry.GetAll;

    for LEntry in LEntries do
    begin
      // Skip the OpenAPI spec/ui routes themselves
      if LEntry.Path.StartsWith(AConfig.SpecPath) then
        Continue;

      // Reuse existing path item or create a new one
      if not LPaths.TryGetValue(LEntry.OpenAPIPath, LPathItem) then
      begin
        LPathItem := TJSONObject.Create;
        LPaths.AddPair(LEntry.OpenAPIPath, LPathItem);
      end;

      LOperation := TJSONObject.Create;

      // Tags
      if Length(LEntry.Tags) > 0 then
      begin
        LTags := TJSONArray.Create;
        for LTag in LEntry.Tags do
          LTags.Add(LTag);
        LOperation.AddPair('tags', LTags);
      end;

      // Summary / description
      if not LEntry.Summary.IsEmpty then
        LOperation.AddPair('summary', LEntry.Summary);
      if not LEntry.Description.IsEmpty then
        LOperation.AddPair('description', LEntry.Description);

      if LEntry.IsDeprecated then
        LOperation.AddPair('deprecated', TJSONBool.Create(True));

      // Path parameters from `:id` segments
      LParamArr := ExtractPathParams(LEntry.Path);
      if LParamArr.Count > 0 then
        LOperation.AddPair('parameters', LParamArr)
      else
        LParamArr.Free;

      // Request body for write methods
      if (LEntry.Method = 'POST') or (LEntry.Method = 'PUT') or (LEntry.Method = 'PATCH') then
        LOperation.AddPair('requestBody',
          TJSONObject.Create
            .AddPair('required', TJSONBool.Create(True))
            .AddPair('content', TJSONObject.Create
              .AddPair('application/json', TJSONObject.Create
                .AddPair('schema', TJSONObject.Create
                  .AddPair('type', 'object')))));

      // Default responses
      LResponses := TJSONObject.Create;
      LDefaultResponse := TJSONObject.Create;
      LDefaultResponse.AddPair('description', 'OK');
      if LEntry.ProducesJSON then
        LDefaultResponse.AddPair('content', TJSONObject.Create
          .AddPair('application/json', TJSONObject.Create
            .AddPair('schema', TJSONObject.Create
              .AddPair('type', 'object'))));
      LResponses.AddPair('200', LDefaultResponse);

      if (LEntry.Method = 'POST') or (LEntry.Method = 'PUT') then
        LResponses.AddPair('422', TJSONObject.Create
          .AddPair('description', 'Validation error'));

      LOperation.AddPair('responses', LResponses);
      LPathItem.AddPair(LEntry.Method.ToLower, LOperation);
    end;

    LDoc.AddPair('paths', LPaths);
    Result := LDoc.Format;
  finally
    LDoc.Free;
  end;
end;

class function TPoseidonOpenAPI.ExtractPathParams(const APoseidonPath: string): TJSONArray;
var
  LSegments: TArray<string>;
  LSegment: string;
  LParam: TJSONObject;
  LSchema: TJSONObject;
begin
  Result := TJSONArray.Create;
  LSegments := APoseidonPath.Split(['/']);
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

class function TPoseidonOpenAPI.SwaggerUIHtml(const ASpecURL: string): string;
begin
  Result :=
    '<!DOCTYPE html>' + sLineBreak +
    '<html lang="en">' + sLineBreak +
    '<head>' + sLineBreak +
    '  <meta charset="UTF-8"/>' + sLineBreak +
    '  <title>Poseidon — API Docs</title>' + sLineBreak +
    '  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"/>' + sLineBreak +
    '</head>' + sLineBreak +
    '<body>' + sLineBreak +
    '<div id="swagger-ui"></div>' + sLineBreak +
    '<script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>' + sLineBreak +
    '<script>' + sLineBreak +
    'SwaggerUIBundle({' + sLineBreak +
    '  url: "' + ASpecURL + '",' + sLineBreak +
    '  dom_id: "#swagger-ui",' + sLineBreak +
    '  presets: [SwaggerUIBundle.presets.apis, SwaggerUIBundle.SwaggerUIStandalonePreset],' + sLineBreak +
    '  layout: "StandaloneLayout"' + sLineBreak +
    '});' + sLineBreak +
    '</script>' + sLineBreak +
    '</body>' + sLineBreak +
    '</html>';
end;

end.
