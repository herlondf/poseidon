unit Bench.Adapter.Poseidon;

// Adaptadores para as configurações de servidor Poseidon.
//
// Cada adaptador sobe um TPoseidonNativeServer em uma porta dedicada e usa
// System.Net.HttpClient como cliente HTTP.
//
// Configurações:
//   TBenchAdapterW4   — Workers=4  (porta 19990)
//   TBenchAdapterAuto — Workers=auto, sem extras (porta 19991)
//   TBenchAdapterGzip — Workers=auto + GzipEnabled=True (porta 19992)
//   TBenchAdapterSSL  — Workers=auto + SSL (porta 19993); N/A sem OpenSSL
//
// Clone() cria apenas um novo THTTPClient apontando para a mesma URL —
// o servidor continua rodando na instância original.

interface

uses
  System.SysUtils,
  System.Net.HttpClient,
  System.Net.URLClient,
  System.Diagnostics,
  System.Classes,
  Bench.Adapter,
  Bench.Server.Poseidon,
  Poseidon.Net.SSL;

type
  // Base: gerencia o servidor + cliente HTTP.
  // Subclasses configuram o servidor antes de Start.
  TBenchAdapterPoseidonBase = class(TInterfacedObject, IBenchAdapter)
  private
    FClient:     THTTPClient;
    FName:       string;
    FOwnsServer: Boolean;  // False em clones

    procedure AcceptAllCerts;
  protected
    FServer:  TBenchPoseidonServer;  // accessible to ConfigureServer overrides
    FBaseURL: string;                // SSL subclass overrides to https://
    // Subclasses sobrescrevem para configurar FServer antes de Start
    procedure ConfigureServer; virtual;
  public
    constructor Create(
      const AName:      string;
      const APort:      Integer;
      const AOwnsServer: Boolean;
      const AExistingServer: TBenchPoseidonServer = nil
    );
    destructor Destroy; override;

    function Execute(const AURL, AMethod: string; const ABody: string = ''): Int64;
    procedure Reset;
    function Name: string;
    function IsAvailable: Boolean; virtual;
    function Clone: IBenchAdapter; virtual; abstract;
    function BaseURL: string;
  end;

  TBenchAdapterW4 = class(TBenchAdapterPoseidonBase)
  protected
    procedure ConfigureServer; override;
  public
    constructor Create; overload;
    constructor Create(const AServer: TBenchPoseidonServer); overload;
    function Clone: IBenchAdapter; override;
    function IsAvailable: Boolean; override;
  end;

  TBenchAdapterAuto = class(TBenchAdapterPoseidonBase)
  public
    constructor Create; overload;
    constructor Create(const AServer: TBenchPoseidonServer); overload;
    function Clone: IBenchAdapter; override;
    function IsAvailable: Boolean; override;
  end;

  TBenchAdapterGzip = class(TBenchAdapterPoseidonBase)
  protected
    procedure ConfigureServer; override;
  public
    constructor Create; overload;
    constructor Create(const AServer: TBenchPoseidonServer); overload;
    function Clone: IBenchAdapter; override;
    function IsAvailable: Boolean; override;
  end;

  TBenchAdapterSSL = class(TBenchAdapterPoseidonBase)
  private
    FCertFile: string;
    FKeyFile:  string;
  protected
    procedure ConfigureServer; override;
  public
    constructor Create(
      const ACertFile: string = '.\certs\bench-server.crt';
      const AKeyFile:  string = '.\certs\bench-server.key'
    ); overload;
    constructor Create(const AServer: TBenchPoseidonServer); overload;
    function Clone: IBenchAdapter; override;
    function IsAvailable: Boolean; override;
  end;

  // Generic configurable adapter: any worker count + DAO latency.
  // Used by the workers-scaling benchmark matrix.
  TBenchAdapterConfigurable = class(TBenchAdapterPoseidonBase)
  private
    FWorkers:    Integer;
    FDAOLatency: Integer;
    FDAOMaxMs:   Integer;
    FClonePort:  Integer;
  protected
    procedure ConfigureServer; override;
  public
    constructor Create(
      const AName:       string;
      const APort:       Integer;
      const AWorkers:    Integer;
      const ADAOLatency: Integer;
      const ADAOMaxMs:   Integer = 0
    ); overload;
    constructor Create(const AServer: TBenchPoseidonServer;
      const AName: string; const AWorkers, ADAOLatency, ADAOMaxMs: Integer); overload;
    function Clone: IBenchAdapter; override;
  end;

implementation

// Procedimento global para aceitar qualquer certificado SSL em testes de benchmark.
// Necessário porque TValidateCertificateCallback é 'procedure' (não 'of object')
// e não aceita métodos nem closures que capturam variáveis.
procedure BenchAcceptAnyCert(const Sender: TObject; const ARequest: TURLRequest;
  const Certificate: TCertificate; var Accepted: Boolean);
begin
  Accepted := True;
end;

{ TBenchAdapterPoseidonBase }

constructor TBenchAdapterPoseidonBase.Create(
  const AName:          string;
  const APort:          Integer;
  const AOwnsServer:    Boolean;
  const AExistingServer: TBenchPoseidonServer
);
begin
  inherited Create;
  FName       := AName;
  FOwnsServer := AOwnsServer;
  FClient     := THTTPClient.Create;
  FClient.HandleRedirects := False;

  if AOwnsServer then
  begin
    FServer := TBenchPoseidonServer.Create(APort);
    ConfigureServer;
    FServer.Start;
    FBaseURL := FServer.BaseURL;
  end
  else
  begin
    FServer  := AExistingServer;  // not owned
    FBaseURL := FServer.BaseURL;
  end;

  AcceptAllCerts;
end;

destructor TBenchAdapterPoseidonBase.Destroy;
begin
  FClient.Free;
  if FOwnsServer then
    FServer.Free;
  inherited;
end;

procedure TBenchAdapterPoseidonBase.AcceptAllCerts;
begin
  FClient.ValidateServerCertificateCallback := BenchAcceptAnyCert;
end;

procedure TBenchAdapterPoseidonBase.ConfigureServer;
begin
  // padrão: sem configuração extra
end;

function TBenchAdapterPoseidonBase.Execute(
  const AURL, AMethod: string;
  const ABody: string
): Int64;
var
  LSW:      TStopwatch;
  LStream:  TStringStream;
  LHeaders: TArray<TNameValuePair>;
begin
  LSW := TStopwatch.StartNew;
  if AMethod = 'GET' then
    FClient.Get(AURL)
  else if AMethod = 'POST' then
  begin
    LStream := TStringStream.Create(ABody, TEncoding.UTF8);
    try
      SetLength(LHeaders, 1);
      LHeaders[0] := TNameValuePair.Create('Content-Type', 'application/json');
      FClient.Post(AURL, LStream, nil, LHeaders);
    finally
      LStream.Free;
    end;
  end;
  Result := LSW.ElapsedMilliseconds;
end;

procedure TBenchAdapterPoseidonBase.Reset;
begin
  FClient.Free;
  FClient := THTTPClient.Create;
  FClient.HandleRedirects := False;
  AcceptAllCerts;
end;

function TBenchAdapterPoseidonBase.Name: string;
begin
  Result := FName;
end;

function TBenchAdapterPoseidonBase.BaseURL: string;
begin
  Result := FBaseURL;
end;

function TBenchAdapterPoseidonBase.IsAvailable: Boolean;
begin
  Result := True;
end;

{ TBenchAdapterW4 }

constructor TBenchAdapterW4.Create;
begin
  inherited Create('Workers=4', TBenchPoseidonServer.BASE_PORT_W4, True);
end;

constructor TBenchAdapterW4.Create(const AServer: TBenchPoseidonServer);
begin
  inherited Create('Workers=4', AServer.Port, False, AServer);
end;

procedure TBenchAdapterW4.ConfigureServer;
begin
  FServer.SetWorkerCount(4);
end;

function TBenchAdapterW4.Clone: IBenchAdapter;
begin
  Result := TBenchAdapterW4.Create(FServer);
end;

function TBenchAdapterW4.IsAvailable: Boolean;
begin
  Result := True;
end;

{ TBenchAdapterAuto }

constructor TBenchAdapterAuto.Create;
begin
  inherited Create('Workers=auto', TBenchPoseidonServer.BASE_PORT_AUTO, True);
end;

constructor TBenchAdapterAuto.Create(const AServer: TBenchPoseidonServer);
begin
  inherited Create('Workers=auto', AServer.Port, False, AServer);
end;

function TBenchAdapterAuto.Clone: IBenchAdapter;
begin
  Result := TBenchAdapterAuto.Create(FServer);
end;

function TBenchAdapterAuto.IsAvailable: Boolean;
begin
  Result := True;
end;

{ TBenchAdapterGzip }

constructor TBenchAdapterGzip.Create;
begin
  inherited Create('Gzip', TBenchPoseidonServer.BASE_PORT_GZIP, True);
end;

constructor TBenchAdapterGzip.Create(const AServer: TBenchPoseidonServer);
begin
  inherited Create('Gzip', AServer.Port, False, AServer);
end;

procedure TBenchAdapterGzip.ConfigureServer;
begin
  FServer.EnableGzip(True);
end;

function TBenchAdapterGzip.Clone: IBenchAdapter;
begin
  Result := TBenchAdapterGzip.Create(FServer);
end;

function TBenchAdapterGzip.IsAvailable: Boolean;
begin
  Result := True;
end;

{ TBenchAdapterSSL }

constructor TBenchAdapterSSL.Create(const ACertFile, AKeyFile: string);
begin
  FCertFile := ACertFile;
  FKeyFile  := AKeyFile;
  inherited Create('SSL', TBenchPoseidonServer.BASE_PORT_SSL, True);
  FBaseURL := 'https://127.0.0.1:' + IntToStr(TBenchPoseidonServer.BASE_PORT_SSL);
end;

constructor TBenchAdapterSSL.Create(const AServer: TBenchPoseidonServer);
begin
  inherited Create('SSL', AServer.Port, False, AServer);
  FBaseURL := 'https://127.0.0.1:' + IntToStr(AServer.Port);
end;

procedure TBenchAdapterSSL.ConfigureServer;
begin
  FServer.ConfigureSSL(FCertFile, FKeyFile);
end;

function TBenchAdapterSSL.Clone: IBenchAdapter;
begin
  Result := TBenchAdapterSSL.Create(FServer);
end;

function TBenchAdapterSSL.IsAvailable: Boolean;
begin
  Result := TPoseidonSSL.IsAvailable
    and FileExists(FCertFile) and FileExists(FKeyFile);
end;

{ TBenchAdapterConfigurable }

constructor TBenchAdapterConfigurable.Create(
  const AName:       string;
  const APort:       Integer;
  const AWorkers:    Integer;
  const ADAOLatency: Integer;
  const ADAOMaxMs:   Integer
);
begin
  FWorkers    := AWorkers;
  FDAOLatency := ADAOLatency;
  FDAOMaxMs   := ADAOMaxMs;
  FClonePort  := APort;
  inherited Create(AName, APort, True);
end;

constructor TBenchAdapterConfigurable.Create(
  const AServer:    TBenchPoseidonServer;
  const AName:      string;
  const AWorkers, ADAOLatency, ADAOMaxMs: Integer
);
begin
  FWorkers    := AWorkers;
  FDAOLatency := ADAOLatency;
  FDAOMaxMs   := ADAOMaxMs;
  FClonePort  := AServer.Port;
  inherited Create(AName, AServer.Port, False, AServer);
end;

procedure TBenchAdapterConfigurable.ConfigureServer;
begin
  if FWorkers > 0 then
    FServer.SetWorkerCount(FWorkers);
  FServer.SetDAOLatencyMs(FDAOLatency, FDAOMaxMs);
end;

function TBenchAdapterConfigurable.Clone: IBenchAdapter;
begin
  Result := TBenchAdapterConfigurable.Create(
    FServer, Name, FWorkers, FDAOLatency, FDAOMaxMs);
end;

end.
