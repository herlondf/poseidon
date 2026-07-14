unit Poseidon.Net.Connection;

// TNativeConn — per-connection state (R-4 SRP extraction from HttpServer.pas).
//
// Owns the socket handle, the accumulation buffer, SSL BIO pointers, WebSocket
// and HTTP/2 upgrade state, and (on Linux) the non-blocking send state.
//
// Lifecycle (IOCP race fix):
//   Created  -> FRefCount = 1  (server "owns" one ref)
//   PostRecv / PostSend -> AddRef before WSARecv/WSASend (one ref per in-flight op)
//   Worker loop completion -> Release after the callback (drops the IOCP-op ref)
//   _CloseConn -> Release (drops the server ref); may not reach zero yet if ops
//                are still in-flight — the object lives until the last Release.
//   AddRef/Release are thread-safe via TInterlocked.

interface

uses
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
{$IFDEF MSWINDOWS}
  Winapi.Winsock2,
{$ENDIF}
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.HTTP2,
  Poseidon.Net.WebSocket;

const
  CCMHttp = 0;
  CCMWebSocket = 1;

type
  TNativeConn = class
  private
    FRefCount: Integer; // Atomic ref count; reaches 0 -> Destroy
    FPadRef: array[0..14] of Integer; // Cache-line padding — isolate FRefCount
  public
{$IFDEF MSWINDOWS}
    Socket: TSocket;
    RioRQ: Pointer;
{$ELSE}
    Socket: Integer;
{$ENDIF}
    RemoteAddr: string;
    // #213: serializes ALL per-connection access to the SSL object, AccumBuf,
    // and H2Conn across the IO/core thread (_ProcessRecvSSL) and the request
    // worker pool (dispatch / _EncryptAndSend). Recursive (TCriticalSection),
    // so nested same-thread acquisition (e.g. _ProcessRecvSSL -> _EncryptAndSend
    // during handshake) does not deadlock.
    Lock: TCriticalSection;
    AccumBuf: TBytes;
    AccumLen: Integer;
    KeepAlive: Boolean;
    LastActivityTick: UInt64;
    InFlightPool: Integer;
    FPadInflight: array[0..14] of Integer; // Cache-line padding — isolate InFlightPool
    SSLHandle: Pointer;
    SSLReadBio: Pointer;
    SSLWriteBio: Pointer;
    SSLHandshook: Boolean;
    WSMode: Byte;
    WSPath: string;
    WSConn: IPoseidonWSConn;
    WSDeflate: Boolean;
    H2Conn: TH2Conn;
    PPParsed: Boolean;
{$IFNDEF MSWINDOWS}
    PendingSend: TBytes;
    PendingSendActual: Integer;
    SentBytes: Integer;
    OwnerEpollFd: Integer;
{$ENDIF}
    // R-1: ASocket is NativeUInt so callers need no {$IFDEF} for socket type.
    // Internally cast to TSocket (Windows) or Integer (Linux).
    constructor Create(ASocket: NativeUInt; const AAddr: string);
    destructor Destroy; override;

    // Ref-counting — thread-safe via TInterlocked.
    // Do NOT call Free directly; use Release instead.
    procedure AddRef;
    procedure Release;
  end;

implementation

// TInterlocked imported via SyncObjs — already in interface uses.

procedure TNativeConn.AddRef;
begin
  TInterlocked.Increment(FRefCount);
end;

procedure TNativeConn.Release;
begin
  if TInterlocked.Decrement(FRefCount) = 0 then
    Self.Free;
end;

constructor TNativeConn.Create(ASocket: NativeUInt; const AAddr: string);
begin
{$IFDEF MSWINDOWS}
  Socket := TSocket(ASocket);
  RioRQ := nil;
{$ELSE}
  Socket := Integer(ASocket);
{$ENDIF}
  RemoteAddr := AAddr;
  FRefCount := 1;
  Lock := TCriticalSection.Create;
  AccumBuf := TBufferPool.Acquire;
  AccumLen := 0;
  KeepAlive := False;
  LastActivityTick := TThread.GetTickCount64;
  InFlightPool := 0;
  SSLHandle := nil;
  SSLReadBio := nil;
  SSLWriteBio := nil;
  SSLHandshook := False;
  WSMode := CCMHttp;
  WSPath := '';
  WSConn := nil;
  WSDeflate := False;
  H2Conn := nil;
  PPParsed := False;
{$IFNDEF MSWINDOWS}
  OwnerEpollFd := -1;
{$ENDIF}
end;

destructor TNativeConn.Destroy;
begin
  if AccumBuf <> nil then TBufferPool.Release(AccumBuf);
{$IFNDEF MSWINDOWS}
  // P-4: return any in-flight pool buffer if connection closed mid-send
  if PendingSend <> nil then TBufferPool.Release(PendingSend);
{$ENDIF}
  FreeAndNil(H2Conn);
  // Refcount is 0 here — no other thread references this connection, so the
  // lock is uncontended and safe to free last.
  FreeAndNil(Lock);
  inherited Destroy;
end;

end.
