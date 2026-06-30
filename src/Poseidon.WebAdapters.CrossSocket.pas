unit Poseidon.WebAdapters.CrossSocket;

// Concrete TWebRequest / TWebResponse adapters that wrap ICrossHttpRequest /
// ICrossHttpResponse from the Delphi-Cross-Socket library, bypassing WebBroker.
// Used by TPoseidonProviderCrossSocket (IOCP on Windows, epoll on Linux).

interface

uses
  System.SysUtils,
  System.Classes,
  Web.HTTPApp,
  Net.CrossHttpServer;

type
  TCrossWebRequest = class(TWebRequest)
  private
    FConnection: ICrossHttpConnection;
    FRequest:    ICrossHttpRequest;
    function BodyStream: TMemoryStream;
  protected
    function GetStringVariable(Index: Integer): string; override;
    function GetDateVariable(Index: Integer): TDateTime; override;
    function GetIntegerVariable(Index: Integer): Int64; override;
    function GetRawContent: TBytes; override;
    function GetInternalPathInfo: string; override;
    function GetInternalScriptName: string; override;
    function GetRawPathInfo: string; override;
  public
    constructor Create(const AConnection: ICrossHttpConnection;
      const ARequest: ICrossHttpRequest);
    // Rebind to a new CrossSocket request without heap allocation (pool reuse).
    procedure Reset(const AConnection: ICrossHttpConnection;
      const ARequest: ICrossHttpRequest);
    function ReadClient(var Buffer; Count: Integer): Integer; override;
    function ReadString(Count: Integer): string; override;
    function TranslateURI(const URI: string): string; override;
    function WriteClient(var Buffer; Count: Integer): Integer; override;
    function WriteString(const AString: string): Boolean; override;
    function WriteHeaders(StatusCode: Integer;
      const ReasonString, Headers: string): Boolean; override;
    function GetFieldByName(const Name: string): string; override;
  end;

  TCrossWebResponse = class(TWebResponse)
  private
    FResponse:   ICrossHttpResponse;
    FStatusCode: Integer;
    FContent:    string;
    FLogMessage: string;
  public
    // Rebind to a new CrossSocket response without heap allocation (pool reuse).
    // Never calls ContentStream := nil via setter that would free a stream — only
    // clears our own fields. FCustomHeaders.Clear keeps the TStrings object alive.
    procedure Reset(const AResponse: ICrossHttpResponse);
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
    constructor Create(ARequest: TWebRequest;
      const AResponse: ICrossHttpResponse);
    // Applies buffered status, headers, and body to the CrossSocket response
    // and dispatches the async send.  Must be called exactly once per request.
    procedure CommitResponse;
    procedure SendResponse; override;
    procedure SendRedirect(const URI: string); override;
  end;

implementation

uses
  System.Math,
  Net.CrossSocket.Base;

{ TCrossWebRequest }

constructor TCrossWebRequest.Create(const AConnection: ICrossHttpConnection;
  const ARequest: ICrossHttpRequest);
begin
  FConnection := AConnection;
  FRequest    := ARequest;
  inherited Create;
end;

function TCrossWebRequest.BodyStream: TMemoryStream;
begin
  if (FRequest.BodyType = btBinary) and (FRequest.Body <> nil) then
  begin
    Result := TMemoryStream(FRequest.Body);
    Result.Position := 0;
  end
  else
    Result := nil;
end;

function TCrossWebRequest.GetStringVariable(Index: Integer): string;
var
  LPP: string;
  LQ:  Integer;
begin
  case Index of
    0:    Result := FRequest.Method;
    2:    Result := FRequest.PathAndParams;
    3:    begin
            LPP := FRequest.PathAndParams;
            LQ  := Pos('?', LPP);
            if LQ > 0 then Result := Copy(LPP, LQ + 1, MaxInt)
            else Result := '';
          end;
    4, 5: Result := FRequest.Path;
    10:   Result := FRequest.HostName;
    15:   Result := FRequest.ContentType;
    16:   Result := FRequest.Header['Connection'];
    20:   Result := FRequest.Header['Accept'];
    21,
    22:   Result := (FConnection as ICrossConnection).PeerAddr;
    27:   Result := FRequest.Header['Cookie'];
    28:   Result := FRequest.Header['Authorization'];
  else
    Result := '';
  end;
end;

function TCrossWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

function TCrossWebRequest.GetIntegerVariable(Index: Integer): Int64;
var
  LStream: TMemoryStream;
  LCL:     string;
begin
  case Index of
    11: // ContentLength
      begin
        LStream := BodyStream;
        if LStream <> nil then
          Result := LStream.Size
        else
        begin
          LCL := FRequest.Header['Content-Length'];
          if LCL <> '' then Result := StrToInt64Def(LCL, 0)
          else Result := 0;
        end;
      end;
  else
    Result := 0;
  end;
end;

function TCrossWebRequest.GetRawContent: TBytes;
var
  LStream: TMemoryStream;
begin
  LStream := BodyStream;
  if LStream = nil then
  begin
    SetLength(Result, 0);
    Exit;
  end;
  LStream.Position := 0;
  SetLength(Result, LStream.Size);
  if LStream.Size > 0 then
    LStream.ReadBuffer(Result[0], LStream.Size);
end;

function TCrossWebRequest.GetInternalPathInfo: string;
begin
  Result := FRequest.Path;
end;

function TCrossWebRequest.GetInternalScriptName: string;
begin
  Result := '';
end;

function TCrossWebRequest.GetRawPathInfo: string;
begin
  Result := FRequest.Path;
end;

procedure TCrossWebRequest.Reset(const AConnection: ICrossHttpConnection;
  const ARequest: ICrossHttpRequest);
begin
  FConnection := AConnection;
  FRequest    := ARequest;
  UpdateMethodType;  // FMethodType must reflect the new request — pool reuse retains stale value otherwise
end;

function TCrossWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
var
  LStream: TMemoryStream;
begin
  LStream := BodyStream;
  if LStream = nil then Result := 0
  else Result := LStream.Read(Buffer, Count);
end;

function TCrossWebRequest.ReadString(Count: Integer): string;
var
  LStream: TMemoryStream;
  LBytes:  TBytes;
  LRead:   Integer;
begin
  LStream := BodyStream;
  if LStream = nil then
  begin
    Result := '';
    Exit;
  end;
  LStream.Position := 0;
  LRead := Min(Count, LStream.Size);
  SetLength(LBytes, LRead);
  if LRead > 0 then
    LStream.ReadBuffer(LBytes[0], LRead);
  Result := TEncoding.UTF8.GetString(LBytes);
end;

function TCrossWebRequest.TranslateURI(const URI: string): string;
begin
  Result := URI;
end;

function TCrossWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin
  Result := Count;
end;

function TCrossWebRequest.WriteString(const AString: string): Boolean;
begin
  Result := True;
end;

function TCrossWebRequest.WriteHeaders(StatusCode: Integer;
  const ReasonString, Headers: string): Boolean;
begin
  Result := True;
end;

function TCrossWebRequest.GetFieldByName(const Name: string): string;
begin
  Result := FRequest.Header[Name];
end;

{ TCrossWebResponse }

constructor TCrossWebResponse.Create(ARequest: TWebRequest;
  const AResponse: ICrossHttpResponse);
begin
  FResponse   := AResponse;
  FStatusCode := 200;
  inherited Create(ARequest);
end;

function TCrossWebResponse.GetStringVariable(Index: Integer): string;
begin
  case Index of
    8:  Result := FResponse.ContentType;
  else
    Result := '';
  end;
end;

procedure TCrossWebResponse.SetStringVariable(Index: Integer; const Value: string);
begin
  case Index of
    8: FResponse.ContentType := Value;
  end;
end;

function TCrossWebResponse.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

procedure TCrossWebResponse.SetDateVariable(Index: Integer; const Value: TDateTime);
begin
end;

function TCrossWebResponse.GetIntegerVariable(Index: Integer): Int64;
begin
  Result := 0;
end;

procedure TCrossWebResponse.SetIntegerVariable(Index: Integer; Value: Int64);
begin
end;

function TCrossWebResponse.GetContent: string;
begin
  Result := FContent;
end;

procedure TCrossWebResponse.SetContent(const Value: string);
begin
  FContent := Value;
end;

function TCrossWebResponse.GetStatusCode: Integer;
begin
  Result := FStatusCode;
end;

procedure TCrossWebResponse.SetStatusCode(Value: Integer);
begin
  FStatusCode := Value;
end;

function TCrossWebResponse.GetLogMessage: string;
begin
  Result := FLogMessage;
end;

procedure TCrossWebResponse.SetLogMessage(const Value: string);
begin
  FLogMessage := Value;
end;

procedure TCrossWebResponse.Reset(const AResponse: ICrossHttpResponse);
begin
  FResponse   := AResponse;
  FStatusCode := 200;
  FContent    := '';
  FLogMessage := '';
  FCustomHeaders.Clear;
  // ContentStream setter checks FOwnsContent (always False here) before freeing —
  // safe to nil; clears TWebResponse.FContentStream without touching CrossSocket streams.
  ContentStream := nil;
end;

procedure TCrossWebResponse.CommitResponse;
var
  I:      Integer;
  LBytes: TBytes;
begin
  FResponse.StatusCode := FStatusCode;
  // Apply custom headers (Content-Type, Location, X-* etc.)
  for I := 0 to FCustomHeaders.Count - 1 do
  begin
    if SameText(FCustomHeaders.Names[I], 'Content-Type') then
      FResponse.ContentType := FCustomHeaders.ValueFromIndex[I]
    else if SameText(FCustomHeaders.Names[I], 'Location') then
      FResponse.Location := FCustomHeaders.ValueFromIndex[I]
    else
      FResponse.Header[FCustomHeaders.Names[I]] := FCustomHeaders.ValueFromIndex[I];
  end;
  // Send body — ContentStream takes priority; fall back to text; empty → status only
  if (ContentStream <> nil) and (ContentStream.Size > 0) and (FContent = '') then
  begin
    // Read into managed bytes so the async send outlives the stream object
    ContentStream.Position := 0;
    SetLength(LBytes, ContentStream.Size);
    ContentStream.ReadBuffer(LBytes[0], ContentStream.Size);
    FResponse.Send(LBytes);
  end
  else if FContent <> '' then
    FResponse.Send(FContent)
  else
    FResponse.SendStatus(FStatusCode);
end;

procedure TCrossWebResponse.SendResponse;
begin
  CommitResponse;
end;

procedure TCrossWebResponse.SendRedirect(const URI: string);
begin
  FStatusCode          := 303;
  FResponse.StatusCode := 303;
  FResponse.Location   := URI;
  FResponse.SendStatus(303);
end;

end.
