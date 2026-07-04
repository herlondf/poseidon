unit Poseidon.Mock.WebRequest;

// Minimal concrete TWebRequest for unit testing.
// Delphi 11 TWebRequest exposes headers via GetStringVariable(index) and
// GetFieldByName — there is NO CustomHeaders property on TWebRequest (only
// on TWebResponse). All indexed properties (Host, ContentType, etc.) are
// routed through GetStringVariable.

interface

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp;

type
  TMockWebRequest = class(TWebRequest)
  private
    FMethod: string;
    FPathInfo: string;
    FContent: string;
    FContentType: string;
    FHost: string;
    FRemoteAddr: string;
    FQueryString: string;
    FCookieString: string;
    FCustomFields: TStringList;
  protected
    // Abstract protected overrides
    function GetStringVariable(Index: Integer): string; override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    function GetIntegerVariable(Index: Integer): Int64; override;
    function GetRawContent: TBytes; override;
    function GetInternalPathInfo: string; override;
    function GetInternalScriptName: string; override;
    function GetRawPathInfo: string; override;
  public
    constructor Create; reintroduce;
    destructor Destroy; override;

    // Setters for test setup
    procedure SetMethod(const AMethod: string);
    procedure SetPathInfo(const APath: string);
    procedure SetContent(const ABody: string);
    procedure SetContentType(const AContentType: string);
    procedure SetHost(const AHost: string);
    procedure SetRemoteAddr(const AIP: string);
    procedure AddQueryParam(const AKey, AValue: string);
    procedure AddCookie(const AKey, AValue: string);
    procedure AddHeader(const AKey, AValue: string);

    // Abstract public overrides
    function ReadClient(var Buffer; Count: Integer): Integer; override;
    function ReadString(Count: Integer): string; override;
    function TranslateURI(const URI: string): string; override;
    function WriteClient(var Buffer; Count: Integer): Integer; override;
    function WriteString(const AString: string): Boolean; override;
    function WriteHeaders(StatusCode: Integer; const ReasonString, Headers: string): Boolean; override;
    function GetFieldByName(const Name: string): string; override;
  end;

  TMockWebRequestFiles = class(TAbstractWebRequestFiles)
  protected
    function GetCount: Integer; override;
    function GetItem(I: Integer): TAbstractWebRequestFile; override;
  end;

implementation

{ TMockWebRequest }

constructor TMockWebRequest.Create;
begin
  // Initialize fields BEFORE inherited so GetStringVariable(0) returns 'GET'
  // when TWebRequest.Create calls UpdateMethodType -> GetStringVariable(0).
  FMethod       := 'GET';
  FContentType  := 'application/json';
  FHost         := 'localhost';
  FRemoteAddr   := '127.0.0.1';
  FPathInfo     := '/';
  FCustomFields := TStringList.Create;
  inherited Create;
end;

destructor TMockWebRequest.Destroy;
begin
  FCustomFields.Free;
  inherited;
end;

procedure TMockWebRequest.SetMethod(const AMethod: string);
begin
  FMethod := AMethod;
  UpdateMethodType;
end;

procedure TMockWebRequest.SetPathInfo(const APath: string);
begin FPathInfo := APath; end;

procedure TMockWebRequest.SetContent(const ABody: string);
begin
  FContent := ABody;
  FCustomFields.Values['Content-Length'] :=
    IntToStr(Length(TEncoding.UTF8.GetBytes(FContent)));
end;

procedure TMockWebRequest.SetContentType(const AContentType: string);
begin FContentType := AContentType; end;

procedure TMockWebRequest.SetHost(const AHost: string);
begin FHost := AHost; end;

procedure TMockWebRequest.SetRemoteAddr(const AIP: string);
begin FRemoteAddr := AIP; end;

procedure TMockWebRequest.AddQueryParam(const AKey, AValue: string);
begin
  if FQueryString <> '' then FQueryString := FQueryString + '&';
  FQueryString := FQueryString + AKey + '=' + AValue;
end;

procedure TMockWebRequest.AddCookie(const AKey, AValue: string);
begin
  if FCookieString <> '' then FCookieString := FCookieString + '; ';
  FCookieString := FCookieString + AKey + '=' + AValue;
end;

procedure TMockWebRequest.AddHeader(const AKey, AValue: string);
begin
  FCustomFields.Values[AKey] := AValue;
end;

function TMockWebRequest.GetStringVariable(Index: Integer): string;
begin
  // Indices from Web.HTTPApp TWebRequest property declarations
  case Index of
    0:  Result := FMethod;       // Method
    2:  Result := FPathInfo;     // URL
    3:  Result := FQueryString;  // Query
    4:  Result := FPathInfo;     // PathInfo
    5:  Result := FPathInfo;     // PathTranslated
    10: Result := FHost;         // Host
    15: Result := FContentType;  // ContentType
    21: Result := FRemoteAddr;   // RemoteAddr
    22: Result := FRemoteAddr;   // RemoteHost
    27: Result := FCookieString; // Cookie
    28: Result := FCustomFields.Values['Authorization']; // Authorization
  else
    Result := '';
  end;
end;

function TMockWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin Result := 0; end;

function TMockWebRequest.GetIntegerVariable(Index: Integer): Int64;
begin
  case Index of
    11: Result := Length(TEncoding.UTF8.GetBytes(FContent)); // ContentLength
    24: Result := 9000; // ServerPort
  else
    Result := 0;
  end;
end;

function TMockWebRequest.GetRawContent: TBytes;
begin
  Result := TEncoding.UTF8.GetBytes(FContent);
end;

function TMockWebRequest.GetInternalPathInfo: string;
begin Result := FPathInfo; end;

function TMockWebRequest.GetInternalScriptName: string;
begin Result := ''; end;

function TMockWebRequest.GetRawPathInfo: string;
begin Result := FPathInfo; end;

function TMockWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
begin Result := 0; end;

function TMockWebRequest.ReadString(Count: Integer): string;
begin Result := ''; end;

function TMockWebRequest.TranslateURI(const URI: string): string;
begin Result := URI; end;

function TMockWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin Result := Count; end;

function TMockWebRequest.WriteString(const AString: string): Boolean;
begin Result := True; end;

function TMockWebRequest.WriteHeaders(StatusCode: Integer; const ReasonString, Headers: string): Boolean;
begin Result := True; end;

function TMockWebRequest.GetFieldByName(const Name: string): string;
var
  I: Integer;
begin
  if SameText(Name, 'ALL_RAW') then
  begin
    // Compose ALL_RAW from custom fields so ParseAllRawHeaders can find them
    Result := '';
    for I := 0 to FCustomFields.Count - 1 do
      Result := Result + FCustomFields.Names[I] + ': ' +
        FCustomFields.ValueFromIndex[I] + #13#10;
  end
  else
    Result := FCustomFields.Values[Name];
end;

{ TMockWebRequestFiles }

function TMockWebRequestFiles.GetCount: Integer;
begin Result := 0; end;

function TMockWebRequestFiles.GetItem(I: Integer): TAbstractWebRequestFile;
begin Result := nil; end;

end.
