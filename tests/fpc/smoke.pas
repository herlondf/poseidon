program smoke;

// FPC / Win64 slice-1 smoke test for issue #5 (Free Pascal compatibility).
//
// Compiles the pure-logic Poseidon units under Free Pascal (x86_64-win64,
// {$MODE DELPHIUNICODE}) and exercises a representative slice of their public
// API. Success = every unit in the closure compiles under FPC AND the basic
// behaviour matches Delphi.
//
// Units forced to compile via `uses`: Status, Exception, Net.Types,
// Net.Security, Net.HTTP1.Parser, Net.HTTP2.HPACK.
//
// Net.Types declares `reference to` (anonymous method) callback types; these
// compile under FPC 3.3.1 with -Mfunctionreferences -Manonymousfunctions
// (see build-fpc.ps1). RunCallbacks exercises one with a capturing closure.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
  {$H+}
{$ENDIF}

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  Generics.Collections,
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  {$ENDIF}
  Poseidon.Status,
  Poseidon.Exception,
  Poseidon.Net.Types,
  Poseidon.Net.Security,
  Poseidon.Net.HTTP1.Parser,
  Poseidon.Net.HTTP2.HPACK;

var
  GOk: Integer = 0;
  GFail: Integer = 0;

procedure Check(const AName: string; ACond: Boolean);
begin
  if ACond then
  begin
    Inc(GOk);
    Writeln('  ok   ', AName);
  end
  else
  begin
    Inc(GFail);
    Writeln(' FAIL  ', AName);
  end;
end;

function AsBytes(const AText: AnsiString): TBytes;
var
  I: Integer;
begin
  SetLength(Result, Length(AText));
  for I := 1 to Length(AText) do
    Result[I - 1] := Byte(AText[I]);
end;

procedure RunStatus;
begin
  Check('Status.Ok = 200', THTTPStatus.Ok.ToInteger = 200);
  Check('Status.NotFound = 404', THTTPStatus.NotFound.ToInteger = 404);
  Check('Status.InternalServerError = 500', THTTPStatus.InternalServerError.ToInteger = 500);
end;

procedure RunSecurity;
var
  LAllowed: TArray<string>;
begin
  SetLength(LAllowed, 2);
  LAllowed[0] := 'GET';
  LAllowed[1] := 'POST';
  Check('IsMethodAllowed GET in [GET,POST]', IsMethodAllowed('GET', LAllowed));
  Check('IsMethodAllowed DELETE not in [GET,POST]', not IsMethodAllowed('DELETE', LAllowed));
end;

procedure RunException;
var
  LEx: EPoseidonException;
begin
  LEx := EPoseidonException.Create('boom', THTTPStatus.BadRequest);
  try
    Check('EPoseidonException.Status = 400', LEx.Status.ToInteger = 400);
    Check('EPoseidonException.Message', LEx.Message = 'boom');
  finally
    LEx.Free;
  end;
end;

procedure RunParser;
var
  LReq: TBytes;
  LMethod, LPath, LQuery: string;
  LHeaders: TArray<TPair<string, string>>;
  LBody: TBytes;
  LKeepAlive, LBad: Boolean;
  LConsumed: Integer;
  LParsed: Boolean;
begin
  LReq := AsBytes('GET /hello?x=1 HTTP/1.1'#13#10 +
                  'Host: example'#13#10 +
                  'Connection: keep-alive'#13#10#13#10);
  LParsed := ParseHTTP1Request(LReq, Length(LReq), 65536, 1048576,
    LMethod, LPath, LQuery, LHeaders, LBody, LKeepAlive, LConsumed, LBad);
  Check('ParseHTTP1Request parsed', LParsed and not LBad);
  Check('  method = GET', LMethod = 'GET');
  Check('  path = /hello', LPath = '/hello');
  Check('  query = x=1', LQuery = 'x=1');
  Check('  keep-alive detected', LKeepAlive);
end;

procedure RunCallbacks;
var
  LHandler: TOnNativeRequest;
  LReq: TPoseidonNativeRequest;
  LStatus: Integer;
  LContentType: string;
  LBody: TBytes;
  LExtra: TArray<TPair<string, string>>;
  LTag: Integer;
begin
  // Exercise a `reference to` callback with a capturing closure — the exact
  // Delphi anonymous-method feature that FPC 3.3.1 unlocks.
  LTag := 418;
  LHandler :=
    procedure(const AReq: TPoseidonNativeRequest;
      out AStatus: Integer; out AContentType: string;
      out ABody: TBytes; out AExtraHeaders: TArray<TPair<string, string>>)
    begin
      AStatus := LTag;                 // captured from the enclosing scope
      AContentType := 'text/plain';
      ABody := TEncoding.UTF8.GetBytes('hi ' + AReq.Path);
      SetLength(AExtraHeaders, 0);
    end;

  LReq := Default(TPoseidonNativeRequest);
  LReq.Path := '/teapot';
  LHandler(LReq, LStatus, LContentType, LBody, LExtra);
  Check('callback closure returns captured status', LStatus = 418);
  Check('callback closure sets content-type', LContentType = 'text/plain');
  Check('callback closure body len > 0', Length(LBody) > 0);
end;

begin
  Writeln('=== Poseidon FPC/Win64 smoke (issue #5) ===');
  RunStatus;
  RunSecurity;
  RunException;
  RunParser;
  RunCallbacks;
  Writeln('---------------------------------------------------');
  Writeln(Format('DONE: %d ok, %d fail', [GOk, GFail]));
  if GFail > 0 then
    Halt(1);
end.
