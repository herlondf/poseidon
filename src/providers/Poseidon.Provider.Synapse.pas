unit Poseidon.Provider.Synapse;

// Poseidon HTTP provider built on Ararat Synapse (TTCPBlockSocket).
// Thread-per-connection blocking I/O model — simplest possible HTTP server.
// Reference baseline: easy to read, easy to debug, ~2-5k req/s on Windows.
//
// Use this provider when:
//   - You want a tiny dependency footprint (no Indy, no CrossSocket)
//   - You already have Synapse in your project (FTP/SMTP/POP3 clients)
//   - You need to compile on Free Pascal / Lazarus without changes
//
// For high-throughput production REST, prefer TPoseidonProviderNative.

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Classes,
  Poseidon.Proc,
  Poseidon.Provider.Abstract;

type
  TPoseidonProviderSynapse = class(TPoseidonProviderAbstract)
  private const
    DEFAULT_HOST = '0.0.0.0';
    DEFAULT_PORT = 9000;
  private
    class var FPort:           Integer;
    class var FHost:           string;
    class var FRunning:        Boolean;
    class var FShutdownEvent:  TEvent;
    class var FAcceptThread:   TThread;
    class var FInFlightCount:  Int64;

    class function GetOrCreateEvent: TEvent;
  public
    class property Port:      Integer read FPort write FPort;
    class property Host:      string  read FHost write FHost;
    class property IsRunning: Boolean read FRunning;

    class procedure Listen; overload; override;
    class procedure Listen(APort: Integer; const AHost: string = DEFAULT_HOST;
      AOnListen: TProc = nil; AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure Listen(APort: Integer; AOnListen: TProc;
      AOnStop: TProc = nil); reintroduce; overload; static;
    class procedure StopListen; override;

    class destructor UnInitialize;
  end;

  TPoseidonSynapse = TPoseidonProviderSynapse;

implementation

uses
  System.Math,
  System.Generics.Collections,
  blcksock,
  synsock,
  Web.HTTPApp,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.WebAdapters.Synapse,
  Poseidon.Core,
  Poseidon.Exception,
  Poseidon.Problem;

const
  CRLF = #13#10;
  READ_TIMEOUT_MS = 10000;

type
  // Accept loop — non-blocking accept with 100ms poll so Stop terminates fast.
  TAcceptThread = class(TThread)
  private
    FPort:   Integer;
    FHost:   string;
    FListen: TTCPBlockSocket;
  protected
    procedure Execute; override;
  public
    constructor Create(APort: Integer; const AHost: string);
    destructor Destroy; override;
  end;

  // Worker — one per accepted socket. Reads/parses/routes/responds/closes.
  TWorkerThread = class(TThread)
  private
    FSock: TTCPBlockSocket;
    procedure HandleRequest;
    function  ReadHeaders(out AHeaderText: string; out ABody: TBytes): Boolean;
    procedure WriteResponse(AStatus: Integer; const AContentType: string;
      const ABody: TBytes; const AExtra: TArray<TPair<string,string>>);
  protected
    procedure Execute; override;
  public
    constructor Create(ASock: TTCPBlockSocket);
    destructor Destroy; override;
  end;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function StatusReason(AStatus: Integer): string;
begin
  case AStatus of
    200: Result := 'OK';
    201: Result := 'Created';
    204: Result := 'No Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    303: Result := 'See Other';
    304: Result := 'Not Modified';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    413: Result := 'Payload Too Large';
    422: Result := 'Unprocessable Entity';
    429: Result := 'Too Many Requests';
    500: Result := 'Internal Server Error';
    503: Result := 'Service Unavailable';
  else
    Result := 'Status ' + AStatus.ToString;
  end;
end;

// Parses "METHOD path?query HTTP/1.x" + headers from header block text.
procedure ParseRequestLineAndHeaders(const AText: string;
  out AMethod, APath, AQuery: string;
  out AHeaders: TArray<TPair<string,string>>);
var
  LLines: TArray<string>;
  LParts: TArray<string>;
  LFull:  string;
  LQ:     Integer;
  I, J:   Integer;
  LName:  string;
  LValue: string;
  LCount: Integer;
begin
  AMethod := '';
  APath   := '';
  AQuery  := '';
  AHeaders := nil;

  LLines := AText.Split([CRLF]);
  if Length(LLines) = 0 then Exit;

  LParts := LLines[0].Split([' ']);
  if Length(LParts) >= 2 then
  begin
    AMethod := LParts[0];
    LFull   := LParts[1];
    LQ      := Pos('?', LFull);
    if LQ > 0 then
    begin
      APath  := Copy(LFull, 1, LQ - 1);
      AQuery := Copy(LFull, LQ + 1, MaxInt);
    end
    else
      APath := LFull;
  end;

  SetLength(AHeaders, Length(LLines));
  LCount := 0;
  for I := 1 to High(LLines) do
  begin
    if LLines[I] = '' then Break;
    J := Pos(':', LLines[I]);
    if J <= 0 then Continue;
    LName  := Trim(Copy(LLines[I], 1, J - 1));
    LValue := Trim(Copy(LLines[I], J + 1, MaxInt));
    AHeaders[LCount] := TPair<string,string>.Create(LName, LValue);
    Inc(LCount);
  end;
  SetLength(AHeaders, LCount);
end;

function HeaderValue(const AHeaders: TArray<TPair<string,string>>;
  const AName: string): string;
var
  I: Integer;
begin
  for I := 0 to High(AHeaders) do
    if SameText(AHeaders[I].Key, AName) then
      Exit(AHeaders[I].Value);
  Result := '';
end;

// ---------------------------------------------------------------------------
// TAcceptThread
// ---------------------------------------------------------------------------

constructor TAcceptThread.Create(APort: Integer; const AHost: string);
begin
  FPort := APort;
  FHost := AHost;
  FListen := TTCPBlockSocket.Create;
  inherited Create(False);
end;

destructor TAcceptThread.Destroy;
begin
  FListen.Free;
  inherited;
end;

procedure TAcceptThread.Execute;
var
  LClient: TSocket;
  LSock:   TTCPBlockSocket;
begin
  FListen.CreateSocket;
  FListen.SetLinger(True, 10);
  FListen.Bind(FHost, FPort.ToString);
  if FListen.LastError <> 0 then
  begin
    Writeln(ErrOutput, '[synapse] bind failed: ', FListen.LastErrorDesc);
    Exit;
  end;
  FListen.Listen;
  if FListen.LastError <> 0 then
  begin
    Writeln(ErrOutput, '[synapse] listen failed: ', FListen.LastErrorDesc);
    Exit;
  end;

  while not Terminated do
  begin
    if FListen.CanRead(100) then
    begin
      LClient := FListen.Accept;
      if FListen.LastError = 0 then
      begin
        LSock := TTCPBlockSocket.Create;
        LSock.Socket := LClient;
        TWorkerThread.Create(LSock);
      end;
    end;
  end;
  FListen.CloseSocket;
end;

// ---------------------------------------------------------------------------
// TWorkerThread
// ---------------------------------------------------------------------------

constructor TWorkerThread.Create(ASock: TTCPBlockSocket);
begin
  FSock := ASock;
  FreeOnTerminate := True;
  inherited Create(False);
end;

destructor TWorkerThread.Destroy;
begin
  FSock.Free;
  inherited;
end;

function TWorkerThread.ReadHeaders(out AHeaderText: string;
  out ABody: TBytes): Boolean;
var
  LBuf:        TBytes;
  LChunk:      TBytes;
  LRead:       Integer;
  LEndIdx:     Integer;
  LContentLen: Integer;
  LHaveLen:    Integer;
  I:           Integer;
  LHeadersArr: TArray<TPair<string,string>>;
  LDummy1,
  LDummy2,
  LDummy3:     string;
begin
  Result := False;
  SetLength(LBuf, 0);
  LEndIdx := -1;
  SetLength(LChunk, 4096);

  // Read until we see the CRLF CRLF terminator.
  while True do
  begin
    LRead := FSock.RecvBufferEx(@LChunk[0], 1, READ_TIMEOUT_MS);
    if FSock.LastError <> 0 then Exit(False);
    if LRead <= 0 then Exit(False);

    I := Length(LBuf);
    SetLength(LBuf, I + LRead);
    Move(LChunk[0], LBuf[I], LRead);

    if Length(LBuf) >= 4 then
    begin
      for I := 0 to Length(LBuf) - 4 do
        if (LBuf[I]   = 13) and (LBuf[I+1] = 10)
        and (LBuf[I+2] = 13) and (LBuf[I+3] = 10) then
        begin
          LEndIdx := I;
          Break;
        end;
    end;
    if LEndIdx >= 0 then Break;
    if Length(LBuf) > 64 * 1024 then Exit(False);   // headers cap
  end;

  AHeaderText := TEncoding.ASCII.GetString(LBuf, 0, LEndIdx);

  // Compute Content-Length to know whether to drain a body.
  ParseRequestLineAndHeaders(AHeaderText, LDummy1, LDummy2, LDummy3, LHeadersArr);
  LContentLen := StrToIntDef(HeaderValue(LHeadersArr, 'Content-Length'), 0);

  // Any bytes already read past CRLFCRLF belong to the body.
  LHaveLen := Length(LBuf) - (LEndIdx + 4);
  if LHaveLen < 0 then LHaveLen := 0;
  SetLength(ABody, LContentLen);
  if LHaveLen > 0 then
    Move(LBuf[LEndIdx + 4], ABody[0], Min(LHaveLen, LContentLen));

  if LContentLen > LHaveLen then
  begin
    LRead := FSock.RecvBufferEx(@ABody[LHaveLen], LContentLen - LHaveLen, READ_TIMEOUT_MS);
    if FSock.LastError <> 0 then Exit(False);
    if LRead <> (LContentLen - LHaveLen) then Exit(False);
  end;

  Result := True;
end;

procedure TWorkerThread.WriteResponse(AStatus: Integer; const AContentType: string;
  const ABody: TBytes; const AExtra: TArray<TPair<string,string>>);
var
  LHdr:  TStringBuilder;
  LText: string;
  I:     Integer;
  LResp: TBytes;
  LHB:   TBytes;
begin
  LHdr := TStringBuilder.Create;
  try
    LHdr.Append('HTTP/1.1 ').Append(AStatus).Append(' ').Append(StatusReason(AStatus)).Append(CRLF);
    LHdr.Append('Content-Type: ').Append(AContentType).Append(CRLF);
    LHdr.Append('Content-Length: ').Append(Length(ABody)).Append(CRLF);
    LHdr.Append('Connection: close').Append(CRLF);
    for I := 0 to High(AExtra) do
      LHdr.Append(AExtra[I].Key).Append(': ').Append(AExtra[I].Value).Append(CRLF);
    LHdr.Append(CRLF);
    LText := LHdr.ToString;
  finally
    LHdr.Free;
  end;

  LHB := TEncoding.ASCII.GetBytes(LText);
  SetLength(LResp, Length(LHB) + Length(ABody));
  Move(LHB[0], LResp[0], Length(LHB));
  if Length(ABody) > 0 then
    Move(ABody[0], LResp[Length(LHB)], Length(ABody));

  FSock.SendBuffer(@LResp[0], Length(LResp));
end;

procedure TWorkerThread.HandleRequest;
var
  LHeaderText: string;
  LBody:       TBytes;
  LSynReq:     TSynapseHttpRequest;
  LWebReq:     TSynapseWebRequest;
  LWebRes:     TSynapseWebResponse;
  LReq:        TPoseidonRequest;
  LRes:        TPoseidonResponse;
  LCommitted:  Boolean;
  LSelf:       TWorkerThread;
begin
  if not ReadHeaders(LHeaderText, LBody) then Exit;

  ParseRequestLineAndHeaders(LHeaderText,
    LSynReq.Method, LSynReq.Path, LSynReq.QueryString, LSynReq.Headers);
  LSynReq.RemoteAddr := FSock.GetRemoteSinIP + ':' + IntToStr(FSock.GetRemoteSinPort);
  LSynReq.RawBody    := LBody;

  TInterlocked.Increment(TPoseidonProviderSynapse.FInFlightCount);
  LCommitted := False;
  LSelf := Self;
  LWebReq := TSynapseWebRequest.Create(LSynReq);
  LWebRes := TSynapseWebResponse.Create(LWebReq,
    procedure(AStatus: Integer; const AContentType: string;
      const ABody: TBytes; const AExtra: TArray<TPair<string,string>>)
    begin
      LSelf.WriteResponse(AStatus, AContentType, ABody, AExtra);
      LCommitted := True;
    end);
  LReq := TPoseidonRequest.Create(LWebReq);
  LRes := TPoseidonResponse.Create(LWebRes);
  try
    try
      TPoseidonCore.Routes.Execute(LReq, LRes);
      if not LCommitted then
        LWebRes.CommitResponse;
    except
      on E: EPoseidonException do
      begin
        var LProblem := TProblemDetail.FromException(E, LSynReq.Path);
        var LJson    := LProblem.ToJSON;
        try
          WriteResponse(E.Status.ToInteger, 'application/problem+json',
            TEncoding.UTF8.GetBytes(LJson.ToString), nil);
        finally
          LJson.Free;
        end;
      end;
      on E: Exception do
        WriteResponse(500, 'application/problem+json',
          TEncoding.UTF8.GetBytes(
            '{"type":"about:blank","title":"Internal Server Error",' +
            '"status":500,"detail":"' + E.Message + '"}'), nil);
    end;
  finally
    LReq.Free;
    LRes.Free;
    LWebRes.Free;
    LWebReq.Free;
    TInterlocked.Decrement(TPoseidonProviderSynapse.FInFlightCount);
  end;
end;

procedure TWorkerThread.Execute;
begin
  try
    HandleRequest;
  except
    on E: Exception do
      Writeln(ErrOutput, '[synapse worker] ', E.Message);
  end;
  FSock.CloseSocket;
end;

// ---------------------------------------------------------------------------
// TPoseidonProviderSynapse
// ---------------------------------------------------------------------------

class function TPoseidonProviderSynapse.GetOrCreateEvent: TEvent;
begin
  if FShutdownEvent = nil then
    FShutdownEvent := TEvent.Create;
  Result := FShutdownEvent;
end;

class procedure TPoseidonProviderSynapse.Listen;
begin
  if FPort <= 0 then FPort := DEFAULT_PORT;
  if FHost.IsEmpty then FHost := DEFAULT_HOST;

  FAcceptThread := TAcceptThread.Create(FPort, FHost);
  FRunning := True;
  DoOnListen;

  if IsConsole then
    while FRunning do
      GetOrCreateEvent.WaitFor;
end;

class procedure TPoseidonProviderSynapse.Listen(APort: Integer; const AHost: string;
  AOnListen, AOnStop: TProc);
begin
  FPort          := APort;
  FHost          := AHost;
  OnListen       := AOnListen;
  OnStopListen   := AOnStop;
  Listen;
end;

class procedure TPoseidonProviderSynapse.Listen(APort: Integer;
  AOnListen, AOnStop: TProc);
begin
  Listen(APort, DEFAULT_HOST, AOnListen, AOnStop);
end;

class procedure TPoseidonProviderSynapse.StopListen;
const
  DRAIN_TIMEOUT_MS = 30000;
  POLL_INTERVAL_MS = 50;
var
  LElapsed: Integer;
begin
  if FAcceptThread = nil then
    raise Exception.Create('Poseidon (Synapse) is not listening');

  FRunning := False;
  FAcceptThread.Terminate;
  FAcceptThread.WaitFor;
  FreeAndNil(FAcceptThread);

  LElapsed := 0;
  while (FInFlightCount > 0) and (LElapsed < DRAIN_TIMEOUT_MS) do
  begin
    Sleep(POLL_INTERVAL_MS);
    Inc(LElapsed, POLL_INTERVAL_MS);
  end;

  DoOnStopListen;
  if FShutdownEvent <> nil then
    FShutdownEvent.SetEvent;
end;

class destructor TPoseidonProviderSynapse.UnInitialize;
begin
  FreeAndNil(FShutdownEvent);
end;

initialization
  TPoseidonProviderSynapse.FPort := 0;
  TPoseidonProviderSynapse.FHost := '';

end.
