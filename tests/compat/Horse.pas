unit Horse;

// Compatibility shim: bridges Horse middleware units to Poseidon.
// This file lives in the CONSUMER project (Docfiscall), not in Poseidon.
// It enables Horse middlewares to compile against Poseidon without modification.

interface

uses
  System.SysUtils,
  Poseidon.Commons,
  Poseidon.Proc,
  Poseidon.Core,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback,
  Poseidon.Exception
{$IF DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  ,Poseidon.Provider.Native
{$ELSE}
  ,Poseidon.Provider.Indy
{$ENDIF}
  ;

type
  THTTPStatus   = Poseidon.Commons.THTTPStatus;
  TMethodType   = Poseidon.Commons.TMethodType;
  TNextProc     = Poseidon.Proc.TNextProc;
  // Horse middlewares use System.SysUtils.TProc for Next param.
  // Must use the SAME TProc type as System.SysUtils for procedure-to-reference
  // implicit conversion to work (Portinari, Pagination use Result := Middleware).
  TProc         = System.SysUtils.TProc;

  THorseRequest    = Poseidon.Request.TPoseidonRequest;
  THorseResponse   = Poseidon.Response.TPoseidonResponse;
  // THorseCallback uses System.SysUtils.TProc (not TNextProc) for the Next param.
  // This matches the original Horse definition and enables procedure-to-reference
  // implicit conversion used by Portinari, Pagination, etc.
  THorseCallback   = reference to procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: System.SysUtils.TProc);
  THorseCallbackRequestResponse = reference to procedure(Req: TPoseidonRequest; Res: TPoseidonResponse);

  EHorseException            = Poseidon.Exception.EPoseidonException;
  EHorseCallbackInterrupted  = Poseidon.Exception.EPoseidonCallbackInterrupted;

{$IF DEFINED(MSWINDOWS) OR DEFINED(LINUX)}
  THorse = class(TPoseidonProviderNative);
{$ELSE}
  THorse = class(TPoseidonProviderIndy);
{$ENDIF}

implementation

end.
