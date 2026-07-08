unit Poseidon.Problem;

interface

uses
  System.SysUtils,
  System.JSON,
  Poseidon.Exception;

type
  TProblemDetail = record
  public
    TypeURI: string;
    Title: string;
    Status: Integer;
    Detail: string;
    Instance: string;
    function ToJSON: TJSONObject;
    class function CanonicalTitle(AStatus: Integer): string; static;
    class function FromException(E: EPoseidonException;
                                 const AInstance: string): TProblemDetail; static;
  end;

implementation

{ TProblemDetail }

class function TProblemDetail.CanonicalTitle(AStatus: Integer): string;
begin
  case AStatus of
    100: Result := 'Continue';
    101: Result := 'Switching Protocols';
    200: Result := 'OK';
    201: Result := 'Created';
    204: Result := 'No Content';
    301: Result := 'Moved Permanently';
    302: Result := 'Found';
    304: Result := 'Not Modified';
    400: Result := 'Bad Request';
    401: Result := 'Unauthorized';
    403: Result := 'Forbidden';
    404: Result := 'Not Found';
    405: Result := 'Method Not Allowed';
    406: Result := 'Not Acceptable';
    409: Result := 'Conflict';
    410: Result := 'Gone';
    422: Result := 'Unprocessable Entity';
    429: Result := 'Too Many Requests';
    500: Result := 'Internal Server Error';
    501: Result := 'Not Implemented';
    502: Result := 'Bad Gateway';
    503: Result := 'Service Unavailable';
  else
    Result := 'Error';
  end;
end;

class function TProblemDetail.FromException(E: EPoseidonException;
  const AInstance: string): TProblemDetail;
begin
  Result.TypeURI := 'about:blank';
  Result.Status := E.Status.ToInteger;
  Result.Title := CanonicalTitle(Result.Status);
  Result.Detail := E.Message;
  Result.Instance := AInstance;
end;

function TProblemDetail.ToJSON: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('type',     TJSONString.Create(TypeURI));
  Result.AddPair('title',    TJSONString.Create(Title));
  Result.AddPair('status',   TJSONNumber.Create(Status));
  if not Detail.IsEmpty then
    Result.AddPair('detail',   TJSONString.Create(Detail));
  if not Instance.IsEmpty then
    Result.AddPair('instance', TJSONString.Create(Instance));
end;

end.
