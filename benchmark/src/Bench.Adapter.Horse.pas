unit Bench.Adapter.Horse;

// IBenchAdapter implementation wrapping TBenchHorseServer.
//
// When IsAvailable = False (Horse/CrossSocket not compiled in), all scenarios
// for this adapter are automatically skipped by the benchmark runner.
//
// Usage:
//   LRunner.AddAdapter(TBenchAdapterHorseCS.Create);
//
// See Bench.Server.Horse.pas for setup instructions.

interface

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.Diagnostics,
  Bench.Adapter,
  Bench.Server.Horse;

type
  TBenchAdapterHorseCS = class(TInterfacedObject, IBenchAdapter)
  private
    FServer:     TBenchHorseServer;
    FClient:     THTTPClient;
    FOwnsServer: Boolean;
    FName_:      string;

    procedure AcceptAllCerts;
  public
    constructor Create(const APort: Integer = TBenchHorseServer.BASE_PORT_CS); overload;
    constructor Create(const AServer: TBenchHorseServer); overload;
    destructor  Destroy; override;

    function Execute(const AURL, AMethod: string; const ABody: string = ''): Int64;
    procedure Reset;
    function  Name: string;
    function  IsAvailable: Boolean;
    function  Clone: IBenchAdapter;
    function  BaseURL: string;
  end;

implementation

procedure BenchHorseAcceptAnyCert(const Sender: TObject; const ARequest: TURLRequest;
  const Certificate: TCertificate; var Accepted: Boolean);
begin
  Accepted := True;
end;

{ TBenchAdapterHorseCS }

constructor TBenchAdapterHorseCS.Create(const APort: Integer);
begin
  inherited Create;
  FName_      := 'Horse/CS';
  FOwnsServer := True;
  FClient     := THTTPClient.Create;
  FClient.HandleRedirects := False;
  AcceptAllCerts;
  FServer := TBenchHorseServer.Create(APort);
  if FServer.IsAvailable then
    FServer.Start;
end;

constructor TBenchAdapterHorseCS.Create(const AServer: TBenchHorseServer);
begin
  inherited Create;
  FName_      := 'Horse/CS';
  FOwnsServer := False;
  FClient     := THTTPClient.Create;
  FClient.HandleRedirects := False;
  AcceptAllCerts;
  FServer := AServer;
end;

destructor TBenchAdapterHorseCS.Destroy;
begin
  FClient.Free;
  if FOwnsServer then
  begin
    FServer.Stop;
    FServer.Free;
  end;
  inherited;
end;

procedure TBenchAdapterHorseCS.AcceptAllCerts;
begin
  FClient.ValidateServerCertificateCallback := BenchHorseAcceptAnyCert;
end;

function TBenchAdapterHorseCS.Execute(
  const AURL, AMethod: string;
  const ABody: string
): Int64;
var
  LSW:     TStopwatch;
  LStream: TStringStream;
  LHdrs:   TArray<TNameValuePair>;
begin
  LSW := TStopwatch.StartNew;
  if AMethod = 'GET' then
    FClient.Get(AURL)
  else if AMethod = 'POST' then
  begin
    LStream := TStringStream.Create(ABody, TEncoding.UTF8);
    try
      SetLength(LHdrs, 1);
      LHdrs[0] := TNameValuePair.Create('Content-Type', 'application/json');
      FClient.Post(AURL, LStream, nil, LHdrs);
    finally
      LStream.Free;
    end;
  end;
  Result := LSW.ElapsedMilliseconds;
end;

procedure TBenchAdapterHorseCS.Reset;
begin
  FClient.Free;
  FClient := THTTPClient.Create;
  FClient.HandleRedirects := False;
  AcceptAllCerts;
end;

function TBenchAdapterHorseCS.Name: string;
begin
  Result := FName_;
end;

function TBenchAdapterHorseCS.IsAvailable: Boolean;
begin
  Result := TBenchHorseServer.IsAvailable;
end;

function TBenchAdapterHorseCS.Clone: IBenchAdapter;
begin
  Result := TBenchAdapterHorseCS.Create(FServer);
end;

function TBenchAdapterHorseCS.BaseURL: string;
begin
  Result := FServer.BaseURL;
end;

end.
