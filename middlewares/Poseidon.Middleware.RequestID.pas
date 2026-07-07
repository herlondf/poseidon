unit Poseidon.Middleware.RequestID;

interface

uses
  Poseidon.Native.Types;

function RequestIDMiddleware: TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string); forward;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function RequestIDMiddleware: TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LID: string;
    begin
      LID := ACtx.Header('X-Request-ID');
      if LID = '' then
        LID := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').ToLower;

      AddHeader(ACtx, 'X-Request-ID', LID);
      ANext();
    end;
end;

end.
