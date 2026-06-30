unit Poseidon.Net.WebAdapters.Native;

// Concrete TWebRequest / TWebResponse adapters for TPoseidonNativeServer.
// Bridges TPoseidonNativeRequest (record from the IOCP layer) to the WebBroker
// abstract interface expected by TPoseidonCore.Routes.Execute.
//
// TNativeWebResponse.CommitResponse invokes FOnFlush, writing response data
// back to the out-parameters of TPoseidonProviderNative.HandleRequest.
// The socket is never touched here — all socket I/O is in Poseidon.Net.HttpServer.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Web.HTTPApp,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer;

type
  TNativeFlushProc = reference to procedure(
    AStatus: Integer; const AContentType: string;
    const ABody: TBytes; const AExtra: TArray<TPair<string,string>>);

  TNativeWebRequest = class(TWebRequest)
  private
    FReq: TPoseidonNativeRequest;  // value copy — safe for pool reuse
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
    constructor Create(const AReq: TPoseidonNativeRequest);
    procedure Reset(const AReq: TPoseidonNativeRequest);
    function GetFieldByName(const Name: string): string; override;
    function ReadClient(var Buffer; Count: Integer): Integer; override;
    function ReadString(Count: Integer): string; override;
    function TranslateURI(const URI: string): string; override;
    function WriteClient(var Buffer; Count: Integer): Integer; override;
    function WriteString(const AString: string): Boolean; override;
    function WriteHeaders(StatusCode: Integer;
      const ReasonString, Headers: string): Boolean; override;
  end;

  TNativeWebResponse = class(TWebResponse)
  private
    FStatusCode: Integer;
    FContent:    string;
    FLogMessage: string;
    FOnFlush:    TNativeFlushProc;
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
    constructor Create(ARequest: TWebRequest; const AOnFlush: TNativeFlushProc);
    procedure Reset(const AOnFlush: TNativeFlushProc);
    // Packages status, headers, and body then calls FOnFlush exactly once.
    procedure CommitResponse;
    procedure SendResponse; override;
    procedure SendRedirect(const URI: string); override;
  end;

implementation

uses
  System.Math;

// ---------------------------------------------------------------------------
// TNativeWebRequest
// ---------------------------------------------------------------------------

constructor TNativeWebRequest.Create(const AReq: TPoseidonNativeRequest);
begin
  FReq := AReq;    // copies managed array refs (TBytes, TArray<TPair>)
  inherited Create;
end;

procedure TNativeWebRequest.Reset(const AReq: TPoseidonNativeRequest);
var
  LCookie: string;
begin
  FReq := AReq;
  UpdateMethodType;  // FMethodType must reflect the new request — pool reuse retains stale value otherwise

  // Optimization: only re-parse QueryFields/CookieFields when the underlying
  // data actually changed.  For most API requests (e.g. /ping, /json), both
  // QueryString and Cookie are empty — skipping the Clear+Extract saves ~2-3%
  // throughput under high concurrency.
  //
  // TWebRequest's Extract* methods APPEND to TStrings without calling .Clear
  // first, so we must Clear before re-extracting when data is present.
  if FReq.QueryString <> '' then
  begin
    QueryFields.Clear;
    ExtractQueryFields(QueryFields);
  end
  else if QueryFields.Count > 0 then
    QueryFields.Clear;

  LCookie := _Header('Cookie');
  if LCookie <> '' then
  begin
    CookieFields.Clear;
    ExtractCookieFields(CookieFields);
  end
  else if CookieFields.Count > 0 then
    CookieFields.Clear;
end;

function TNativeWebRequest._Header(const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(FReq.Headers) do
    if SameText(FReq.Headers[I].Key, AName) then
      Exit(FReq.Headers[I].Value);
  Result := '';
end;

function TNativeWebRequest.GetStringVariable(Index: Integer): string;
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
    21,
    22:    Result := FReq.RemoteAddr;
    27:    Result := _Header('Cookie');
    28:    Result := _Header('Authorization');
  else
    Result := '';
  end;
end;

function TNativeWebRequest.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

function TNativeWebRequest.GetIntegerVariable(Index: Integer): Int64;
begin
  case Index of
    11: Result := Length(FReq.RawBody);
  else  Result := 0;
  end;
end;

function TNativeWebRequest.GetRawContent: TBytes;
begin
  Result := FReq.RawBody;
end;

function TNativeWebRequest.GetInternalPathInfo: string;
begin
  Result := FReq.Path;
end;

function TNativeWebRequest.GetInternalScriptName: string;
begin
  Result := '';
end;

function TNativeWebRequest.GetRawPathInfo: string;
begin
  Result := FReq.Path;
end;

function TNativeWebRequest.GetFieldByName(const Name: string): string;
var
  I: Integer;
  LSB: TStringBuilder;
begin
  // 'ALL_RAW' is the ISAPI convention used by Horse.Core.Param.Header to enumerate
  // all headers via GetFieldByName. Return them in 'Key: Value\r\n' format so the
  // TStringList with NameValueSeparator=':' can parse them correctly.
  if SameText(Name, 'ALL_RAW') then
  begin
    LSB := TStringBuilder.Create;
    try
      for I := 0 to High(FReq.Headers) do
        LSB.Append(FReq.Headers[I].Key).Append(': ').Append(FReq.Headers[I].Value).Append(#13#10);
      Result := LSB.ToString;
    finally
      LSB.Free;
    end;
  end
  else
    Result := _Header(Name);
end;

function TNativeWebRequest.ReadClient(var Buffer; Count: Integer): Integer;
var
  LLen: Integer;
begin
  LLen := Min(Count, Length(FReq.RawBody));
  if LLen > 0 then
    Move(FReq.RawBody[0], Buffer, LLen);
  Result := LLen;
end;

function TNativeWebRequest.ReadString(Count: Integer): string;
var
  LLen: Integer;
begin
  LLen := Min(Count, Length(FReq.RawBody));
  if LLen = 0 then Exit('');
  Result := TEncoding.UTF8.GetString(FReq.RawBody, 0, LLen);
end;

function TNativeWebRequest.TranslateURI(const URI: string): string;
begin
  Result := URI;
end;

function TNativeWebRequest.WriteClient(var Buffer; Count: Integer): Integer;
begin
  Result := Count;
end;

function TNativeWebRequest.WriteString(const AString: string): Boolean;
begin
  Result := True;
end;

function TNativeWebRequest.WriteHeaders(StatusCode: Integer;
  const ReasonString, Headers: string): Boolean;
begin
  Result := True;
end;

// ---------------------------------------------------------------------------
// TNativeWebResponse
// ---------------------------------------------------------------------------

constructor TNativeWebResponse.Create(ARequest: TWebRequest;
  const AOnFlush: TNativeFlushProc);
begin
  FStatusCode := 200;
  FOnFlush    := AOnFlush;
  inherited Create(ARequest);
end;

procedure TNativeWebResponse.Reset(const AOnFlush: TNativeFlushProc);
begin
  FOnFlush    := AOnFlush;
  FStatusCode := 200;
  FContent    := '';
  FLogMessage := '';
  FCustomHeaders.Clear;
  // ContentStream setter: FOwnsContent is always False here — sets stream to nil safely.
  ContentStream := nil;
end;

function TNativeWebResponse.GetStringVariable(Index: Integer): string;
begin
  case Index of
    8:  Result := FCustomHeaders.Values['Content-Type'];
  else  Result := '';
  end;
end;

procedure TNativeWebResponse.SetStringVariable(Index: Integer; const Value: string);
begin
  case Index of
    8: FCustomHeaders.Values['Content-Type'] := Value;
  end;
end;

function TNativeWebResponse.GetDateVariable(Index: Integer): TDateTime;
begin
  Result := 0;
end;

procedure TNativeWebResponse.SetDateVariable(Index: Integer; const Value: TDateTime);
begin
end;

function TNativeWebResponse.GetIntegerVariable(Index: Integer): Int64;
begin
  Result := 0;
end;

procedure TNativeWebResponse.SetIntegerVariable(Index: Integer; Value: Int64);
begin
end;

function TNativeWebResponse.GetContent: string;
begin
  Result := FContent;
end;

procedure TNativeWebResponse.SetContent(const Value: string);
begin
  FContent := Value;
end;

function TNativeWebResponse.GetStatusCode: Integer;
begin
  Result := FStatusCode;
end;

procedure TNativeWebResponse.SetStatusCode(Value: Integer);
begin
  FStatusCode := Value;
end;

function TNativeWebResponse.GetLogMessage: string;
begin
  Result := FLogMessage;
end;

procedure TNativeWebResponse.SetLogMessage(const Value: string);
begin
  FLogMessage := Value;
end;

procedure TNativeWebResponse.CommitResponse;
var
  I:           Integer;
  LCT:         string;
  LBody:       TBytes;
  LExtra:      TArray<TPair<string,string>>;
  LExtraCount: Integer;
begin
  LCT := '';

  // Fast path: skip header iteration when no custom headers (99% of API requests)
  if FCustomHeaders.Count > 0 then
  begin
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
  end;

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

procedure TNativeWebResponse.SendResponse;
begin
  CommitResponse;
end;

procedure TNativeWebResponse.SendRedirect(const URI: string);
var
  LExtra: TArray<TPair<string,string>>;
begin
  SetLength(LExtra, 1);
  LExtra[0] := TPair<string,string>.Create('Location', URI);
  if Assigned(FOnFlush) then
    FOnFlush(303, 'text/plain', nil, LExtra);
end;

end.
