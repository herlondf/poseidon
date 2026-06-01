unit Bench.Server.Poseidon;

// Servidor HTTP local embutido para o benchmark usando TPoseidonNativeServer.
// Cada instância escuta em uma porta dedicada.
//
// Endpoints:
//   GET  /ping             → {"ok":true}           (28 bytes)
//   GET  /medium           → JSON object ~1KB
//   GET  /large            → JSON array ~50KB
//   GET  /xlarge           → JSON array ~512KB
//   POST /echo             → devolve body recebido
//   GET  /fail             → sempre HTTP 500
//   GET  /users/:id        → FakeDAO.FindByID (latência configurável)
//   POST /users            → FakeDAO.Create_
//   PUT  /users/:id        → FakeDAO.Update
//   DELETE /users/:id      → FakeDAO.Delete
//   GET  /users            → FakeDAO.ListAll (page+pageSize)

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.Generics.Defaults,
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer,
  Bench.FakeDAO;

type
  // Alias avoids >> tokenizer issue in Delphi 11 class declarations.
  TBenchExtraHeaders = TArray<TPair<string, string>>;

  TBenchPoseidonServer = class
  private
    FServer:      TPoseidonNativeServer;
    FPort:        Integer;
    FStartEvent:  TEvent;
    FThread:      TThread;
    FMediumJSON:  string;
    FLargeJSON:   string;
    FXLargeJSON:  string;
    FDAO:         TFakeDAO;
    procedure BuildPayloads;
    procedure HandleRequest(
      const AReq:          TPoseidonNativeRequest;
      out   AStatus:       Integer;
      out   AContentType:  string;
      out   ABody:         TBytes;
      out   AExtraHeaders: TBenchExtraHeaders
    );
    procedure HandleUsersCRUD(
      const AReq:          TPoseidonNativeRequest;
      out   AStatus:       Integer;
      out   ABody:         TBytes
    );
  public
    const BASE_PORT_W4   = 19990;
    const BASE_PORT_AUTO = 19991;
    const BASE_PORT_GZIP = 19992;
    const BASE_PORT_SSL  = 19993;

    constructor Create(const APort: Integer);
    destructor  Destroy; override;

    // Configura antes de Start
    procedure SetWorkerCount(const ACount: Integer);
    procedure EnableGzip(const AEnabled: Boolean);
    procedure ConfigureSSL(const ACertFile, AKeyFile: string);
    // DAOLatencyMs = 0 → rotas /users sem sleep (default)
    procedure SetDAOLatencyMs(ALatencyMs: Integer; AMaxMs: Integer = 0);

    // Inicia o servidor em background; bloqueia até a porta estar ativa.
    // Levanta ETimeout se não subir em 5 s.
    procedure Start;
    procedure Stop;

    function BaseURL: string;
    function Port: Integer;
  end;

implementation

{ TBenchPoseidonServer }

constructor TBenchPoseidonServer.Create(const APort: Integer);
begin
  inherited Create;
  FPort       := APort;
  FServer     := TPoseidonNativeServer.Create;
  FStartEvent := TEvent.Create(nil, True, False, '');
  FDAO        := TFakeDAO.Create(0);  // default: no latency
  BuildPayloads;
end;

destructor TBenchPoseidonServer.Destroy;
begin
  Stop;
  FStartEvent.Free;
  FreeAndNil(FDAO);
  FreeAndNil(FServer);
  inherited;
end;

procedure TBenchPoseidonServer.SetWorkerCount(const ACount: Integer);
begin
  FServer.WorkerCount := ACount;
end;

procedure TBenchPoseidonServer.EnableGzip(const AEnabled: Boolean);
begin
  FServer.CompressionEnabled := AEnabled;
end;

procedure TBenchPoseidonServer.ConfigureSSL(const ACertFile, AKeyFile: string);
begin
  FServer.ConfigureSSL(ACertFile, AKeyFile);
end;

procedure TBenchPoseidonServer.SetDAOLatencyMs(ALatencyMs: Integer; AMaxMs: Integer);
begin
  FDAO.LatencyMs    := ALatencyMs;
  FDAO.LatencyMaxMs := AMaxMs;
end;

procedure TBenchPoseidonServer.BuildPayloads;
var
  LSB: TStringBuilder;
  I:   Integer;
begin
  // ~1KB
  LSB := TStringBuilder.Create;
  try
    LSB.Append('{"status":"ok","items":[');
    for I := 1 to 10 do
    begin
      if I > 1 then LSB.Append(',');
      LSB.AppendFormat('{"id":%d,"name":"item_%d","value":%d}', [I, I, I * 7]);
    end;
    LSB.Append(']}');
    FMediumJSON := LSB.ToString;
  finally
    LSB.Free;
  end;

  // ~50KB
  LSB := TStringBuilder.Create;
  try
    LSB.Append('{"status":"ok","data":[');
    for I := 1 to 500 do
    begin
      if I > 1 then LSB.Append(',');
      LSB.AppendFormat(
        '{"id":%d,"name":"registro_%d","email":"user%d@bench.test",' +
        '"score":%d,"active":%s,"tags":["tag%d","bench","test"]}',
        [I, I, I, I * 3, BoolToStr(Odd(I), True).ToLower, I mod 10]
      );
    end;
    LSB.Append(']}');
    FLargeJSON := LSB.ToString;
  finally
    LSB.Free;
  end;

  // ~512KB
  LSB := TStringBuilder.Create;
  try
    LSB.Append('{"status":"ok","data":[');
    for I := 1 to 5000 do
    begin
      if I > 1 then LSB.Append(',');
      LSB.AppendFormat(
        '{"id":%d,"name":"registro_%d","email":"user%d@bench.test",' +
        '"score":%d,"active":%s,"tags":["tag%d","bench","test"]}',
        [I, I, I, I * 3, BoolToStr(Odd(I), True).ToLower, I mod 10]
      );
    end;
    LSB.Append(']}');
    FXLargeJSON := LSB.ToString;
  finally
    LSB.Free;
  end;
end;

procedure TBenchPoseidonServer.HandleUsersCRUD(
  const AReq:  TPoseidonNativeRequest;
  out   AStatus: Integer;
  out   ABody:   TBytes
);
var
  LIDStr: string;
  LID:    Integer;
  LRec:   TFakeUserRecord;
  LRecs:  TArray<TFakeUserRecord>;
  LPage:  Integer;
  LPS:    Integer;
  LSB:    TStringBuilder;
  I:      Integer;
  LQS:    string;
begin
  // Extract trailing :id from path (e.g. /users/42 → 42)
  LIDStr := '';
  if Length(AReq.Path) > 7 then  // '/users/' = 7 chars
    LIDStr := Copy(AReq.Path, 8, MaxInt);
  LID := StrToIntDef(LIDStr, 0);

  if (AReq.Method = 'GET') and (LID > 0) then
  begin
    // GET /users/:id
    FDAO.FindByID(LID, LRec);
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes(
      Format('{"id":%d,"name":"%s","email":"%s"}',
        [LRec.ID, LRec.Name, LRec.Email]));
  end
  else if (AReq.Method = 'GET') and (LIDStr = '') then
  begin
    // GET /users?page=1&pageSize=20
    LQS   := AReq.QueryString;
    LPage := 1;
    LPS   := 20;
    // simple parse: find page= and pageSize=
    if Pos('page=', LQS) > 0 then
      LPage := StrToIntDef(Copy(LQS, Pos('page=', LQS) + 5, 10), 1);
    if Pos('pageSize=', LQS) > 0 then
      LPS := StrToIntDef(Copy(LQS, Pos('pageSize=', LQS) + 9, 10), 20);
    if LPage < 1 then LPage := 1;
    if (LPS < 1) or (LPS > 100) then LPS := 20;
    LRecs := FDAO.ListAll(LPage, LPS);
    LSB := TStringBuilder.Create;
    try
      LSB.Append('[');
      for I := 0 to High(LRecs) do
      begin
        if I > 0 then LSB.Append(',');
        LSB.AppendFormat('{"id":%d,"name":"%s","email":"%s"}',
          [LRecs[I].ID, LRecs[I].Name, LRecs[I].Email]);
      end;
      LSB.Append(']');
      AStatus := 200;
      ABody   := TEncoding.UTF8.GetBytes(LSB.ToString);
    finally
      LSB.Free;
    end;
  end
  else if AReq.Method = 'POST' then
  begin
    // POST /users (create)
    LRec.ID    := 0;
    LRec.Name  := 'new_user';
    LRec.Email := 'new@bench.test';
    FDAO.Create_(LRec);
    AStatus := 201;
    ABody   := TEncoding.UTF8.GetBytes('{"id":0,"created":true}');
  end
  else if (AReq.Method = 'PUT') and (LID > 0) then
  begin
    LRec.ID    := LID;
    LRec.Name  := 'updated_user';
    LRec.Email := Format('updated%d@bench.test', [LID]);
    FDAO.Update(LRec);
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes('{"updated":true}');
  end
  else if (AReq.Method = 'DELETE') and (LID > 0) then
  begin
    FDAO.Delete(LID);
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes('{"deleted":true}');
  end
  else
  begin
    AStatus := 400;
    ABody   := TEncoding.UTF8.GetBytes('{"error":"bad request"}');
  end;
end;

procedure TBenchPoseidonServer.HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TBenchExtraHeaders
);
begin
  AContentType  := 'application/json; charset=utf-8';
  AExtraHeaders := [];

  if (AReq.Method = 'GET') and (AReq.Path = '/ping') then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes('{"ok":true}');
  end
  else if (AReq.Method = 'GET') and (AReq.Path = '/medium') then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes(FMediumJSON);
  end
  else if (AReq.Method = 'GET') and (AReq.Path = '/large') then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes(FLargeJSON);
  end
  else if (AReq.Method = 'GET') and (AReq.Path = '/xlarge') then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes(FXLargeJSON);
  end
  else if AReq.Method = 'POST' then
  begin
    AStatus := 200;
    ABody   := AReq.RawBody;
  end
  else if (AReq.Method = 'GET') and (AReq.Path = '/fail') then
  begin
    AStatus := 500;
    ABody   := TEncoding.UTF8.GetBytes('{"error":"forced failure"}');
  end
  else if (Length(AReq.Path) >= 6) and
          (Copy(AReq.Path, 1, 6) = '/users') then
  begin
    HandleUsersCRUD(AReq, AStatus, ABody);
  end
  else
  begin
    AStatus := 404;
    ABody   := TEncoding.UTF8.GetBytes('{"error":"not found"}');
  end;
end;

procedure TBenchPoseidonServer.Start;
var
  LWR:     TWaitResult;
  LSelf:   TBenchPoseidonServer;
  LOnReady: TProc;
begin
  LSelf    := Self;
  LOnReady := procedure begin LSelf.FStartEvent.SetEvent; end;
  FStartEvent.ResetEvent;
  FThread := TThread.CreateAnonymousThread(
    procedure
    var
      LHandler: TOnNativeRequest;
    begin
      LHandler := procedure(const AReq: TPoseidonNativeRequest;
        out AStatus: Integer; out AContentType: string;
        out ABody: TBytes; out AExtraHeaders: TBenchExtraHeaders)
      begin
        LSelf.HandleRequest(AReq, AStatus, AContentType, ABody, AExtraHeaders);
      end;
      LSelf.FServer.Listen('127.0.0.1', LSelf.FPort, LHandler, LOnReady);
    end
  );
  FThread.FreeOnTerminate := True;
  FThread.Start;

  LWR := FStartEvent.WaitFor(5000);
  if LWR <> TWaitResult.wrSignaled then
    raise Exception.CreateFmt(
      'Poseidon server (port %d) did not start within 5 s', [FPort]);
end;

procedure TBenchPoseidonServer.Stop;
begin
  if Assigned(FServer) then
    FServer.Stop;
end;

function TBenchPoseidonServer.BaseURL: string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(FPort);
end;

function TBenchPoseidonServer.Port: Integer;
begin
  Result := FPort;
end;

end.
