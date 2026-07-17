unit Poseidon.Net.Pool.Socket;

// Socket recycling pool using DisconnectEx + TF_REUSE_SOCKET.
//
// Instead of closesocket() + socket(), DisconnectEx resets a connected
// socket to the listening state without kernel object teardown.
// The recycled socket is ready for the next AcceptEx/accept cycle.
//
// Pool is bounded (CMaxPoolSize) to avoid holding too many kernel handles.
// If the pool is full, the socket is closed normally.
//
// Windows only. On Linux, this unit compiles as an empty stub.

{$IFDEF MSWINDOWS}

interface

uses
  {$IFDEF FPC}
  WinSock2,
  syncobjs;
  {$ELSE}
  Winapi.Winsock2;
  {$ENDIF}

type
  TSocketPool = class
  private class var
    FPool: array of TSocket;
    FCount: Integer;
    // FPC's TMonitor is non-functional (TMonitor.Enter AVs), so under FPC this
    // dedicated lock is a real critical section. Delphi keeps TObject+TMonitor.
    {$IFDEF FPC}FLock: TCriticalSection;{$ELSE}FLock: TObject;{$ENDIF}
    FDisconnectEx: Pointer;
    FLoaded: Boolean;
  public
    class procedure Initialize; static;
    class procedure Finalize; static;

    // Load DisconnectEx function pointer via WSAIoctl on the given socket.
    // Called once with the listen socket.
    class procedure LoadDisconnectEx(ASocket: TSocket); static;

    // Attempt to recycle a socket via DisconnectEx + TF_REUSE_SOCKET.
    // Returns True if recycled (socket now in pool); False if closed normally.
    class function Recycle(ASocket: TSocket): Boolean; static;

    // Acquire a recycled socket from the pool.
    // Returns INVALID_SOCKET if pool is empty.
    class function Acquire: TSocket; static;

    // Add an already-disconnected socket directly to the pool.
    // Used by async DisconnectEx completion path.
    class function AddRecycled(ASocket: TSocket): Boolean; static;
  end;

implementation

uses
  {$IFDEF FPC}
  Windows,
  SysUtils;
  {$ELSE}
  System.SysUtils,
  System.SyncObjs,
  Winapi.Windows;
  {$ENDIF}

const
  CMaxPoolSize = 2048;
  TF_REUSE_SOCKET = $02;
  SIO_GET_EXTENSION_FUNCTION_POINTER = $C8000006;
  WSAID_DISCONNECTEX: TGUID = '{7FDA2E11-8630-436F-A031-F536A6EEC157}';

type
  TDisconnectExFunc = function(ASocket: TSocket; AOverlapped: POverlapped;
    AFlags: DWORD; AReserved: DWORD): BOOL; stdcall;

class procedure TSocketPool.Initialize;
begin
  {$IFDEF FPC}FLock := syncobjs.TCriticalSection.Create;{$ELSE}FLock := TObject.Create;{$ENDIF}
  SetLength(FPool, CMaxPoolSize);
  FCount := 0;
  FDisconnectEx := nil;
  FLoaded := False;
end;

class procedure TSocketPool.Finalize;
var
  I: Integer;
begin
  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    for I := 0 to FCount - 1 do
      closesocket(FPool[I]);
    FCount := 0;
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
  FreeAndNil(FLock);
end;

class procedure TSocketPool.LoadDisconnectEx(ASocket: TSocket);
var
  LBytes: DWORD;
  LGuid: TGUID;
begin
  if FLoaded then Exit;
  LGuid := WSAID_DISCONNECTEX;
  LBytes := 0;
  if WSAIoctl(ASocket, SIO_GET_EXTENSION_FUNCTION_POINTER,
    @LGuid, SizeOf(LGuid), @FDisconnectEx, SizeOf(FDisconnectEx),
    {$IFDEF FPC}@LBytes{$ELSE}LBytes{$ENDIF}, nil, nil) = 0 then
    FLoaded := True;
end;

class function TSocketPool.Recycle(ASocket: TSocket): Boolean;
begin
  Result := False;
  if (not FLoaded) or (FDisconnectEx = nil) then Exit;

  // Synchronous DisconnectEx with TF_REUSE_SOCKET
  if not TDisconnectExFunc(FDisconnectEx)(ASocket, nil, TF_REUSE_SOCKET, 0) then
  begin
    // DisconnectEx failed — close normally
    closesocket(ASocket);
    Exit;
  end;

  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    if FCount < CMaxPoolSize then
    begin
      FPool[FCount] := ASocket;
      Inc(FCount);
      Result := True;
    end
    else
      closesocket(ASocket); // Pool full — close normally
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
end;

class function TSocketPool.Acquire: TSocket;
begin
  Result := INVALID_SOCKET;
  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    if FCount > 0 then
    begin
      Dec(FCount);
      Result := FPool[FCount];
    end;
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
end;

class function TSocketPool.AddRecycled(ASocket: TSocket): Boolean;
begin
  Result := False;
  {$IFDEF FPC}FLock.Enter;{$ELSE}TMonitor.Enter(FLock);{$ENDIF}
  try
    if FCount < CMaxPoolSize then
    begin
      FPool[FCount] := ASocket;
      Inc(FCount);
      Result := True;
    end;
  finally
    {$IFDEF FPC}FLock.Leave;{$ELSE}TMonitor.Exit(FLock);{$ENDIF}
  end;
end;

initialization
  TSocketPool.Initialize;

finalization
  TSocketPool.Finalize;

{$ELSE}

interface
implementation

{$ENDIF MSWINDOWS}

end.
