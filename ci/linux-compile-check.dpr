program linux_compile_check;

// Linux-face COMPILE CHECK harness (issue #204).
//
// Windows CI never compiles the epoll / io_uring backends (they live behind
// {$IFDEF} / {$ELSE} for non-Windows), so a bug there stays LATENT until a
// Linux deploy. This harness pulls in the units that select the Linux I/O
// backends so dcclinux64 must compile them.
//
// On a Windows box WITHOUT the Linux SDK the LINK step fails (undefined
// reference to libc symbols such as 'socket'/'bind') — that is expected and is
// NOT a source defect. A clean COMPILE (every unit → .dcu/.o, zero errors that
// cite a .pas(line)) is the signal we gate on. On a Linux runner with the SDK
// installed the same harness links to a real (empty) executable.

{$APPTYPE CONSOLE}

uses
  Poseidon.Net.Types,
  Poseidon.Net.HttpServer,
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Net.HTTP2,
  Poseidon.Net.HTTP2.HPACK,
  Poseidon.Net.HTTP2.Manager,
  Poseidon.Net.WebSocket,
  Poseidon.Net.WebSocket.Manager,
  Poseidon.Net.Dispatcher,
  Poseidon.Net.HTTP1.Parser,
  Poseidon.Net.ResponseBuilder,
  Poseidon.Net.Security,
  Poseidon.Net.ProxyProtocol;

begin
end.
