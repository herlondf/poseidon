unit Poseidon.Tests.ConnectionLimit;

// Integration tests for MaxConnections, MaxConnectionsPerIP and IdleTimeout.
// Uses raw Winsock2 sockets to hold connections open without sending HTTP data.
// Test methods are compiled and registered only on Windows (IOCP provider).

interface

{$IFDEF MSWINDOWS}
uses
  DUnitX.TestFramework,
  System.Classes;

type
  [TestFixture]
  TConnectionLimitTests = class
  private
    FServer: TObject; // TPoseidonNativeServer
    FThread: TThread;
    procedure StartServer(APort, AMaxConn, APerIP, AIdleMs: Integer);
    procedure StopServer;
  public
    [TearDown]
    procedure TearDown;

    [Test] procedure MaxConnections_ThirdConnIsRejected;
    [Test] procedure MaxConnectionsPerIP_ThirdConnIsRejected;
    [Test] procedure IdleTimeout_ZombieConnIsClosed;
  end;
{$ENDIF}

implementation

{$IFDEF MSWINDOWS}
uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  Winapi.Windows,
  Winapi.WinSock2,
  Poseidon.Net.HttpServer;

// Type alias to prevent Delphi parser confusion with nested generics
// inside standalone procedure parameters assigned to a method reference.
type
  TExtraHeaders = TArray<TPair<string, string>>;

const
  CL_HOST = '127.0.0.1';

// Declare connect directly against ws2_32.dll with PSockAddrIn to avoid
// the Delphi RTL's 'var TSockAddr' declaration which causes E2033.
function _WsaConnect(s: TSocket; name: PSockAddrIn; namelen: Integer): Integer; stdcall;
  external 'ws2_32.dll' name 'connect';

procedure DummyHandler(const AReq: TPoseidonNativeRequest;
  out AStatus: Integer; out AContentType: string;
  out ABody: TBytes; out AExtraHeaders: TExtraHeaders);
begin
  AStatus      := 200;
  AContentType := 'text/plain';
  ABody        := TEncoding.UTF8.GetBytes('ok');
  SetLength(AExtraHeaders, 0);
end;

function RawConnect(APort: Word): TSocket;
var
  LAddr: TSockAddrIn;
begin
  Result := Winapi.WinSock2.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
  if Result = INVALID_SOCKET then
    raise Exception.Create('socket() failed: ' + IntToStr(WSAGetLastError));
  FillChar(LAddr, SizeOf(LAddr), 0);
  LAddr.sin_family      := AF_INET;
  LAddr.sin_port        := htons(APort);
  LAddr.sin_addr.S_addr := inet_addr(PAnsiChar(AnsiString(CL_HOST)));
  _WsaConnect(Result, @LAddr, SizeOf(LAddr));
end;

// Returns True if the socket still appears open (no FIN/RST received).
// Sets a 200ms receive timeout via SO_RCVTIMEO, then peeks with MSG_PEEK.
// WSAETIMEDOUT means no data and no FIN arrived → still open.
function IsConnOpen(ASocket: TSocket): Boolean;
const
  MSG_PEEK_FLAG = $2;
var
  LTO:  DWORD;
  LBuf: AnsiChar;
  LRet: Integer;
begin
  LTO := 200; // 200ms
  setsockopt(ASocket, SOL_SOCKET, SO_RCVTIMEO, PAnsiChar(@LTO), SizeOf(LTO));
  LRet := recv(ASocket, LBuf, SizeOf(LBuf), MSG_PEEK_FLAG);
  if LRet = 0 then
    Result := False                              // graceful FIN from server
  else if LRet = SOCKET_ERROR then
    Result := WSAGetLastError = WSAETIMEDOUT     // timeout = no FIN yet = open
  else
    Result := True;                              // data present = still open
end;

{ TConnectionLimitTests }

procedure TConnectionLimitTests.StartServer(APort, AMaxConn, APerIP, AIdleMs: Integer);
var
  LReady:    TEvent;
  LOnReq:    TOnNativeRequest;
  LOnListen: TProc;
begin
  FServer := TPoseidonNativeServer.Create;
  with TPoseidonNativeServer(FServer) do
  begin
    MaxConnections      := AMaxConn;
    MaxConnectionsPerIP := APerIP;
    IdleTimeoutMs       := AIdleMs;
  end;
  LReady    := TEvent.Create(nil, True, False, '');
  LOnReq    := DummyHandler;
  LOnListen := procedure begin LReady.SetEvent; end;
  FThread   := TThread.CreateAnonymousThread(
    procedure
    begin
      TPoseidonNativeServer(FServer).Listen(CL_HOST, APort, LOnReq, LOnListen);
    end);
  FThread.FreeOnTerminate := False;
  FThread.Start;
  LReady.WaitFor(3000);
  LReady.Free;
end;

procedure TConnectionLimitTests.StopServer;
begin
  if FServer <> nil then
  begin
    TPoseidonNativeServer(FServer).Stop;
    FThread.WaitFor;
    FreeAndNil(FThread);
    FreeAndNil(FServer);
  end;
end;

procedure TConnectionLimitTests.TearDown;
begin
  StopServer;
end;

procedure TConnectionLimitTests.MaxConnections_ThirdConnIsRejected;
var
  S1, S2, S3: TSocket;
begin
  StartServer(19997, {MaxConn=}2, {PerIP=}0, {IdleMs=}0);
  S1 := RawConnect(19997);
  Sleep(80);
  S2 := RawConnect(19997);
  Sleep(80);
  S3 := RawConnect(19997);
  Sleep(250); // let server accept + reject S3
  try
    Assert.IsTrue(IsConnOpen(S1),  'S1 deve continuar aberta (MaxConnections=2)');
    Assert.IsTrue(IsConnOpen(S2),  'S2 deve continuar aberta (MaxConnections=2)');
    Assert.IsFalse(IsConnOpen(S3), 'S3 deve ser recusada — limite de conexões atingido');
  finally
    closesocket(S1);
    closesocket(S2);
    closesocket(S3);
  end;
end;

procedure TConnectionLimitTests.MaxConnectionsPerIP_ThirdConnIsRejected;
var
  S1, S2, S3: TSocket;
begin
  StartServer(19996, {MaxConn=}0, {PerIP=}2, {IdleMs=}0);
  S1 := RawConnect(19996);
  Sleep(80);
  S2 := RawConnect(19996);
  Sleep(80);
  S3 := RawConnect(19996);
  Sleep(250);
  try
    Assert.IsTrue(IsConnOpen(S1),  'S1 deve continuar aberta (PerIP=2)');
    Assert.IsTrue(IsConnOpen(S2),  'S2 deve continuar aberta (PerIP=2)');
    Assert.IsFalse(IsConnOpen(S3), 'S3 deve ser recusada — limite por IP atingido');
  finally
    closesocket(S1);
    closesocket(S2);
    closesocket(S3);
  end;
end;

procedure TConnectionLimitTests.IdleTimeout_ZombieConnIsClosed;
var
  S: TSocket;
begin
  // IdleTimeoutMs=500ms. The idle sweep runs every ~1s (_IdleSweepLoop).
  // Wait 3s total to ensure at least two sweep iterations run.
  StartServer(19995, {MaxConn=}0, {PerIP=}0, {IdleMs=}500);
  S := RawConnect(19995);
  Sleep(100);

  Assert.IsTrue(IsConnOpen(S), 'Conexão deve estar aberta inicialmente');

  Sleep(3000);

  Assert.IsFalse(IsConnOpen(S), 'Conexão deve ser fechada pelo idle sweep após timeout');
  closesocket(S);
end;

initialization
  TDUnitX.RegisterTestFixture(TConnectionLimitTests);
{$ENDIF}

end.
