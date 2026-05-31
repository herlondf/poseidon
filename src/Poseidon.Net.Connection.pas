unit Poseidon.Net.Connection;

// TNativeConn — per-connection state (R-4 SRP extraction from HttpServer.pas).
//
// Owns the socket handle, the accumulation buffer, SSL BIO pointers, WebSocket
// and HTTP/2 upgrade state, and (on Linux) the non-blocking send state.
// Lifecycle: created in _OnNewSocket, destroyed in _CloseConn.

interface

uses
  System.SysUtils,
  Poseidon.Net.Pool.Buffer,
  Poseidon.Net.HTTP2,
  Poseidon.Net.WebSocket;

const
  CM_HTTP      = 0;
  CM_WEBSOCKET = 1;

type
  TNativeConn = class
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
    LastActivity:  TDateTime;    // updated on every _ProcessRecv — drives idle-timeout
    SSLHandle:     Pointer;    // SSL* (nil when plain HTTP)
    SSLReadBio:    Pointer;    // BIO* — encrypted bytes from network
    SSLWriteBio:   Pointer;    // BIO* — encrypted bytes to network
    SSLHandshook:  Boolean;
    WSMode:        Byte;
    WSPath:        string;
    WSConn:        IPoseidonWSConn;
    H2Conn:        TH2Conn;    // non-nil when connection uses HTTP/2 (via ALPN)
    PPParsed:      Boolean;    // True once Proxy Protocol header has been consumed
{$IFNDEF MSWINDOWS}
    PendingSend:       TBytes;
    PendingSendActual: Integer; // P-4: bytes to send; 0 = use Length(PendingSend)
    SentBytes:         Integer;
{$ENDIF}
    constructor Create(
{$IFDEF MSWINDOWS}ASocket: TSocket{$ELSE}ASocket: Integer{$ENDIF};
      const AAddr: string);
    destructor Destroy; override;
  end;

implementation

constructor TNativeConn.Create(
{$IFDEF MSWINDOWS}ASocket: TSocket{$ELSE}ASocket: Integer{$ENDIF};
  const AAddr: string);
begin
  Socket       := ASocket;
  RemoteAddr   := AAddr;
  AccumBuf     := TBufferPool.Acquire;  // pooled 8 KB
  AccumLen     := 0;
  KeepAlive    := False;
  LastActivity := Now;
  SSLHandle    := nil;
  SSLReadBio   := nil;
  SSLWriteBio  := nil;
  SSLHandshook := False;
  WSMode       := CM_HTTP;
  WSPath       := '';
  WSConn       := nil;
  H2Conn       := nil;
  PPParsed     := False;
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
