unit Bench.Handlers;

// Shared HTTP handlers for the benchmark comparison.
// Implements 4 endpoints matching the Horse PR #481 methodology:
//   /ping   — CPU-only, zero I/O
//   /json   — JSON serialization overhead
//   /upload — Large body ingestion (5 MB)
//   /delay  — Simulated DB blocking (50 ms)

interface

uses
  System.SysUtils,
  System.Generics.Collections,
  Poseidon.Net.Types;

// Poseidon native callback — dispatches to the 4 endpoints by path.
procedure PoseidonHandler(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);

implementation

uses
  System.Classes;

const
  JSON_RESPONSE = '{"message":"Hello, World!","framework":"Poseidon"}';

procedure PoseidonHandler(
  const AReq:          TPoseidonNativeRequest;
  out   AStatus:       Integer;
  out   AContentType:  string;
  out   ABody:         TBytes;
  out   AExtraHeaders: TArray<TPair<string,string>>);
begin
  AExtraHeaders := [];
  AContentType  := 'application/json';

  if AReq.Path = '/ping' then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes('"pong"');
  end
  else if AReq.Path = '/json' then
  begin
    AStatus := 200;
    ABody   := TEncoding.UTF8.GetBytes(JSON_RESPONSE);
  end
  else if AReq.Path = '/upload' then
  begin
    AStatus      := 200;
    AContentType := 'text/plain';
    ABody        := TEncoding.UTF8.GetBytes('received:' + IntToStr(Length(AReq.RawBody)));
  end
  else if AReq.Path = '/delay' then
  begin
    Sleep(50);
    AStatus      := 200;
    AContentType := 'text/plain';
    ABody        := TEncoding.UTF8.GetBytes('ok');
  end
  else
  begin
    AStatus := 404;
    ABody   := TEncoding.UTF8.GetBytes('{"error":"not found"}');
  end;
end;

end.
