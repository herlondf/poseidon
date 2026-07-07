unit Poseidon;

// Poseidon — REST framework for Delphi 11+
// Built for performance: zero-copy native API with IOCP/epoll.
//
// Quick start (native API — recommended):
//   uses Poseidon;
//
//   var
//     App: TPoseidonServer;
//   begin
//     App := TPoseidonServer.Create;
//     try
//       App.Get('/ping',
//         procedure(var Ctx: TNativeRequestContext)
//         begin
//           Ctx.Status := 200;
//           Ctx.ContentType := 'text/plain';
//           Ctx.Body := TEncoding.UTF8.GetBytes('pong');
//         end);
//       App.Listen(9000);
//     finally
//       App.Free;
//     end;
//   end.

interface

uses
  Poseidon.Status,
  Poseidon.Native.Types,
  Poseidon.Native.Server,
  Poseidon.Native.Group,
  Poseidon.Net.WebSocket,
  Poseidon.Net.Types,
  Poseidon.Exception,
  Poseidon.Problem;

type
  // Primary API — native zero-copy
  TPoseidonServer = Poseidon.Native.Server.TPoseidonServer;
  TNativeRequestContext = Poseidon.Native.Types.TNativeRequestContext;
  PNativeRequestContext = Poseidon.Native.Types.PNativeRequestContext;
  TNativeHandler = Poseidon.Native.Types.TNativeHandler;
  TNativeHandlerFunc = Poseidon.Native.Types.TNativeHandlerFunc;
  TNativeMiddleware = Poseidon.Native.Types.TNativeMiddleware;
  TNativeMiddlewareFunc = Poseidon.Native.Types.TNativeMiddlewareFunc;
  TNativeGroup = Poseidon.Native.Group.TNativeGroup;
  TNativeGroupBlock = Poseidon.Native.Group.TNativeGroupBlock;

  // WebSocket
  IPoseidonWSConn = Poseidon.Net.WebSocket.IPoseidonWSConn;
  TWSMessageCallback = Poseidon.Net.WebSocket.TWSMessageCallback;

  // Error handling
  EPoseidonException = Poseidon.Exception.EPoseidonException;
  EPoseidonCallbackInterrupted = Poseidon.Exception.EPoseidonCallbackInterrupted;
  EPoseidonValidation = Poseidon.Exception.EPoseidonValidation;
  TProblemDetail = Poseidon.Problem.TProblemDetail;

  // HTTP status and MIME types
  THTTPStatus = Poseidon.Status.THTTPStatus;
  TMimeType = Poseidon.Status.TMimeType;

  // Server types
  TLogLevel = Poseidon.Net.Types.TLogLevel;
  TOnPoseidonLog = Poseidon.Net.Types.TOnPoseidonLog;
  TOnPoseidonRequestLog = Poseidon.Net.Types.TOnPoseidonRequestLog;

implementation

end.
