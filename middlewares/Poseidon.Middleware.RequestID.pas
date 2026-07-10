unit Poseidon.Middleware.RequestID;

interface

uses
  Poseidon.Native.Types;

function RequestIDMiddleware: TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Generics.Collections;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string); forward;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

// #M21: a client-supplied X-Request-ID is echoed into the response header and
// into logs. Accept it only if it is short and made of safe visible ASCII —
// otherwise a CR/LF would enable header injection / log forging.
function IsSafeRequestID(const AID: string): Boolean;
var
  I: Integer;
begin
  Result := False;
  if (AID = '') or (Length(AID) > 128) then
    Exit;
  for I := 1 to Length(AID) do
    if (AID[I] < #$21) or (AID[I] > #$7E) then
      Exit;
  Result := True;
end;

function RequestIDMiddleware: TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LID: string;
    begin
      LID := ACtx.Header('X-Request-ID');
      if not IsSafeRequestID(LID) then
        LID := TGUID.NewGuid.ToString.Replace('{', '').Replace('}', '').ToLower;

      AddHeader(ACtx, 'X-Request-ID', LID);
      ANext();
    end;
end;

end.
