unit Poseidon.Net.HTTP2.Manager;

// THTTP2Manager — HTTP/2 upgrade, stream handling, push.
//
// Extracted from TPoseidonNativeServer. Manages H2 upgrade (h2c cleartext),
// and provides callbacks for TH2Conn (send, close, request dispatch).
// Transport operations provided via constructor-injected callbacks.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  Poseidon.Net.Types,
  Poseidon.Net.Connection,
  Poseidon.Net.HTTP2;

type
  // Transport callbacks — injected by the server
  TH2TransportSend  = reference to procedure(AConn: Pointer; const AData: TBytes);
  TH2TransportClose = reference to procedure(AConn: Pointer);
  TH2TransportRecv  = reference to procedure(AConn: Pointer);

  THTTP2Manager = class
  private
    FH2Enabled: Boolean;
    FH2MaxConcurrentStreams: Cardinal;
    FH2InitialWindowSize: Cardinal;
    FOnH2Push: TOnH2Push;
    FOnRequest: TOnNativeRequest;
    FInFlightCount: PInt64;
    FSend: TH2TransportSend;
    FClose: TH2TransportClose;
    FRecv: TH2TransportRecv;
  public
    constructor Create(ASend: TH2TransportSend; AClose: TH2TransportClose;
      ARecv: TH2TransportRecv);

    procedure UpgradeToH2C(AConn: Pointer; const AReq: TPoseidonNativeRequest);

    // TH2Conn callbacks — registered as procedure of object via method references
    procedure H2Send(AConn: Pointer; const AData: TBytes);
    procedure H2Close(AConn: Pointer);
    procedure H2OnRequest(const AReq: TH2RequestData;
      var AStatus: Integer; var AContentType: string; var ABody: TBytes;
      var AExtra: TArray<TPair<string,string>>;
      var APushResources: TArray<TPoseidonPushResource>);

    property H2Enabled: Boolean read FH2Enabled write FH2Enabled;
    property H2MaxConcurrentStreams: Cardinal read FH2MaxConcurrentStreams write FH2MaxConcurrentStreams;
    property H2InitialWindowSize: Cardinal read FH2InitialWindowSize write FH2InitialWindowSize;
    property OnH2Push: TOnH2Push read FOnH2Push write FOnH2Push;
    property OnRequest: TOnNativeRequest read FOnRequest write FOnRequest;
    property InFlightCount: PInt64 read FInFlightCount write FInFlightCount;
  end;

implementation

const
  CDefaultH2MaxConcurrentStreams = 100;
  CDefaultH2InitialWindowSize = 65535;  // RFC 7540 default

var
  DefaultErrorBody: TBytes;

constructor THTTP2Manager.Create(ASend: TH2TransportSend;
  AClose: TH2TransportClose; ARecv: TH2TransportRecv);
begin
  inherited Create;
  FSend := ASend;
  FClose := AClose;
  FRecv := ARecv;
  FH2Enabled := False;
  FH2MaxConcurrentStreams := CDefaultH2MaxConcurrentStreams;
  FH2InitialWindowSize := CDefaultH2InitialWindowSize;
  FOnH2Push := nil;
  FOnRequest := nil;
  FInFlightCount := nil;
end;

procedure THTTP2Manager.UpgradeToH2C(AConn: Pointer;
  const AReq: TPoseidonNativeRequest);
var
  LConn: TNativeConn;
  LResp: TBytes;
  LH2Req: TH2RequestData;
  I: Integer;
begin
  LConn := TNativeConn(AConn);

  LResp := TEncoding.ASCII.GetBytes(
    'HTTP/1.1 101 Switching Protocols'#13#10 +
    'Connection: Upgrade'#13#10 +
    'Upgrade: h2c'#13#10#13#10);

  LConn.H2Conn := TH2Conn.Create(AConn, H2Send, H2Close, H2OnRequest,
    FH2MaxConcurrentStreams, FH2InitialWindowSize);
  LConn.KeepAlive := True;
  LConn.AccumLen := 0;

  FSend(AConn, LResp);
  LConn.H2Conn.SendInitialSettings;

  LH2Req.Host        := '';
  LH2Req.ContentType := '';
  for I := 0 to High(AReq.Headers) do
  begin
    if SameText(AReq.Headers[I].Key, ':authority') or
       SameText(AReq.Headers[I].Key, 'host') then
      LH2Req.Host := AReq.Headers[I].Value;
    if SameText(AReq.Headers[I].Key, 'content-type') then
      LH2Req.ContentType := AReq.Headers[I].Value;
  end;

  LConn.H2Conn.DispatchH2CInitialRequest(
    AReq.Method, AReq.Path, AReq.QueryString,
    LConn.RemoteAddr, LH2Req.Host, LH2Req.ContentType,
    AReq.Headers, AReq.RawBody);

  FRecv(AConn);
end;

procedure THTTP2Manager.H2Send(AConn: Pointer; const AData: TBytes);
begin
  FSend(AConn, AData);
end;

procedure THTTP2Manager.H2Close(AConn: Pointer);
begin
  FClose(AConn);
end;

procedure THTTP2Manager.H2OnRequest(const AReq: TH2RequestData;
  var AStatus: Integer; var AContentType: string; var ABody: TBytes;
  var AExtra: TArray<TPair<string,string>>;
  var APushResources: TArray<TPoseidonPushResource>);
var
  LNativeReq: TPoseidonNativeRequest;
  LQPos: Integer;
  LStatus: Integer;
  LCT: string;
  LBody: TBytes;
  LExtra: TArray<TPair<string,string>>;
begin
  LQPos := Pos('?', AReq.Path);
  if LQPos > 0 then
  begin
    LNativeReq.Path := Copy(AReq.Path, 1, LQPos - 1);
    LNativeReq.QueryString := Copy(AReq.Path, LQPos + 1, MaxInt);
  end else
  begin
    LNativeReq.Path := AReq.Path;
    LNativeReq.QueryString := AReq.QueryString;
  end;
  LNativeReq.Method := AReq.Method;
  LNativeReq.RawBody := AReq.Body;
  LNativeReq.RemoteAddr := AReq.RemoteAddr;
  LNativeReq.KeepAlive := True;
  LNativeReq.Headers := AReq.Headers;

  LStatus := 500;
  LCT := 'application/json';
  LBody := DefaultErrorBody;
  SetLength(LExtra, 0);
  if FInFlightCount <> nil then
    TInterlocked.Increment(FInFlightCount^);
  try
    try
      if Assigned(FOnRequest) then
        FOnRequest(LNativeReq, LStatus, LCT, LBody, LExtra);
    except
      on E: Exception do
      begin
        LStatus := 500;
        LCT := 'application/problem+json';
        // Do not leak the raw exception message (info disclosure + JSON break).
        LBody   := TEncoding.UTF8.GetBytes(
          '{"type":"about:blank","title":"Internal Server Error",' +
          '"status":500,"detail":"An unexpected error occurred."}');
        SetLength(LExtra, 0);
      end;
    end;
  finally
    if FInFlightCount <> nil then
      TInterlocked.Decrement(FInFlightCount^);
  end;

  AStatus := LStatus;
  AContentType := LCT;
  ABody := LBody;
  AExtra := LExtra;

  if Assigned(FOnH2Push) then
    FOnH2Push(LNativeReq, APushResources);
end;

initialization
  DefaultErrorBody := TEncoding.UTF8.GetBytes(
    '{"type":"about:blank","title":"Internal Server Error","status":500}');

end.
