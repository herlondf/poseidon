unit Poseidon.Net.Connection;

// TNativeConn — per-connection state (R-4 SRP extraction from HttpServer.pas).
//
// Owns the socket handle, the accumulation buffer, SSL BIO pointers, WebSocket
// and HTTP/2 upgrade state, and (on Linux) the non-blocking send state.
//
// Lifecycle (#43 — IOCP race fix):
//   Created  → FRefCount = 1  (server "owns" one ref)
//   PostRecv / PostSend → AddRef before WSARecv/WSASend (one ref per in-flight op)
//   Worker loop completion → Release after the callback (drops the IOCP-op ref)
//   _CloseConn → Release (drops the server ref); may not reach zero yet if ops
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
  CM_HTTP      = 0;
  CM_WEBSOCKET = 1;

type
  TNativeConn = class
  private
    FRefCount:     Integer;   // #43: atomic ref count; reaches 0 → Destroy
    _PadRef:       array[0..14] of Integer; // #69: cache-line padding — isolate FRefCount
  public
{$IFDEF MSWINDOWS}
    Socket:     TSocket;
{$ELSE}
    Socket:     Integer;
{$ENDIF}
    RemoteAddr:    string;
    AccumBuf:      TBytes;
    AccumLen:      Integer;
    KeepAlive:     Boolean;
    LastActivityTick: UInt64;    // TThread.GetTickCount64 — drives idle-timeout
    InFlightPool:  Integer;      // atomic counter: >0 while pool lambdas hold this connection; idle-sweep skips it
    _PadInflight:  array[0..14] of Integer; // #69: cache-line padding — isolate InFlightPool
    SSLHandle:     Pointer;    // SSL* (nil when plain HTTP)
    SSLReadBio:    Pointer;    // BIO* — encrypted bytes from network
    SSLWriteBio:   Pointer;    // BIO* — encrypted bytes to network
    SSLHandshook:  Boolean;
    WSMode:        Byte;
    WSPath:        string;
    WSConn:        IPoseidonWSConn;
    WSDeflate:     Boolean;    // True when permessage-deflate was negotiated
    H2Conn:        TH2Conn;    // non-nil when connection uses HTTP/2 (via ALPN)
    PPParsed:      Boolean;    // True once Proxy Protocol header has been consumed
{$IFNDEF MSWINDOWS}
    PendingSend:       TBytes;
    PendingSendActual: Integer; // P-4: bytes to send; 0 = use Length(PendingSend)
    SentBytes:         Integer;
    OwnerEpollFd:      Integer; // #66: per-core epoll fd that owns this connection
{$ENDIF}
    // R-1: ASocket is NativeUInt so callers need no {$IFDEF} for socket type.
    // Internally cast to TSocket (Windows) or Integer (Linux).
    constructor Create(ASocket: NativeUInt; const AAddr: string);
    destructor Destroy; override;

    // #43: ref-counting — thread-safe via TInterlocked.
    // Do NOT call Free directly; use Release instead.
    procedure AddRef;
    procedure Release;
  end;

implementation

// #43: import TInterlocked via SyncObjs alias — already in interface uses.

procedure TNativeConn.AddRef;
begin
  TInterlocked.Increment(FRefCount);
end;

procedure TNativeConn.Release;
begin
  if TInterlocked.Decrement(FRefCount) = 0 then
    Destroy;
end;

constructor TNativeConn.Create(ASocket: NativeUInt; const AAddr: string);
begin
{$IFDEF MSWINDOWS}
  Socket       := TSocket(ASocket);
{$ELSE}
  Socket       := Integer(ASocket);
{$ENDIF}
  RemoteAddr   := AAddr;
  FRefCount    := 1;                    // #43: server owns one ref
  AccumBuf     := TBufferPool.Acquire;  // pooled 8 KB
  AccumLen     := 0;
  KeepAlive    := False;
  LastActivityTick := TThread.GetTickCount64;
  InFlightPool := 0;
  SSLHandle    := nil;
  SSLReadBio   := nil;
  SSLWriteBio  := nil;
  SSLHandshook := False;
  WSMode       := CM_HTTP;
  WSPath       := '';
  WSConn       := nil;
  WSDeflate    := False;
  H2Conn       := nil;
  PPParsed     := False;
{$IFNDEF MSWINDOWS}
  OwnerEpollFd := -1;   // #66: set by epoll backend on RegisterConn
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
  inherited Destroy;
end;

end.
