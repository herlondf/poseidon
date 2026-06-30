unit Poseidon.Request;

interface

uses
  System.SysUtils,
  System.Classes,
  System.JSON,
  System.RTTI,
  System.TypInfo,
  System.NetEncoding,
  Web.HTTPApp,
  Poseidon.Commons,
  Poseidon.Core.Param,
  Poseidon.Exception,
  Poseidon.Validation,
  Poseidon.Cookies;

type
  TPoseidonRequest = class
  private
    FWebRequest: TWebRequest;
    FHeaders: TPoseidonParam;
    FQuery: TPoseidonParam;
    FParams: TPoseidonParam;
    FCookie: TPoseidonParam;
    FContentFields: TPoseidonParam;
    FBody: TObject;
    FSession: TObject;
    FOwnsSession: Boolean;
    procedure InitHeaders;
    procedure InitQuery;
    procedure InitCookie;
    procedure InitContentFields;
    function IsMultipartForm: Boolean;
    function IsFormURLEncoded: Boolean;
  public
    constructor Create(AWebRequest: TWebRequest);
    destructor Destroy; override;

    // Reset for pool reuse — reassigns the underlying web request and clears cached data
    procedure Reinitialize(AWebRequest: TWebRequest);

    // Raw string body from the request
    function RawBody: string;

    // Deserialize JSON body into a typed DTO, running validation attributes
    function BodyAs<T: class, constructor>: T;

    // Set a typed object as body (used by middleware to pre-parse body)
    function SetBody(ABody: TObject): TPoseidonRequest;

    // Retrieve a previously set body object (cast, no parsing)
    function GetBody<T: class>: T;

    function Headers: TPoseidonParam;
    function Query: TPoseidonParam;
    function Params: TPoseidonParam;
    function Cookie: TPoseidonParam;
    function ContentFields: TPoseidonParam;

    // Verifies HMAC-SHA256 signature on a previously SetSignedCookie value.
    // Returns True with the decoded plaintext in AValue when the signature is
    // valid; False otherwise. Constant-time comparison.
    function GetSignedCookie(const AName, ASecret: string; out AValue: string): Boolean;

    function MethodType: TMethodType;
    function ContentType: string;
    function Host: string;
    function PathInfo: string;

    function RawWebRequest: TWebRequest;

    // --- Horse compatibility: Session ---
    // Stores a per-request session object (JWT middleware sets this).
    // Session<T> retrieves; Session(obj) stores. Matches Horse API exactly.
    function Session<T: class>: T; overload;
    function Session(const ASession: TObject): TPoseidonRequest; overload;

    // --- Horse compatibility aliases ---
    // These methods allow Horse middlewares and handlers to work without changes.
    function Body: string; overload;
    function Body<T: class>: T; overload;
    function Body(const ABody: TObject): TPoseidonRequest; overload;
  end;

implementation

constructor TPoseidonRequest.Create(AWebRequest: TWebRequest);
begin
  FWebRequest    := AWebRequest;
  FSession       := nil;
  FOwnsSession   := False;
end;

destructor TPoseidonRequest.Destroy;
begin
  FHeaders.Free;
  FQuery.Free;
  FParams.Free;
  FCookie.Free;
  FContentFields.Free;
  FBody.Free;
  if FOwnsSession then
    FSession.Free;
  inherited;
end;

function TPoseidonRequest.RawBody: string;
begin
  Result := FWebRequest.Content;
end;

function TPoseidonRequest.BodyAs<T>: T;
var
  LJSON: TJSONObject;
  LCtx: TRttiContext;
  LType: TRttiType;
  LField: TRttiField;
  LJSONValue: TJSONValue;
  LRaw: string;
begin
  LRaw := RawBody;
  if LRaw.IsEmpty then
    raise EPoseidonException.Create('Request body is empty', THTTPStatus.BadRequest);

  LJSON := TJSONObject.ParseJSONValue(LRaw) as TJSONObject;
  if LJSON = nil then
    raise EPoseidonException.Create('Request body is not valid JSON', THTTPStatus.BadRequest);

  Result := T.Create;
  LCtx := TRttiContext.Create;
  try
    LType := LCtx.GetType(Result.ClassType);
    for LField in LType.GetFields do
    begin
      LJSONValue := LJSON.GetValue(LField.Name);
      if LJSONValue = nil then
        Continue;
      try
        case LField.FieldType.TypeKind of
          tkUString, tkString:
            LField.SetValue(Pointer(Result), TValue.From<string>(LJSONValue.Value));
          tkInteger:
            LField.SetValue(Pointer(Result), TValue.From<Integer>((LJSONValue as TJSONNumber).AsInt));
          tkInt64:
            LField.SetValue(Pointer(Result), TValue.From<Int64>((LJSONValue as TJSONNumber).AsInt64));
          tkFloat:
            LField.SetValue(Pointer(Result), TValue.From<Double>((LJSONValue as TJSONNumber).AsDouble));
          tkEnumeration:
            if LField.FieldType.Handle = TypeInfo(Boolean) then
              LField.SetValue(Pointer(Result), TValue.From<Boolean>(LJSONValue is TJSONTrue));
        end;
      except
        // Ignore type mismatch for optional fields — validation catches required ones
      end;
    end;
  finally
    LCtx.Free;
    LJSON.Free;
  end;

  TPoseidonValidator.ValidateOrRaise(Result);
end;

function TPoseidonRequest.SetBody(ABody: TObject): TPoseidonRequest;
begin
  FBody.Free;
  FBody := ABody;
  Result := Self;
end;

function TPoseidonRequest.GetBody<T>: T;
begin
  Result := T(FBody);
end;

procedure TPoseidonRequest.InitHeaders;
begin
  if FHeaders = nil then
    FHeaders := TPoseidonParam.Create
  else
    FHeaders.Clear;
  FHeaders.AddOrSet('Content-Type',     FWebRequest.ContentType);
  FHeaders.AddOrSet('Host',             FWebRequest.Host);
  FHeaders.AddOrSet('Accept',           FWebRequest.Accept);
  FHeaders.AddOrSet('Authorization',    FWebRequest.Authorization);
  FHeaders.AddOrSet('Cache-Control',    FWebRequest.CacheControl);
  FHeaders.AddOrSet('Connection',       FWebRequest.Connection);
  FHeaders.AddOrSet('Content-Encoding', FWebRequest.ContentEncoding);
  FHeaders.AddOrSet('User-Agent',       FWebRequest.UserAgent);
  // Arbitrary headers (JWT middleware uses Authorization above; compression uses this)
  FHeaders.AddOrSet('Accept-Encoding',  FWebRequest.GetFieldByName('Accept-Encoding'));
  // Proxy header — only added when present so GetOrDefault falls back to RemoteAddr correctly
  var LFwd: string;
  LFwd := FWebRequest.GetFieldByName('X-Forwarded-For');
  if not LFwd.IsEmpty then
    FHeaders.AddOrSet('X-Forwarded-For', LFwd);
end;

procedure TPoseidonRequest.InitQuery;
var
  LItem, LKey, LValue: string;
  LPos: Integer;
begin
  if FQuery = nil then
    FQuery := TPoseidonParam.Create
  else
    FQuery.Clear;
  for LItem in FWebRequest.QueryFields do
  begin
    LPos := Pos('=', LItem);
    LKey := Copy(LItem, 1, LPos - 1);
    LValue := TNetEncoding.URL.Decode(Copy(LItem, LPos + 1, MaxInt));
    if FQuery.Has(LKey) then
      FQuery.AddOrSet(LKey, FQuery.Get(LKey) + ',' + LValue)
    else
      FQuery.Add(LKey, LValue);
  end;
end;

procedure TPoseidonRequest.InitCookie;
var
  LItem: string;
  LParts: TArray<string>;
begin
  if FCookie = nil then
    FCookie := TPoseidonParam.Create
  else
    FCookie.Clear;
  for LItem in FWebRequest.CookieFields do
  begin
    LParts := LItem.Split(['='], 2);
    if Length(LParts) = 2 then
      FCookie.AddOrSet(LParts[0].Trim, LParts[1].Trim);
  end;
end;

procedure TPoseidonRequest.InitContentFields;
var
  I: Integer;
begin
  if FContentFields = nil then
    FContentFields := TPoseidonParam.Create
  else
    FContentFields.Clear;
  if not (IsMultipartForm or IsFormURLEncoded) then
    Exit;
  for I := 0 to Pred(FWebRequest.ContentFields.Count) do
    FContentFields.AddOrSet(
      FWebRequest.ContentFields.Names[I],
      FWebRequest.ContentFields.ValueFromIndex[I]);
end;

function TPoseidonRequest.IsMultipartForm: Boolean;
begin
  Result := StrLIComp(PChar(FWebRequest.ContentType), 'multipart/form-data',
    Length('multipart/form-data')) = 0;
end;

function TPoseidonRequest.IsFormURLEncoded: Boolean;
begin
  Result := StrLIComp(PChar(FWebRequest.ContentType), 'application/x-www-form-urlencoded',
    Length('application/x-www-form-urlencoded')) = 0;
end;

function TPoseidonRequest.Headers: TPoseidonParam;
begin
  if FHeaders = nil then
    InitHeaders;
  Result := FHeaders;
end;

function TPoseidonRequest.Query: TPoseidonParam;
begin
  if FQuery = nil then
    InitQuery;
  Result := FQuery;
end;

function TPoseidonRequest.Params: TPoseidonParam;
begin
  if FParams = nil then
  begin
    FParams := TPoseidonParam.Create;
    FParams.Required := True;
  end;
  Result := FParams;
end;

function TPoseidonRequest.Cookie: TPoseidonParam;
begin
  if FCookie = nil then
    InitCookie;
  Result := FCookie;
end;

function TPoseidonRequest.ContentFields: TPoseidonParam;
begin
  if FContentFields = nil then
    InitContentFields;
  Result := FContentFields;
end;

function TPoseidonRequest.MethodType: TMethodType;
begin
  Result := FWebRequest.MethodType;
end;

function TPoseidonRequest.ContentType: string;
begin
  Result := FWebRequest.ContentType;
end;

function TPoseidonRequest.Host: string;
begin
  Result := FWebRequest.Host;
end;

function TPoseidonRequest.PathInfo: string;
begin
  Result := FWebRequest.PathInfo;
  if Result.IsEmpty then
    Result := '/';
end;

function TPoseidonRequest.RawWebRequest: TWebRequest;
begin
  Result := FWebRequest;
end;

procedure TPoseidonRequest.Reinitialize(AWebRequest: TWebRequest);
begin
  FWebRequest := AWebRequest;
  // Re-init any previously accessed param (reuses its TDictionary capacity)
  if FHeaders <> nil then InitHeaders;
  if FQuery <> nil then InitQuery;
  if FCookie <> nil then InitCookie;
  if FContentFields <> nil then InitContentFields;
  // Params is populated by the router — clear without freeing
  if FParams <> nil then
  begin
    FParams.Clear;
    FParams.Required := True;
  end;
  FBody.Free;
  FBody := nil;
  if FOwnsSession then
    FreeAndNil(FSession)
  else
    FSession := nil;
  FOwnsSession := False;
end;

function TPoseidonRequest.GetSignedCookie(const AName, ASecret: string;
  out AValue: string): Boolean;
var
  LRaw: string;
begin
  Result := False;
  AValue := '';
  LRaw := Cookie.Get(AName);
  if LRaw = '' then Exit;
  Result := TCookieFormat.VerifySigned(LRaw, ASecret, AValue);
end;

// --- Horse compatibility: Session ---

function TPoseidonRequest.Session<T>: T;
begin
  Result := T(FSession);
end;

function TPoseidonRequest.Session(const ASession: TObject): TPoseidonRequest;
begin
  // If a previous session was set and we own it, free it first
  if FOwnsSession and (FSession <> nil) and (FSession <> ASession) then
    FSession.Free;
  FSession     := ASession;
  FOwnsSession := True;
  Result       := Self;
end;

// --- Horse compatibility aliases ---

function TPoseidonRequest.Body: string;
begin
  Result := RawBody;
end;

function TPoseidonRequest.Body<T>: T;
begin
  Result := GetBody<T>;
end;

function TPoseidonRequest.Body(const ABody: TObject): TPoseidonRequest;
begin
  Result := SetBody(ABody);
end;

end.
