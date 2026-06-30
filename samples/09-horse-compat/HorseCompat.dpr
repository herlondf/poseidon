program HorseCompat;

// Demonstrates Horse-compatible API: uses "Poseidon" but writes THorse code.
// This should compile and run identically to a Horse application.

{$APPTYPE CONSOLE}
{$DEFINE POSEIDON_HORSE_COMPAT}

uses
  System.SysUtils,
  System.JSON,
  Poseidon;  // <-- only change: "Horse" → "Poseidon"

begin
  // Exact Horse pattern — THorse, THorseRequest, THorseResponse all work
  THorse.Get('/ping',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Send('pong');
    end);

  THorse.Get('/users',
    procedure(Req: THorseRequest; Res: THorseResponse)
    var LArr: TJSONArray;
    begin
      LArr := TJSONArray.Create;
      LArr.Add(TJSONObject.Create.AddPair('id', TJSONNumber.Create(1)).AddPair('name', 'Alice'));
      Res.Send<TJSONArray>(LArr);  // Horse's Send<T> → Poseidon's Json()
    end);

  THorse.Post('/users',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      Res.Status(201).Send('created: ' + Req.Body);  // Body → RawBody alias
    end);

  THorse.Get('/error',
    procedure(Req: THorseRequest; Res: THorseResponse)
    begin
      raise EHorseException.Create('not found', THTTPStatus.NotFound);
    end);

  // Middleware — Horse pattern (TNextProc = TProc alias in Poseidon)
  THorse.Use(TPoseidonCallback(
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      Res.AddHeader('X-Powered-By', 'Poseidon');  // AddHeader alias → Header
      Next;
    end));

  Writeln('[Horse-Compatible] on http://localhost:9009');
  THorse.Listen(9009);
end.
