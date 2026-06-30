unit Poseidon.Middleware.RequestID;

// Reads X-Request-ID from the incoming request; generates a GUID if absent.
// Echoes the ID in X-Request-ID response header.
// Stores the ID in Req.Params under key '__request_id' for handler access.

interface

uses
  Poseidon.Callback,
  Poseidon.Proc;

type
  TPoseidonMiddlewareRequestID = class
  public
    class function New: TPoseidonCallback; static;
  end;

implementation

uses
  System.SysUtils,
  Web.HTTPApp,
  Poseidon.Request,
  Poseidon.Response;

class function TPoseidonMiddlewareRequestID.New: TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LID: string;
    begin
      LID := Req.RawWebRequest.GetFieldByName('X-Request-ID');
      if LID.IsEmpty then
        LID := GUIDToString(TGUID.NewGuid).ToLower.Replace('{', '').Replace('}', '');
      Req.Params.Add('__request_id', LID);
      Res.Header('X-Request-ID', LID);
      Next();
    end;
end;

end.
