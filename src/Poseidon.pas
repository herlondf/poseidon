unit Poseidon;

// Poseidon — REST framework for Delphi 11+
// Inspired by Horse (HashLoad/horse), built from scratch.
//
// Quick start:
//   uses Poseidon;
//
//   begin
//     TPoseidon.Get('/ping',
//       procedure(Req: TPoseidonRequest; Res: TPoseidonResponse)
//       begin
//         Res.Send('pong');
//       end);
//     TPoseidon.Listen(9000);
//   end.

interface

uses
  Poseidon.Commons,
  Poseidon.Proc,
  Poseidon.Core,
  Poseidon.Core.RouterTree,
  Poseidon.Core.Group,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback,
  Poseidon.Exception,
  Poseidon.Validation,
  Poseidon.Provider.Indy,
  Poseidon.Provider.IndyDirect
{$IF DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  ,Poseidon.Provider.Native
{$ENDIF}
  ;

type
  // Core types exposed at top level
  THTTPStatus   = Poseidon.Commons.THTTPStatus;
  TMethodType   = Poseidon.Commons.TMethodType;
  TMimeType     = Poseidon.Commons.TMimeType;
  TNextProc     = Poseidon.Proc.TNextProc;
  TProc         = Poseidon.Proc.TProc;

  TPoseidonRequest    = Poseidon.Request.TPoseidonRequest;
  TPoseidonResponse   = Poseidon.Response.TPoseidonResponse;
  TPoseidonCallback   = Poseidon.Callback.TPoseidonCallback;
  TPoseidonCallbackReqRes = Poseidon.Callback.TPoseidonCallbackReqRes;
  TPoseidonCallbackReq    = Poseidon.Callback.TPoseidonCallbackReq;

  EPoseidonException          = Poseidon.Exception.EPoseidonException;
  EPoseidonCallbackInterrupted = Poseidon.Exception.EPoseidonCallbackInterrupted;
  EPoseidonValidation         = Poseidon.Exception.EPoseidonValidation;

  // Route groups
  TPoseidonGroup      = Poseidon.Core.Group.TPoseidonGroup;
  TPoseidonGroupBlock = Poseidon.Core.Group.TPoseidonGroupBlock;

  // Validation attributes (re-exported for use without extra unit)
  RequiredAttribute  = Poseidon.Validation.RequiredAttribute;
  MinLengthAttribute = Poseidon.Validation.MinLengthAttribute;
  MaxLengthAttribute = Poseidon.Validation.MaxLengthAttribute;
  EmailAttribute     = Poseidon.Validation.EmailAttribute;
  RangeAttribute     = Poseidon.Validation.RangeAttribute;
  PatternAttribute   = Poseidon.Validation.PatternAttribute;

  // Default provider: Native (IOCP/epoll) on Windows+Linux, Indy elsewhere
{$IF DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  TPoseidon = class(TPoseidonProviderNative);
{$ELSE}
  TPoseidon = class(TPoseidonProviderIndy);
{$ENDIF}

  // Alternative providers — available for explicit use
  // (CrossSocket: add Poseidon.Provider.CrossSocket to your uses clause manually)
  TPoseidonIndy       = class(TPoseidonProviderIndy);
  TPoseidonIndyDirect = class(TPoseidonProviderIndyDirect);

implementation

end.
