program BenchServer.PoseidonFramework;
// Poseidon Framework (router + middleware pipeline + Native IOCP/epoll)
// This is the unified framework — TPoseidon = TPoseidonProviderNative
{$APPTYPE CONSOLE}
uses
  System.SysUtils,
  Poseidon;
var LPort: Integer;
begin
  LPort := StrToIntDef(GetEnvironmentVariable('BENCH_PORT'), 9801);

  TPoseidon.Get('/ping',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.ContentType('application/json').Send('"pong"');
    end);

  TPoseidon.Get('/json',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.ContentType('application/json')
        .Send('{"message":"Hello, World!","framework":"Poseidon"}');
    end);

  TPoseidon.Post('/upload',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Res.ContentType('text/plain')
        .Send('received:' + IntToStr(Length(Req.RawBody)));
    end);

  TPoseidon.Get('/delay',
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
    begin
      Sleep(50);
      Res.ContentType('text/plain').Send('ok');
    end);

  Writeln(Format('[Poseidon Framework] port %d', [LPort]));
  TPoseidon.Listen(LPort);
end.
