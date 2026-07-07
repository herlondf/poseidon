unit Poseidon.Exception;

interface

uses
  System.SysUtils,
  Poseidon.Status;

type
  EPoseidonException = class(Exception)
  private
    FStatus: THTTPStatus;
  public
    constructor Create(const AMessage: string; const AStatus: THTTPStatus); reintroduce;
    property Status: THTTPStatus read FStatus;
  end;

  EPoseidonCallbackInterrupted = class(Exception)
  public
    constructor Create; reintroduce;
  end;

  EPoseidonValidation = class(EPoseidonException)
  public
    constructor Create(const AMessage: string); reintroduce;
  end;

implementation

{ EPoseidonException }

constructor EPoseidonException.Create(const AMessage: string; const AStatus: THTTPStatus);
begin
  inherited Create(AMessage);
  FStatus := AStatus;
end;

{ EPoseidonCallbackInterrupted }

constructor EPoseidonCallbackInterrupted.Create;
begin
  inherited Create('Poseidon callback interrupted');
end;

{ EPoseidonValidation }

constructor EPoseidonValidation.Create(const AMessage: string);
begin
  inherited Create(AMessage, THTTPStatus.UnprocessableEntity);
end;

end.
