unit Poseidon.Net.Connection.Manager;

// TConnectionManager (#84) — connection admission, per-IP tracking, limits.
//
// Extracted from TPoseidonNativeServer to follow SRP.
// Thread-safe: all public methods acquire FLock internally.

interface

uses
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  System.Classes,
  Poseidon.Net.Connection;

type
  TConnectionManager = class
  private
    FLock:               TCriticalSection;
    FConnList:           TList;
    FPerIPCount:         TDictionary<string, Integer>;
    FMaxConnections:     Integer;
    FMaxConnectionsPerIP: Integer;
  public
    constructor Create;
    destructor Destroy; override;

    // Try to admit AConn. Returns True if admitted, False if limits exceeded.
    // Adds AConn to the connection list and updates per-IP counters.
    function Admit(AConn: Pointer): Boolean;

    // Remove AConn from the tracked list. Returns the index it was at,
    // or -1 if not found (already removed).
    function Remove(AConn: Pointer): Integer;

    // Snapshot all connections with AddRef on each. Caller must Release.
    function Snapshot: TArray<Pointer>;

    // Connection count (under lock).
    function Count: Integer;

    // Enumerate all connections under lock.
    // AProc receives each connection pointer. Do NOT call Remove inside AProc.
    procedure ForEach(AProc: TProc<Pointer>);

    property Lock: TCriticalSection read FLock;
    property ConnList: TList read FConnList;
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    property MaxConnectionsPerIP: Integer read FMaxConnectionsPerIP write FMaxConnectionsPerIP;
  end;

// Extract IP from "IP:Port" address string (handles IPv6 "[::1]:Port").
function ExtractIP(const ARemoteAddr: string): string;

implementation

function ExtractIP(const ARemoteAddr: string): string;
var
  LColonPos: Integer;
begin
  // RemoteAddr format is "IP:Port". For IPv6 it would be "[::1]:Port".
  // Find LAST colon to handle IPv6 too.
  LColonPos := ARemoteAddr.LastDelimiter(':');
  if LColonPos > 0 then
    Result := Copy(ARemoteAddr, 1, LColonPos)
  else
    Result := ARemoteAddr;
end;

constructor TConnectionManager.Create;
begin
  inherited Create;
  FLock               := TCriticalSection.Create;
  FConnList           := TList.Create;
  FPerIPCount         := TDictionary<string, Integer>.Create;
  FMaxConnections     := 0;
  FMaxConnectionsPerIP := 0;
end;

destructor TConnectionManager.Destroy;
begin
  FreeAndNil(FPerIPCount);
  FreeAndNil(FConnList);
  FreeAndNil(FLock);
  inherited Destroy;
end;

function TConnectionManager.Admit(AConn: Pointer): Boolean;
var
  LConn:  TNativeConn;
  LIP:    string;
  LCount: Integer;
begin
  Result := False;
  LConn := TNativeConn(AConn);
  LIP := ExtractIP(LConn.RemoteAddr);
  FLock.Enter;
  try
    if (FMaxConnections > 0) and (FConnList.Count >= FMaxConnections) then Exit;
    if FMaxConnectionsPerIP > 0 then
    begin
      if FPerIPCount.TryGetValue(LIP, LCount) and
         (LCount >= FMaxConnectionsPerIP) then Exit;
      if not FPerIPCount.TryGetValue(LIP, LCount) then LCount := 0;
      FPerIPCount.AddOrSetValue(LIP, LCount + 1);
    end;
    FConnList.Add(AConn);
    Result := True;
  finally
    FLock.Leave;
  end;
end;

function TConnectionManager.Remove(AConn: Pointer): Integer;
var
  LConn:  TNativeConn;
  LIP:    string;
  LCount: Integer;
begin
  LConn := TNativeConn(AConn);
  FLock.Enter;
  try
    Result := FConnList.IndexOf(AConn);
    if Result >= 0 then
    begin
      FConnList.Delete(Result);
      // Unregister per-IP counter
      if FMaxConnectionsPerIP > 0 then
      begin
        LIP := ExtractIP(LConn.RemoteAddr);
        if FPerIPCount.TryGetValue(LIP, LCount) then
        begin
          if LCount <= 1 then FPerIPCount.Remove(LIP)
          else FPerIPCount.AddOrSetValue(LIP, LCount - 1);
        end;
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TConnectionManager.Snapshot: TArray<Pointer>;
var
  I: Integer;
begin
  FLock.Enter;
  try
    SetLength(Result, FConnList.Count);
    for I := 0 to FConnList.Count - 1 do
    begin
      Result[I] := FConnList[I];
      TNativeConn(Result[I]).AddRef;
    end;
  finally
    FLock.Leave;
  end;
end;

function TConnectionManager.Count: Integer;
begin
  FLock.Enter;
  try
    Result := FConnList.Count;
  finally
    FLock.Leave;
  end;
end;

procedure TConnectionManager.ForEach(AProc: TProc<Pointer>);
var
  I: Integer;
begin
  FLock.Enter;
  try
    for I := 0 to FConnList.Count - 1 do
      AProc(FConnList[I]);
  finally
    FLock.Leave;
  end;
end;

end.
