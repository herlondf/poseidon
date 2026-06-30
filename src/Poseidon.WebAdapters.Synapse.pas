unit Poseidon.WebAdapters.Synapse;

// Concrete TWebRequest / TWebResponse adapters for TPoseidonProviderSynapse.
// Bridges a parsed HTTP request (headers/body decoded from TTCPBlockSocket)
// to the WebBroker abstract interface expected by TPoseidonCore.Routes.Execute.
//
// TSynapseWebResponse.CommitResponse packages the response and invokes
// the registered flush proc, which writes the bytes back through the
// originating TTCPBlockSocket on the worker thread.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Web.HTTPApp;

type
  TSynapseHttpRequest = record
    Method:      string;
    Path:        string;
    QueryString: string;
    RemoteAddr:  string;
    Headers:     TArray<TPair<string,string>>;
    RawBody:     TBytes;
  end;

  TSynapseFlushProc = reference to procedure(
    AStatus: Integer; const AContentType: string;
    const ABody: TBytes; const AExtra: TArray<TPair<string,string>>);

  TSynapseWebRequest = class(TWebRequest)
  private
    FReq: TSynapseHttpRequest;
    function _Header(const AName: string): string;
  protected
    function GetStringVariable(Index: Integer): string; override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    function GetIntegerVariable(Index: Integer): Int64; override;
    function GetRawContent: TBytes; override;
    function GetInternalPathInfo: string; override;
    function GetInternalScriptName: string; override;
    function GetRawPathInfo: string; override;
  public
    constructor Create(const AReq: TSynapseHttpRequest);
    function GetFieldByName(const Name: string): string; override;
    function ReadClient(var Buffer; Count: Integer): Integer; override;
    function ReadString(Count: Integer): string; override;
    function TranslateURI(const URI: string): string; override;
    function WriteClient(var Buffer; Count: Integer): Integer; override;
    function WriteString(const AString: string): Boolean; override;
    function WriteHeaders(StatusCode: Integer;
      const ReasonString, Headers: string): Boolean; override;
  end;

  TSynapseWebResponse = class(TWebResponse)
  private
    FStatusCode: Integer;
    FContent:    string;
    FLogMessage: string;
    FOnFlush:    TSynapseFlushProc;
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
    constructor Create(ARequest: TWebRequest; const AOnFlush: TSynapseFlushProc);
    procedure CommitResponse;
    procedure SendResponse; override;
    procedure SendRedirect(const URI: string); override;
  end;

implementation

uses
  System.Math;

// ---------------------------------------------------------------------------
// TSynapseWebRequest
// ---------------------------------------------------------------------------

constructor TSynapseWebRequest.Create(const AReq: TSynapseHttpRequest);
begin
  FReq := AReq;
  inherited Create;
end;

function TSynapseWebRequest._Header(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(FReq.Headers) do
    if SameText(FReq.Headers[I].Key, AName) then
      Exit(FReq.Headers[I].Value);
  Result := '';
end;

function TSynapseWebRequest.GetStringVariable(Index: Integer): string;
begin
  case Index of
    0:     Result := FReq.Method;
    2:     if FReq.QueryString <> '' then
             Result := FReq.Path + '?' + FReq.QueryString
           else
             Result := FReq.Path;
    3:     Result := FReq.QueryString;
    4, 5:  Result := FReq.Path;
    10:    Result := _Header('Host');
    15:    Result := _Header('Content-Type');
    16:    Result := _Header('Connection');
    20:    Result := _Header('Accept');
    21, 22: Result := FReq.RemoteAddr;
    27:    Result := _Header('Cookie');
    28:    Result := _Header('Authorization');
  else
    Result := '';
  end;
end;

function TSynapseWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

function TSynapseWebRequest.GetIntegerVariable(Index: Integer): Int64;
begin
  case Index of
    11: Result := Length(FReq.RawBody);
  else
    Result := 0;
  end;
end;

function TSynapseWebRequest.GetRawContent: TBytes;
begin
  Result := FReq.RawBody;
end;

function TSynapseWebRequest.GetInternalPathInfo: string;
begin
  Result := FReq.Path;
end;

function TSynapseWebRequest.GetInternalScriptName: string;
begin
  Result := '';
end;

function TSynapseWebRequest.GetRawPathInfo: string;
begin
  Result := FReq.Path;
end;

function TSynapseWebRequest.GetFieldByName(const Name: string): string;
begin
  Result := _Header(Name);
end;

function TSynapseWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
var
  LLen: Integer;
begin
  LLen := Min(Count, Length(FReq.RawBody));
  if LLen > 0 then
    Move(FReq.RawBody[0], Buffer, LLen);
  Result := LLen;
end;

function TSynapseWebRequest.ReadString(Count: Integer): string;
var
  LLen: Integer;
begin
  LLen := Min(Count, Length(FReq.RawBody));
  if LLen = 0 then Exit('');
  Result := TEncoding.UTF8.GetString(FReq.RawBody, 0, LLen);
end;

function TSynapseWebRequest.TranslateURI(const URI: string): string;
begin
  Result := URI;
end;

function TSynapseWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin
  Result := Count;
end;

function TSynapseWebRequest.WriteString(const AString: string): Boolean;
begin
  Result := True;
end;

function TSynapseWebRequest.WriteHeaders(StatusCode: Integer;
  const ReasonString, Headers: string): Boolean;
begin
  Result := True;
end;

// ---------------------------------------------------------------------------
// TSynapseWebResponse
// ---------------------------------------------------------------------------

constructor TSynapseWebResponse.Create(ARequest: TWebRequest;
  const AOnFlush: TSynapseFlushProc);
begin
  FStatusCode := 200;
  FOnFlush    := AOnFlush;
  inherited Create(ARequest);
end;

function TSynapseWebResponse.GetStringVariable(Index: Integer): string;
begin
  case Index of
    8:  Result := FCustomHeaders.Values['Content-Type'];
  else  Result := '';
  end;
end;

procedure TSynapseWebResponse.SetStringVariable(Index: Integer; const Value: string);
begin
  case Index of
    8: FCustomHeaders.Values['Content-Type'] := Value;
  end;
end;

function TSynapseWebResponse.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

procedure TSynapseWebResponse.SetDateVariable(Index: Integer; const Value: TDateTime);
begin
end;

function TSynapseWebResponse.GetIntegerVariable(Index: Integer): Int64;
begin
  Result := 0;
end;

procedure TSynapseWebResponse.SetIntegerVariable(Index: Integer; Value: Int64);
begin
end;

function TSynapseWebResponse.GetContent: string;
begin
  Result := FContent;
end;

procedure TSynapseWebResponse.SetContent(const Value: string);
begin
  FContent := Value;
end;

function TSynapseWebResponse.GetStatusCode: Integer;
begin
  Result := FStatusCode;
end;

procedure TSynapseWebResponse.SetStatusCode(Value: Integer);
begin
  FStatusCode := Value;
end;

function TSynapseWebResponse.GetLogMessage: string;
begin
  Result := FLogMessage;
end;

procedure TSynapseWebResponse.SetLogMessage(const Value: string);
begin
  FLogMessage := Value;
end;

procedure TSynapseWebResponse.CommitResponse;
var
  I:           Integer;
  LCT:         string;
  LBody:       TBytes;
  LExtra:      TArray<TPair<string,string>>;
  LExtraCount: Integer;
begin
  LCT         := 'text/plain';
  LExtraCount := 0;
  SetLength(LExtra, FCustomHeaders.Count);

  for I := 0 to FCustomHeaders.Count - 1 do
  begin
    if SameText(FCustomHeaders.Names[I], 'Content-Type') then
      LCT := FCustomHeaders.ValueFromIndex[I]
    else
    begin
      LExtra[LExtraCount] := TPair<string,string>.Create(
        FCustomHeaders.Names[I], FCustomHeaders.ValueFromIndex[I]);
      Inc(LExtraCount);
    end;
  end;
  SetLength(LExtra, LExtraCount);

  if (ContentStream <> nil) and (ContentStream.Size > 0) and (FContent = '') then
  begin
    ContentStream.Position := 0;
    SetLength(LBody, ContentStream.Size);
    ContentStream.ReadBuffer(LBody[0], ContentStream.Size);
  end
  else if FContent <> '' then
    LBody := TEncoding.UTF8.GetBytes(FContent)
  else
    SetLength(LBody, 0);

  if Assigned(FOnFlush) then
    FOnFlush(FStatusCode, LCT, LBody, LExtra);
end;

procedure TSynapseWebResponse.SendResponse;
begin
  CommitResponse;
end;

procedure TSynapseWebResponse.SendRedirect(const URI: string);
var
  LExtra: TArray<TPair<string,string>>;
begin
  SetLength(LExtra, 1);
  LExtra[0] := TPair<string,string>.Create('Location', URI);
  if Assigned(FOnFlush) then
    FOnFlush(303, 'text/plain', nil, LExtra);
end;

end.
