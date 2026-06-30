unit Bench.HorseRoutes;

// Shared Horse route registration for all Horse-based benchmark servers.
// Registers 4 endpoints: /ping, /json, /upload, /delay

interface

procedure RegisterBenchRoutes(const AFrameworkLabel: string);

implementation

uses
  System.SysUtils,
  Horse;

var
  GLabel: string;

procedure RegisterBenchRoutes(const AFrameworkLabel: string);
begin
  GLabel := AFrameworkLabel;

  // Use 2-param callback (THorseCallbackRequestResponse) — compatible with
  // both Horse 3.2.0 and Horse Latest.  In Latest, the 3-param overload
  // (with ANext: TProc) registers as middleware, not as a route handler.
  THorse.Get('/ping',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      ARes.ContentType('application/json').Send('"pong"');
    end);

  THorse.Get('/json',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      ARes.ContentType('application/json')
        .Send('{"message":"Hello, World!","framework":"' + GLabel + '"}');
    end);

  THorse.Post('/upload',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      ARes.ContentType('text/plain')
        .Send('received:' + IntToStr(Length(AReq.Body)));
    end);

  THorse.Get('/delay',
    procedure(AReq: THorseRequest; ARes: THorseResponse)
    begin
      Sleep(50);
      ARes.ContentType('text/plain').Send('ok');
    end);
end;

end.
