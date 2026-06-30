unit Poseidon.Provider.Abstract;

interface

uses
  System.SysUtils,
  Poseidon.Proc,
  Poseidon.Core;

type
  TPoseidonProviderAbstract = class(TPoseidonCore)
  private
    class var FOnListen: TProc;
    class var FOnStopListen: TProc;
  protected
    class procedure DoOnListen;
    class procedure DoOnStopListen;
  public
    class property OnListen: TProc read FOnListen write FOnListen;
    class property OnStopListen: TProc read FOnStopListen write FOnStopListen;

    class procedure Listen; overload; virtual; abstract;
    class procedure StopListen; virtual;
  end;

implementation

class procedure TPoseidonProviderAbstract.DoOnListen;
begin
  if Assigned(FOnListen) then
    FOnListen();
end;

class procedure TPoseidonProviderAbstract.DoOnStopListen;
begin
  if Assigned(FOnStopListen) then
    FOnStopListen();
end;

class procedure TPoseidonProviderAbstract.StopListen;
begin
  raise Exception.Create('StopListen not implemented for this provider');
end;

end.
