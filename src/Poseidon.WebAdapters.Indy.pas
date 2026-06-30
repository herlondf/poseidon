unit Poseidon.WebAdapters.Indy;

// Concrete TWebRequest / TWebResponse adapters that wrap TIdHTTPRequestInfo /
// TIdHTTPResponseInfo directly, bypassing TIdHTTPWebBrokerBridge.
// Used by TPoseidonProviderIndyDirect to eliminate the WebBroker dispatch layer.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Math,
  Web.HTTPApp,
  IdContext,
  IdCustomHTTPServer;

type
  TIndyWebRequest = class(TWebRequest)
  private
    FContext:     TIdContext;
    FRequestInfo: TIdHTTPRequestInfo;
  protected
    function GetStringVariable(Index: Integer): string; override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    function GetIntegerVariable(Index: Integer): Int64; override;
    function GetRawContent: TBytes; override;
    function GetInternalPathInfo: string; override;
    function GetInternalScriptName: string; override;
    function GetRawPathInfo: string; override;
  public
    constructor Create(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo);
    function ReadClient(var Buffer; Count: Integer): Integer; override;
    function ReadString(Count: Integer): string; override;
    function TranslateURI(const URI: string): string; override;
    function WriteClient(var Buffer; Count: Integer): Integer; override;
    function WriteString(const AString: string): Boolean; override;
    function WriteHeaders(StatusCode: Integer;
      const ReasonString, Headers: string): Boolean; override;
    function GetFieldByName(const Name: string): string; override;
  end;

  TIndyWebResponse = class(TWebResponse)
  private
    FResponseInfo: TIdHTTPResponseInfo;
    FStatusCode:   Integer;
    FLogMessage:   string;
  protected
    function GetStringVariable(Index: Integer): string; override;
    procedure SetStringVariable(Index: Integer; const Value: string); override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    procedure SetDateVariable(Index: Integer; const Value: TDateTime); override;
    function GetIntegerVariable(Index: Integer): Int64; override;
    procedure SetIntegerVariable(Index: Integer; Value: Int64); override;
    function GetContent: string; override;
    procedure SetContent(const Value: string); override;
    function GetStatusCode: Integer; override;
    procedure SetStatusCode(Value: Integer); override;
    function GetLogMessage: string; override;
    procedure SetLogMessage(const Value: string); override;
  public
    constructor Create(ARequest: TWebRequest; AResponseInfo: TIdHTTPResponseInfo);
    // Copies FCustomHeaders (populated by TWebResponse.SetCustomHeader) to Indy.
    procedure CommitHeaders;
    procedure SendResponse; override;
    procedure SendRedirect(const URI: string); override;
  end;

implementation

{ TIndyWebRequest }

constructor TIndyWebRequest.Create(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo);
begin
  FContext     := AContext;
  FRequestInfo := ARequestInfo;
  inherited Create;
end;

function TIndyWebRequest.GetStringVariable(Index: Integer): string;
begin
  // Indices follow Web.HTTPApp TWebRequest property declarations.
  case Index of
    0:  Result := FRequestInfo.Command;
    2:  Result := FRequestInfo.URI;            // full path+query
    3:  Result := FRequestInfo.QueryParams;
    4:  Result := FRequestInfo.Document;       // path only
    5:  Result := FRequestInfo.Document;
    10: Result := FRequestInfo.Host;
    15: Result := FRequestInfo.ContentType;
    16: Result := FRequestInfo.RawHeaders.Values['Connection'];
    20: Result := FRequestInfo.RawHeaders.Values['Accept'];
    21: Result := FContext.Binding.PeerIP;
    22: Result := FContext.Binding.PeerIP;
    27: Result := FRequestInfo.RawHeaders.Values['Cookie'];
    28: Result := FRequestInfo.RawHeaders.Values['Authorization'];
  else
    Result := '';
  end;
end;

function TIndyWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

function TIndyWebRequest.GetIntegerVariable(Index: Integer): Int64;
begin
  case Index of
    11: // ContentLength
      if FRequestInfo.PostStream <> nil then
        Result := FRequestInfo.PostStream.Size
      else
        Result := 0;
    24: Result := FContext.Binding.Port;  // ServerPort
  else
    Result := 0;
  end;
end;

function TIndyWebRequest.GetRawContent: TBytes;
var
  LStream: TStream;
begin
  LStream := FRequestInfo.PostStream;
  if (LStream = nil) or (LStream.Size = 0) then
  begin
    Result := nil;
    Exit;
  end;
  LStream.Position := 0;
  SetLength(Result, LStream.Size);
  LStream.ReadBuffer(Result[0], LStream.Size);
end;

function TIndyWebRequest.GetInternalPathInfo: string;
begin
  Result := FRequestInfo.Document;
end;

function TIndyWebRequest.GetInternalScriptName: string;
begin
  Result := '';
end;

function TIndyWebRequest.GetRawPathInfo: string;
begin
  Result := FRequestInfo.Document;
end;

function TIndyWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
var
  LStream: TStream;
begin
  LStream := FRequestInfo.PostStream;
  if (LStream = nil) or (LStream.Size = 0) then
    Result := 0
  else
    Result := LStream.Read(Buffer, Count);
end;

function TIndyWebRequest.ReadString(Count: Integer): string;
var
  LStream: TStream;
  LBytes:  TBytes;
  LRead:   Integer;
begin
  LStream := FRequestInfo.PostStream;
  if (LStream = nil) or (LStream.Size = 0) then
  begin
    Result := '';
    Exit;
  end;
  LStream.Position := 0;
  LRead := Min(Count, LStream.Size);
  SetLength(LBytes, LRead);
  LStream.ReadBuffer(LBytes[0], LRead);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function TIndyWebRequest.TranslateURI(const URI: string): string;
begin
  Result := URI;
end;

function TIndyWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin
  Result := Count;
end;

function TIndyWebRequest.WriteString(const AString: string): Boolean;
begin
  Result := True;
end;

function TIndyWebRequest.WriteHeaders(StatusCode: Integer;
  const ReasonString, Headers: string): Boolean;
begin
  Result := True;
end;

function TIndyWebRequest.GetFieldByName(const Name: string): string;
begin
  Result := FRequestInfo.RawHeaders.Values[Name];
end;

{ TIndyWebResponse }

constructor TIndyWebResponse.Create(ARequest: TWebRequest;
  AResponseInfo: TIdHTTPResponseInfo);
begin
  FResponseInfo := AResponseInfo;
  FStatusCode   := 200;
  inherited Create(ARequest);
end;

function TIndyWebResponse.GetStringVariable(Index: Integer): string;
begin
  case Index of
    8:  Result := FResponseInfo.ContentType;
  else
    Result := '';
  end;
end;

procedure TIndyWebResponse.SetStringVariable(Index: Integer; const Value: string);
begin
  case Index of
    8: FResponseInfo.ContentType := Value;
  end;
end;

function TIndyWebResponse.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

procedure TIndyWebResponse.SetDateVariable(Index: Integer; const Value: TDateTime);
begin
end;

function TIndyWebResponse.GetIntegerVariable(Index: Integer): Int64;
begin
  Result := 0;
end;

procedure TIndyWebResponse.SetIntegerVariable(Index: Integer; Value: Int64);
begin
end;

function TIndyWebResponse.GetContent: string;
begin
  Result := FResponseInfo.ContentText;
end;

procedure TIndyWebResponse.SetContent(const Value: string);
begin
  FResponseInfo.ContentText := Value;
end;

function TIndyWebResponse.GetStatusCode: Integer;
begin
  Result := FStatusCode;
end;

procedure TIndyWebResponse.SetStatusCode(Value: Integer);
begin
  FStatusCode           := Value;
  FResponseInfo.ResponseNo := Value;
end;

function TIndyWebResponse.GetLogMessage: string;
begin
  Result := FLogMessage;
end;

procedure TIndyWebResponse.SetLogMessage(const Value: string);
begin
  FLogMessage := Value;
end;

procedure TIndyWebResponse.CommitHeaders;
var
  I: Integer;
begin
  for I := 0 to FCustomHeaders.Count - 1 do
    FResponseInfo.CustomHeaders.Values[FCustomHeaders.Names[I]] :=
      FCustomHeaders.ValueFromIndex[I];
end;

procedure TIndyWebResponse.SendResponse;
begin
  FResponseInfo.ResponseNo := FStatusCode;
  CommitHeaders;
end;

procedure TIndyWebResponse.SendRedirect(const URI: string);
begin
  FStatusCode := 303;
  FResponseInfo.Redirect(URI);
end;

end.
