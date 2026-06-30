unit Poseidon.Middleware.BodyLimit;

// Rejects requests whose Content-Length exceeds AMaxBytes.
// Returns 413 application/problem+json before the body is consumed.

interface

uses
  Poseidon.Callback,
  Poseidon.Proc;

type
  TPoseidonMiddlewareBodyLimit = class
  public
    class function New(AMaxBytes: Int64): TPoseidonCallback; static;
  end;

implementation

uses
  System.SysUtils,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Commons;

class function TPoseidonMiddlewareBodyLimit.New(AMaxBytes: Int64): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LContentLength: Int64;
    begin
      // Prefer the Content-Length header (available before body is read);
      // fall back to the WebRequest property for servers that populate it differently.
      LContentLength := StrToInt64Def(
        Req.RawWebRequest.GetFieldByName('Content-Length'), 0);
      if LContentLength = 0 then
        LContentLength := Req.RawWebRequest.ContentLength;
      if (LContentLength > 0) and (LContentLength > AMaxBytes) then
      begin
        Res.Status(THTTPStatus.PayloadTooLarge)
           .Header('Content-Type', 'application/problem+json')
           .Send(
             '{"type":"about:blank","title":"Payload Too Large",' +
             '"status":413,"detail":"Request body exceeds limit of ' +
             AMaxBytes.ToString + ' bytes"}');
        Exit;
      end;
      Next();
    end;
end;

end.
