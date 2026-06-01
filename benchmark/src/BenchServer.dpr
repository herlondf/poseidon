program BenchServer;

{$APPTYPE CONSOLE}

// Servidor HTTP standalone para benchmark Linux.
//
// Compilar com dcclinux64 usando:
//   -DPOSEIDON;NOGUI;RELEASE          → Poseidon native (IOCP/epoll)
//   -DHORSE_CROSSSOCKET;NOGUI;RELEASE → Horse/CrossSocket
//
// Endpoints:
//   GET  /ping            → {"ok":true}        (healthcheck ALB)
//   GET  /medium          → JSON ~1 KB
//   GET  /large           → JSON ~50 KB
//   POST /dao/slow        → FakeDAO.Sleep(30000) — emula SEFAZ/NFCe
//   GET  /status          → {"workers":N,"uptime_ms":T}

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
{$IFDEF POSEIDON}
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer,
{$ENDIF}
  Bench.FakeDAO;

const
  HTTP_PORT  = 8080;
  MEDIUM_LEN = 1024;
  LARGE_LEN  = 51200;

var
  GStartedAt: TDateTime;

// ---------------------------------------------------------------------------
// Payloads pré-gerados
// ---------------------------------------------------------------------------

function MediumJSON: string;
var
  I: Integer;
  LFields: string;
begin
  LFields := '';
  for I := 1 to 20 do
  begin
    if I > 1 then LFields := LFields + ',';
    LFields := LFields + Format('"field%d":"value%d"', [I, I]);
  end;
  Result := '{' + LFields + '}';
end;

function LargeJSON: string;
var
  I: Integer;
  LItems: string;
begin
  LItems := '';
  for I := 1 to 500 do
  begin
    if I > 1 then LItems := LItems + ',';
    LItems := LItems + Format('{"id":%d,"name":"item%d","value":%d}', [I, I, I * 7]);
  end;
  Result := '[' + LItems + ']';
end;

{$IFDEF POSEIDON}
// ---------------------------------------------------------------------------
// Poseidon handler
// ---------------------------------------------------------------------------
var
  GMedium:    TBytes;
  GLarge:     TBytes;
  GDAO:       TFakeDAO;
  GStopEvent: TEvent;

procedure HandleRequest(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
var
  LUptime: Int64;
  LRec:    TFakeUserRecord;
begin
  AStatus       := 200;
  AContentType  := 'application/json';
  AExtraHeaders := [];

  if AReq.Path = '/ping' then
  begin
    ABody := TEncoding.UTF8.GetBytes('{"ok":true}');
  end
  else if AReq.Path = '/medium' then
  begin
    ABody := GMedium;
  end
  else if AReq.Path = '/large' then
  begin
    ABody := GLarge;
  end
  else if (AReq.Method = 'POST') and (AReq.Path = '/dao/slow') then
  begin
    GDAO.FindByID(1, LRec);  // blocks for DAO_LATENCY_SEFAZ ms
    ABody := TEncoding.UTF8.GetBytes('{"ok":true}');
  end
  else if AReq.Path = '/status' then
  begin
    LUptime := Round((Now - GStartedAt) * 86400000);
    ABody   := TEncoding.UTF8.GetBytes(
      Format('{"workers":%d,"uptime_ms":%d}',
        [TThread.ProcessorCount * 2, LUptime]));
  end
  else
  begin
    AStatus := 404;
    ABody   := TEncoding.UTF8.GetBytes('{"error":"not found"}');
  end;
end;

procedure RunPoseidon;
var
  LServer: TPoseidonNativeServer;
  LReady:  TEvent;
begin
  WriteLn('BenchServer [Poseidon] starting on port ' + IntToStr(HTTP_PORT));
  LReady      := TEvent.Create(nil, True, False, '');
  GStopEvent  := TEvent.Create(nil, True, False, '');
  GMedium     := TEncoding.UTF8.GetBytes(MediumJSON);
  GLarge      := TEncoding.UTF8.GetBytes(LargeJSON);
  GDAO        := TFakeDAO.Create(DAO_LATENCY_SEFAZ);
  GStartedAt  := Now;
  LServer     := TPoseidonNativeServer.Create;
  try
    LServer.Listen('0.0.0.0', HTTP_PORT,
      procedure(const AReq: TPoseidonNativeRequest; out AStatus: Integer;
        out AContentType: string; out ABody: TBytes;
        out AExtraHeaders: TArray<TPair<string,string>>)
      begin
        HandleRequest(AReq, AStatus, AContentType, ABody, AExtraHeaders);
      end,
      procedure begin LReady.SetEvent; WriteLn('Listening.'); end);
    GStopEvent.WaitFor(INFINITE);  // Block until Docker SIGTERM kills process
  finally
    LServer.Free;
    GDAO.Free;
    LReady.Free;
    GStopEvent.Free;
  end;
end;
{$ENDIF}

begin
  try
{$IFDEF POSEIDON}
    RunPoseidon;
{$ELSE}
    WriteLn('ERROR: compile with -DPOSEIDON or -DHORSE_CROSSSOCKET');
    ExitCode := 1;
{$ENDIF}
  except
    on E: Exception do
    begin
      WriteLn('FATAL: ' + E.ClassName + ': ' + E.Message);
      ExitCode := 1;
    end;
  end;
end.
