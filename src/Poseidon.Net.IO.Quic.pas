unit Poseidon.Net.IO.Quic;

// #64: TQuicBackend — HTTP/3 (QUIC) backend placeholder.
//
// HTTP/3 uses QUIC (UDP) as transport, eliminating TCP head-of-line blocking
// and offering 0-RTT connection establishment.
//
// Implementation plan:
//   - Integrate with MsQuic (Microsoft, Windows) or quiche (Cloudflare, cross-platform) via FFI
//   - New backend implementing IIOBackend
//   - ALPN negotiation: h3 via UDP, h2/h1.1 via TCP (fallback)
//   - Reuse the entire routing/middleware layer — only the transport changes
//
// Dependencies:
//   - MsQuic: msquic.dll (Windows) / libmsquic.so (Linux) — MIT license
//   - quiche: libquiche.so — BSD-2 license, C API via FFI
//
// This unit currently raises ENotSupportedException at construction.
// Implementation will be added incrementally:
//   Phase 1: MsQuic FFI bindings + connection lifecycle
//   Phase 2: Stream multiplexing + request dispatch
//   Phase 3: 0-RTT support + session resumption
//   Phase 4: Benchmarks vs HTTP/2

interface

uses
  System.SysUtils,
  Poseidon.Net.IO;

type
  TQuicBackend = class(TInterfacedObject, IIOBackend)
  public
    constructor Create;
    // IIOBackend
    procedure StartListening(const AHost: string; APort: Integer;
      AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
      AAcceptThreads: Integer = 1);
    procedure StopAccept;
    procedure ShutdownConn(AConn: Pointer);
    procedure SignalWorkers;
    procedure JoinWorkers;
    procedure RegisterConn(AConn: Pointer);
    procedure PostRecv(AConn: Pointer);
    procedure PostSend(AConn: Pointer; const AData: TBytes; AActualLen: Integer);
    procedure PostSendV(AConn: Pointer;
      const AHeaders: TBytes; AHdrLen: Integer;
      const ABody: TBytes; ABodyLen: Integer);
    procedure SocketClose(AConn: Pointer);
  end;

implementation

constructor TQuicBackend.Create;
begin
  inherited Create;
  raise ENotSupportedException.Create(
    'HTTP/3 (QUIC) backend not yet implemented. ' +
    'Requires MsQuic or quiche library.');
end;

procedure TQuicBackend.StartListening(const AHost: string; APort: Integer;
  AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks;
  AAcceptThreads: Integer);
begin
end;

procedure TQuicBackend.StopAccept;
begin
end;

procedure TQuicBackend.ShutdownConn(AConn: Pointer);
begin
end;

procedure TQuicBackend.SignalWorkers;
begin
end;

procedure TQuicBackend.JoinWorkers;
begin
end;

procedure TQuicBackend.RegisterConn(AConn: Pointer);
begin
end;

procedure TQuicBackend.PostRecv(AConn: Pointer);
begin
end;

procedure TQuicBackend.PostSend(AConn: Pointer; const AData: TBytes;
  AActualLen: Integer);
begin
end;

procedure TQuicBackend.PostSendV(AConn: Pointer;
  const AHeaders: TBytes; AHdrLen: Integer;
  const ABody: TBytes; ABodyLen: Integer);
begin
end;

procedure TQuicBackend.SocketClose(AConn: Pointer);
begin
end;

end.
