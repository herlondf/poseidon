unit Poseidon.Response;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.RTTI,
  System.TypInfo,
  Web.HTTPApp,
  Poseidon.Commons,
  Poseidon.Cookies;

type
  TPoseidonResponse = class
  private
    FWebResponse: TWebResponse;
    FRawBody:        TBytes;
    FRawContentType: string;
    FHasRawBody:     Boolean;

    function SerializeToJSON(AObject: TObject): TJSONObject;
  public
    constructor Create(AWebResponse: TWebResponse);
    destructor Destroy; override;

    // Send a plain string body
    function Send(const AContent: string): TPoseidonResponse;

    // Serialize AObject to JSON, set Content-Type: application/json, optionally free AObject
    function Json(AObject: TObject; AOwns: Boolean = True): TPoseidonResponse; overload;

    // Serialize a TJSONValue directly and free it
    function Json(AValue: TJSONValue): TPoseidonResponse; overload;

    // Set HTTP status code
    function Status(ACode: Integer): TPoseidonResponse; overload;
    function Status(AStatus: THTTPStatus): TPoseidonResponse; overload;

    // Read current status code
    function StatusCode: Integer;

    // Add or overwrite a response header
    function Header(const AName, AValue: string): TPoseidonResponse;

    // Remove a response header
    function RemoveHeader(const AName: string): TPoseidonResponse;

    // Set Content-Type
    function ContentType(const AMime: string): TPoseidonResponse;

    // 303 redirect
    function Redirect(const ALocation: string): TPoseidonResponse; overload;
    function Redirect(const ALocation: string; AStatus: THTTPStatus): TPoseidonResponse; overload;

    // Serve a file inline (Content-Disposition: inline)
    function SendFile(const AFileName: string): TPoseidonResponse; overload;
    function SendFile(AStream: TStream; const AFileName: string): TPoseidonResponse; overload;

    // Serve a file as download (Content-Disposition: attachment)
    function Download(const AFileName: string): TPoseidonResponse; overload;

    function RawWebResponse: TWebResponse;

    // RFC 7807 Problem Details response (application/problem+json)
    function Problem(AStatus: THTTPStatus; const ADetail: string = ''): TPoseidonResponse; overload;
    function Problem(AStatus: THTTPStatus; const ATitle, ADetail: string): TPoseidonResponse; overload;

    // W4: raw-bytes body. Sets the response body to ABytes (UTF-8 already
    // encoded) and bypasses the FWebResponse.Content (string, UTF-16) round
    // trip in adapter CommitResponse. Provider.Native checks HasRawBody and
    // wires the bytes straight to _BuildResponse — saves 1 UTF-16→UTF-8
    // encoding pass per request.
    function RawSend(const ABytes: TBytes; const AContentType: string = 'application/octet-stream'): TPoseidonResponse;
    function JsonBytes(const ABytes: TBytes): TPoseidonResponse;
    function HasRawBody: Boolean;
    function RawBody: TBytes;
    function RawContentType: string;

    // Cookie helpers (see Poseidon.Cookies for TCookieOptions)
    function SetCookie(const AName, AValue: string): TPoseidonResponse; overload;
    function SetCookie(const AName, AValue: string;
      const AOptions: TCookieOptions): TPoseidonResponse; overload;
    function SetSignedCookie(const AName, AValue, ASecret: string;
      const AOptions: TCookieOptions): TPoseidonResponse; overload;
    function SetSignedCookie(const AName, AValue, ASecret: string): TPoseidonResponse; overload;
    function ClearCookie(const AName: string; const APath: string = '/'): TPoseidonResponse;

    // Reset for pool reuse — reassigns the underlying web response and resets status
    procedure Reinitialize(AWebResponse: TWebResponse);
  end;

implementation

uses
  System.IOUtils,
  Poseidon.Problem;

constructor TPoseidonResponse.Create(AWebResponse: TWebResponse);
begin
  FWebResponse := AWebResponse;
  FWebResponse.StatusCode := THTTPStatus.Ok.ToInteger;
end;

destructor TPoseidonResponse.Destroy;
begin
  inherited;
end;

function TPoseidonResponse.Send(const AContent: string): TPoseidonResponse;
begin
  if AContent.IsEmpty then
  begin
    FWebResponse.ContentStream := TMemoryStream.Create;
    FWebResponse.ContentLength := 0;
  end
  else
    FWebResponse.Content := AContent;
  Result := Self;
end;

function TPoseidonResponse.SerializeToJSON(AObject: TObject): TJSONObject;
var
  LCtx: TRttiContext;
  LType: TRttiType;
  LField: TRttiField;
  LValue: TValue;
  LNestedJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  LCtx := TRttiContext.Create;
  try
    LType := LCtx.GetType(AObject.ClassType);
    for LField in LType.GetFields do
    begin
      LValue := LField.GetValue(AObject);
      case LField.FieldType.TypeKind of
        tkUString, tkString, tkLString, tkWString:
          Result.AddPair(LField.Name, TJSONString.Create(LValue.AsString));
        tkInteger:
          Result.AddPair(LField.Name, TJSONNumber.Create(LValue.AsInteger));
        tkInt64:
          Result.AddPair(LField.Name, TJSONNumber.Create(LValue.AsInt64));
        tkFloat:
          Result.AddPair(LField.Name, TJSONNumber.Create(LValue.AsExtended));
        tkEnumeration:
          if LField.FieldType.Handle = TypeInfo(Boolean) then
            Result.AddPair(LField.Name, TJSONBool.Create(LValue.AsBoolean));
        tkClass:
          if not LValue.IsEmpty and (LValue.AsObject <> nil) then
          begin
            LNestedJSON := SerializeToJSON(LValue.AsObject);
            Result.AddPair(LField.Name, LNestedJSON);
          end
          else
            Result.AddPair(LField.Name, TJSONNull.Create);
      end;
    end;
  finally
    LCtx.Free;
  end;
end;

function TPoseidonResponse.Json(AObject: TObject; AOwns: Boolean): TPoseidonResponse;
var
  LJSON:    TJSONObject;
  LStr:     string;
begin
  // Builds the JSON string once, then pre-encodes to UTF-8 bytes into the
  // RawBody fast path. FWebResponse.Content is also set so test mocks and
  // middleware that inspect Content keep working — Provider.Native sees
  // HasRawBody=True and bypasses CommitResponse's encoding step (W4).
  LJSON := SerializeToJSON(AObject);
  try
    LStr := LJSON.ToString;
    FWebResponse.ContentType := TMimeType.ApplicationJSON;
    FWebResponse.Content := LStr;
    FRawBody             := TEncoding.UTF8.GetBytes(LStr);
    FRawContentType      := TMimeType.ApplicationJSON;
    FHasRawBody          := True;
  finally
    LJSON.Free;
    if AOwns then
      AObject.Free;
  end;
  Result := Self;
end;

function TPoseidonResponse.Json(AValue: TJSONValue): TPoseidonResponse;
var
  LStr: string;
begin
  try
    LStr := AValue.ToString;
    FWebResponse.ContentType := TMimeType.ApplicationJSON;
    FWebResponse.Content := LStr;
    FRawBody             := TEncoding.UTF8.GetBytes(LStr);
    FRawContentType      := TMimeType.ApplicationJSON;
    FHasRawBody          := True;
  finally
    AValue.Free;
  end;
  Result := Self;
end;

function TPoseidonResponse.Status(ACode: Integer): TPoseidonResponse;
begin
  FWebResponse.StatusCode := ACode;
  Result := Self;
end;

function TPoseidonResponse.Status(AStatus: THTTPStatus): TPoseidonResponse;
begin
  FWebResponse.StatusCode := AStatus.ToInteger;
  Result := Self;
end;

function TPoseidonResponse.StatusCode: Integer;
begin
  Result := FWebResponse.StatusCode;
end;

function TPoseidonResponse.Header(const AName, AValue: string): TPoseidonResponse;
begin
  FWebResponse.SetCustomHeader(AName, AValue);
  Result := Self;
end;

function TPoseidonResponse.RemoveHeader(const AName: string): TPoseidonResponse;
var
  I: Integer;
begin
  I := FWebResponse.CustomHeaders.IndexOfName(AName);
  if I >= 0 then
    FWebResponse.CustomHeaders.Delete(I);
  Result := Self;
end;

function TPoseidonResponse.ContentType(const AMime: string): TPoseidonResponse;
begin
  FWebResponse.ContentType := AMime;
  Result := Self;
end;

function TPoseidonResponse.Redirect(const ALocation: string): TPoseidonResponse;
begin
  Result := Redirect(ALocation, THTTPStatus.SeeOther);
end;

function TPoseidonResponse.Redirect(const ALocation: string; AStatus: THTTPStatus): TPoseidonResponse;
begin
  FWebResponse.SetCustomHeader('Location', ALocation);
  Result := Status(AStatus);
end;

function TPoseidonResponse.SendFile(const AFileName: string): TPoseidonResponse;
var
  LStream: TFileStream;
begin
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  Result := SendFile(LStream, TPath.GetFileName(AFileName));
end;

function TPoseidonResponse.SendFile(AStream: TStream; const AFileName: string): TPoseidonResponse;
begin
  AStream.Position := 0;
  FWebResponse.FreeContentStream := False;
  FWebResponse.ContentLength := AStream.Size;
  FWebResponse.ContentStream := AStream;
  FWebResponse.SetCustomHeader('Content-Disposition', Format('inline; filename="%s"', [AFileName]));
  FWebResponse.SendResponse;
  Result := Self;
end;

function TPoseidonResponse.Download(const AFileName: string): TPoseidonResponse;
var
  LStream: TFileStream;
  LName: string;
begin
  LName := TPath.GetFileName(AFileName);
  LStream := TFileStream.Create(AFileName, fmOpenRead or fmShareDenyWrite);
  LStream.Position := 0;
  FWebResponse.FreeContentStream := False;
  FWebResponse.ContentLength := LStream.Size;
  FWebResponse.ContentStream := LStream;
  FWebResponse.SetCustomHeader('Content-Disposition', Format('attachment; filename="%s"', [LName]));
  FWebResponse.SendResponse;
  Result := Self;
end;

function TPoseidonResponse.RawWebResponse: TWebResponse;
begin
  Result := FWebResponse;
end;

function TPoseidonResponse.Problem(AStatus: THTTPStatus; const ADetail: string): TPoseidonResponse;
begin
  Result := Problem(AStatus, TProblemDetail.CanonicalTitle(AStatus.ToInteger), ADetail);
end;

function TPoseidonResponse.Problem(AStatus: THTTPStatus; const ATitle, ADetail: string): TPoseidonResponse;
var
  LProblem: TProblemDetail;
  LJSON:    TJSONObject;
begin
  LProblem.TypeURI  := 'about:blank';
  LProblem.Status   := AStatus.ToInteger;
  LProblem.Title    := ATitle;
  LProblem.Detail   := ADetail;
  LProblem.Instance := '';
  LJSON := LProblem.ToJSON;
  try
    FWebResponse.StatusCode  := AStatus.ToInteger;
    FWebResponse.ContentType := 'application/problem+json';
    FWebResponse.Content     := LJSON.ToString;
  finally
    LJSON.Free;
  end;
  Result := Self;
end;

procedure TPoseidonResponse.Reinitialize(AWebResponse: TWebResponse);
begin
  FWebResponse := AWebResponse;
  FWebResponse.StatusCode := THTTPStatus.Ok.ToInteger;
  FRawBody        := nil;
  FRawContentType := '';
  FHasRawBody     := False;
end;

{ W4: raw-bytes body helpers }

function TPoseidonResponse.RawSend(const ABytes: TBytes;
  const AContentType: string): TPoseidonResponse;
begin
  FRawBody        := ABytes;
  FRawContentType := AContentType;
  FHasRawBody     := True;
  Result := Self;
end;

function TPoseidonResponse.JsonBytes(const ABytes: TBytes): TPoseidonResponse;
begin
  Result := RawSend(ABytes, 'application/json');
end;

function TPoseidonResponse.HasRawBody: Boolean;
begin
  Result := FHasRawBody;
end;

function TPoseidonResponse.RawBody: TBytes;
begin
  Result := FRawBody;
end;

function TPoseidonResponse.RawContentType: string;
begin
  Result := FRawContentType;
end;

{ Cookie helpers }

function TPoseidonResponse.SetCookie(const AName, AValue: string): TPoseidonResponse;
begin
  Result := SetCookie(AName, AValue, TCookieOptions.Default);
end;

function TPoseidonResponse.SetCookie(const AName, AValue: string;
  const AOptions: TCookieOptions): TPoseidonResponse;
begin
  // CustomHeaders.Add (not SetCustomHeader) so multiple Set-Cookie headers
  // can coexist — Values[Name] would overwrite the previous cookie.
  FWebResponse.CustomHeaders.Add(
    'Set-Cookie=' + TCookieFormat.Build(AName, AValue, AOptions));
  Result := Self;
end;

function TPoseidonResponse.SetSignedCookie(const AName, AValue, ASecret: string;
  const AOptions: TCookieOptions): TPoseidonResponse;
begin
  Result := SetCookie(AName, TCookieFormat.Sign(AValue, ASecret), AOptions);
end;

function TPoseidonResponse.SetSignedCookie(const AName, AValue, ASecret: string): TPoseidonResponse;
begin
  Result := SetSignedCookie(AName, AValue, ASecret, TCookieOptions.Default);
end;

function TPoseidonResponse.ClearCookie(const AName: string; const APath: string): TPoseidonResponse;
var
  LOpts: TCookieOptions;
begin
  // Max-Age=0 (or in the past) tells the browser to evict immediately.
  LOpts := TCookieOptions.Default.WithPath(APath).WithMaxAge(-1);
  Result := SetCookie(AName, '', LOpts);
end;

end.
