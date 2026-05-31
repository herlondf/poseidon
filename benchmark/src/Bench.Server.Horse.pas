unit Bench.Server.Horse;

// Horse/CrossSocket server stub for the benchmark harness.
//
// Provides the same endpoints as TBenchPoseidonServer so comparisons are fair:
//   GET  /ping             → {"ok":true}
//   GET  /medium, /large   → pre-built JSON payloads
//   GET  /users/:id        → FakeDAO.FindByID
//   POST /users            → FakeDAO.Create_
//   GET  /users            → FakeDAO.ListAll
//
// REQUIREMENTS TO ACTIVATE:
//   1. Add Horse library to search path:
//        <horse-path>\src;
//   2. Add CrossSocket to search path:
//        <crosssocket-path>\Source;
//   3. Add {$DEFINE HORSE_CROSSSOCKET} to project options
//      OR add 'HORSE_CROSSSOCKET' to Conditional defines.
//   4. Fill in the TODOs below.
//
// Without the define, IsAvailable returns False and benchmark scenarios
// for Horse are automatically skipped.
//
// Known issue — Windows Stop deadlock:
//   CrossSocket may hang on Stop() when keep-alive connections are open.
//   Workaround: run the Horse server in a separate process and kill it on Stop.
//   See: https://github.com/digoal/poseidon#19

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Bench.FakeDAO;

type
  TBenchHorseServer = class
  private
    FDAO:        TFakeDAO;
    FPort:       Integer;
    FStartEvent: TEvent;
    // TODO: add FHorse: THorse (when HORSE_CROSSSOCKET defined)
  public
    const BASE_PORT_CS = 19998;  // Horse/CrossSocket comparison port

    constructor Create(const APort: Integer = BASE_PORT_CS);
    destructor  Destroy; override;

    procedure SetDAOLatencyMs(ALatencyMs: Integer; AMaxMs: Integer = 0);
    procedure Start;
    procedure Stop;
    function  BaseURL: string;
    function  Port: Integer;

    // True only when Horse/CrossSocket is compiled in.
    class function IsAvailable: Boolean;
  end;

implementation

constructor TBenchHorseServer.Create(const APort: Integer);
begin
  inherited Create;
  FPort       := APort;
  FDAO        := TFakeDAO.Create(0);
  FStartEvent := TEvent.Create(nil, True, False, '');
end;

destructor TBenchHorseServer.Destroy;
begin
  FStartEvent.Free;
  FreeAndNil(FDAO);
  inherited;
end;

procedure TBenchHorseServer.SetDAOLatencyMs(ALatencyMs: Integer; AMaxMs: Integer);
begin
  FDAO.LatencyMs    := ALatencyMs;
  FDAO.LatencyMaxMs := AMaxMs;
end;

procedure TBenchHorseServer.Start;
begin
  if not IsAvailable then
    raise Exception.Create(
      'Horse/CrossSocket not available. ' +
      'Define HORSE_CROSSSOCKET and add Horse to the search path.');
  // TODO: configure THorse with CrossSocket provider and register routes
end;

procedure TBenchHorseServer.Stop;
begin
  // TODO: stop Horse server; on Windows consider process isolation to avoid hang
end;

function TBenchHorseServer.BaseURL: string;
begin
  Result := 'http://127.0.0.1:' + IntToStr(FPort);
end;

function TBenchHorseServer.Port: Integer;
begin
  Result := FPort;
end;

class function TBenchHorseServer.IsAvailable: Boolean;
begin
{$IFDEF HORSE_CROSSSOCKET}
  Result := True;
{$ELSE}
  Result := False;
{$ENDIF}
end;

end.
