unit Poseidon.Middleware.Proxy;

interface

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient,
  Poseidon.Proc,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Callback;

type
  TPoseidonMiddlewareProxy = class
  private
    class procedure _Execute(
      const AUpstream, APrefix: string;
      Req: TPoseidonRequest; Res: TPoseidonResponse); static;
  public
    class function New(const AUpstream: string): TPoseidonCallback; static;
    class function NewWithPrefix(const AUpstream, APrefix: string): TPoseidonCallback; static;
  end;

implementation

uses
  Web.HTTPApp;

class procedure TPoseidonMiddlewareProxy._Execute(
  const AUpstream, APrefix: string;
  Req: TPoseidonRequest; Res: TPoseidonResponse);
var
  LClient: TNetHTTPClient;
  LHTTPReq: TNetHTTPRequest;
  LResponse: IHTTPResponse;
  LPath: string;
  LTargetURL: string;
  LBodyStream: TBytesStream;
  LContentLength: Int64;
  LRawReq: TWebRequest;
  LHeaderName, LHeaderValue: string;
  LStatus: Integer;
  LContentType: string;
  LBytes: TBytes;
  I: Integer;
  LKnownHeaders: array[0..7] of string;
begin
  LRawReq := Req.RawWebRequest;

  LPath := Req.PathInfo;
  if (APrefix <> '') and LPath.StartsWith(APrefix, True) then
    LPath := Copy(LPath, Length(APrefix) + 1, MaxInt);
  if LPath = '' then
    LPath := '/';

  if LRawReq.QueryString <> '' then
    LTargetURL := AUpstream + LPath + '?' + LRawReq.QueryString
  else
    LTargetURL := AUpstream + LPath;

  LClient  := TNetHTTPClient.Create(nil);
  LHTTPReq := TNetHTTPRequest.Create(nil);
  LBodyStream := nil;
  try
    LHTTPReq.Client := LClient;

    LKnownHeaders[0] := 'Authorization';
    LKnownHeaders[1] := 'Accept';
    LKnownHeaders[2] := 'Accept-Language';
    LKnownHeaders[3] := 'Accept-Encoding';
    LKnownHeaders[4] := 'Content-Type';
    LKnownHeaders[5] := 'Cache-Control';
    LKnownHeaders[6] := 'X-Forwarded-For';
    LKnownHeaders[7] := 'X-Request-Id';

    for I := 0 to High(LKnownHeaders) do
    begin
      LHeaderName  := LKnownHeaders[I];
      LHeaderValue := LRawReq.GetFieldByName(LHeaderName);
      if LHeaderValue <> '' then
        LHTTPReq.CustomHeaders[LHeaderName] := LHeaderValue;
    end;

    LHTTPReq.CustomHeaders['X-Forwarded-Host'] := LRawReq.Host;

    LContentLength := LRawReq.ContentLength;
    if LContentLength > 0 then
    begin
      LBodyStream := TBytesStream.Create(TEncoding.UTF8.GetBytes(Req.RawBody));
      LBodyStream.Position := 0;
    end;

    try
      LResponse := LHTTPReq.Execute(LRawReq.Method, LTargetURL, LBodyStream);

      LStatus      := LResponse.StatusCode;
      LContentType := LResponse.ContentType;
      LBytes       := LResponse.ContentAsBytes;

      if LContentType = '' then
        LContentType := 'application/octet-stream';

      Res.Status(LStatus).RawSend(LBytes, LContentType);
    except
      on E: Exception do
        Res.Status(502).Send('Bad Gateway: ' + E.Message);
    end;
  finally
    LBodyStream.Free;
    LHTTPReq.Free;
    LClient.Free;
  end;
end;

class function TPoseidonMiddlewareProxy.New(const AUpstream: string): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      _Execute(AUpstream, '', Req, Res);
    end;
end;

class function TPoseidonMiddlewareProxy.NewWithPrefix(const AUpstream, APrefix: string): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    begin
      if not Req.PathInfo.StartsWith(APrefix, True) then
      begin
        Next;
        Exit;
      end;
      _Execute(AUpstream, APrefix, Req, Res);
    end;
end;

end.
