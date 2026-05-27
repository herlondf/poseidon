program AsyncIO.Sample.Horse;

// Sample 05 — Horse Provider
// Demonstrates using AsyncIO as the HTTP transport for the Horse framework.
//
// How it works:
//   {$DEFINE HORSE_ASYNCIO} in project options selects Horse.Provider.AsyncIO
//   as THorseProvider. All THorse.* calls (routes, middleware, Listen) dispatch
//   through AsyncIO's IOCP/epoll engine instead of Indy's blocking thread-per-conn.
//
// Search path required:
//   <asyncio>\src\               — AsyncIO core
//   <asyncio>\providers\horse\  — Horse.Provider.AsyncIO
//   <horse>\src\                — Horse framework
//
// Run:
//   curl http://localhost:9005/ping
//   curl http://localhost:9005/users
//   curl -X POST http://localhost:9005/users -H "Content-Type: application/json" -d '{"name":"Alice"}'

{$APPTYPE CONSOLE}
{$DEFINE HORSE_ASYNCIO}

uses
  System.SysUtils,
  System.JSON,
  Horse;

const
  SERVER_PORT = 9005;

procedure RegisterRoutes;
begin
  // GET /ping
  THorse.Get('/ping',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    begin
      ARes.Send('{"message":"pong"}');
    end);

  // GET /users — returns a static list
  THorse.Get('/users',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    var
      LArr: TJSONArray;
    begin
      LArr := TJSONArray.Create;
      try
        LArr.Add(TJSONObject.Create
          .AddPair('id', TJSONNumber.Create(1))
          .AddPair('name', 'Alice'));
        LArr.Add(TJSONObject.Create
          .AddPair('id', TJSONNumber.Create(2))
          .AddPair('name', 'Bob'));
        ARes.Send<TJSONArray>(LArr);
      except
        LArr.Free;
        raise;
      end;
    end);

  // POST /users — echoes back the received JSON body
  THorse.Post('/users',
    procedure(AReq: THorseRequest; ARes: THorseResponse; ANext: TProc)
    var
      LBody: TJSONObject;
      LResp: TJSONObject;
    begin
      LBody := AReq.Body<TJSONObject>;
      LResp := TJSONObject.Create
        .AddPair('created', True)
        .AddPair('name', LBody.GetValue<string>('name', ''));
      ARes.Status(THTTPStatus.Created).Send<TJSONObject>(LResp);
    end);
end;

begin
  // Worker threads — keep at 200 or match your DB pool size for blocking handlers
  THorse.WorkerCount := 200;

  RegisterRoutes;

  THorse.Listen(SERVER_PORT,
    procedure
    begin
      Writeln(Format('AsyncIO/Horse running on http://0.0.0.0:%d', [SERVER_PORT]));
      Writeln('Press Enter to stop...');
      Readln;
      THorse.StopListen;
    end,
    nil);
end.
