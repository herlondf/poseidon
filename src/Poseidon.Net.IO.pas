unit Poseidon.Net.IO;

// IIOCallbacks and IIOBackend — contracts between TPoseidonNativeServer and the
// platform-specific IO backends (IOCP on Windows, epoll on Linux).
// R-1: extracted from Poseidon.Net.HttpServer to enforce SRP. HttpServer now has
// zero platform-specific {$IFDEF} blocks in its method bodies.

interface

uses
  System.SysUtils;

type
  // Callbacks: IO backend → server
  IIOCallbacks = interface
    ['{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}']
    // Accept thread calls this when a new client socket arrives.
    // The backend has already applied TCP_NODELAY and SO_KEEPALIVE.
    procedure OnNewConn(ASocket: NativeUInt; const AAddr: string);
    // Worker calls this when data is received from a connection.
    procedure OnRecv(AConn: Pointer; const ABuf: PByte; ALen: Cardinal);
    // Worker calls this when all pending send data has been written to the OS.
    // Allows the server to re-arm recv (keep-alive) or close the connection.
    procedure OnSendComplete(AConn: Pointer);
    // Worker calls this when a connection error or graceful EOF is detected.
    procedure OnConnError(AConn: Pointer);
  end;

  // Platform IO backend — implemented by TIOCPBackend (Windows) and TEpollBackend (Linux).
  IIOBackend = interface
    ['{B2C3D4E5-F6A7-8901-BCDE-F12345678901}']
    // --- Lifecycle (call in order during Listen / Stop) ---

    // Sets up IO subsystem, listen socket, workers, and accept thread.
    procedure StartListening(const AHost: string; APort: Integer;
      AWorkerCount: Integer; AFastOpen: Boolean; ACallbacks: IIOCallbacks);

    // Closes listen socket; accept thread exits naturally on next syscall.
    procedure StopAccept;

    // Forces an in-flight connection into error state
    // (SD_BOTH on Windows; SHUT_RDWR on Linux).
    procedure ShutdownConn(AConn: Pointer);

    // Sends one shutdown token per worker thread
    // (null-key IOCP post on Windows; one pipe byte per worker on Linux).
    procedure SignalWorkers;

    // Waits for all worker threads and releases IO resources
    // (CloseHandle(IOCP) + WSACleanup on Windows; close epoll fd + pipe on Linux).
    procedure JoinWorkers;

    // --- Per-connection ---

    // Registers a new connection with the IO subsystem and arms the first recv.
    // Called from server's _OnNewSocket after TNativeConn is created.
    procedure RegisterConn(AConn: Pointer);

    // Re-arms recv after a dispatch cycle
    // (WSARecv on Windows; epoll_ctl MOD EPOLLIN|ONESHOT on Linux).
    procedure PostRecv(AConn: Pointer);

    // Initiates an asynchronous send.
    procedure PostSend(AConn: Pointer; const AData: TBytes; AActualLen: Integer);

    // Platform-specific socket teardown: remove from epoll / close fd or handle.
    // Called from server's _CloseConn after app-level cleanup (SSL, WS, H2) is done.
    procedure SocketClose(AConn: Pointer);
  end;

implementation

end.
