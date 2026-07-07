unit Poseidon.Middleware.Proxy;

// Reverse proxy middleware.
//
// Usage:
//   App.Use(ProxyMiddleware('http://backend:8080'));
//   App.Use(ProxyMiddlewareWithPrefix('http://backend:8080', '/api'));

interface

uses
  Poseidon.Native.Types;

function ProxyMiddleware(const AUpstream: string): TNativeMiddlewareFunc;
function ProxyMiddlewareWithPrefix(const AUpstream, APrefix: string): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.Net.HttpClient;

procedure ExecuteProxy(const AUpstream, APrefix: string;
  var ACtx: TNativeRequestContext);
var
  LClient: TNetHTTPClient;
  LHTTPReq: TNetHTTPRequest;
  LResponse: IHTTPResponse;
  LPath, LTargetURL: string;
  LBodyStream: TBytesStream;
  LContentType: string;
  I: Integer;
const
  CForwardHeaders: array[0..7] of string = (
    'Authorization', 'Accept', 'Accept-Language', 'Accept-Encoding',
    'Content-Type', 'Cache-Control', 'X-Forwarded-For', 'X-Request-Id');
begin
  LPath := ACtx.Path;
  if (APrefix <> '') and LPath.StartsWith(APrefix, True) then
    LPath := Copy(LPath, Length(APrefix) + 1, MaxInt);
  if LPath = '' then
    LPath := '/';

  if ACtx.QueryString <> '' then
    LTargetURL := AUpstream + LPath + '?' + ACtx.QueryString
  else
    LTargetURL := AUpstream + LPath;

  LClient := TNetHTTPClient.Create(nil);
  LHTTPReq := TNetHTTPRequest.Create(nil);
  LBodyStream := nil;
  try
    LHTTPReq.Client := LClient;

    for I := 0 to High(CForwardHeaders) do
    begin
      var LVal := ACtx.Header(CForwardHeaders[I]);
      if LVal <> '' then
        LHTTPReq.CustomHeaders[CForwardHeaders[I]] := LVal;
    end;

    if Length(ACtx.RawBody) > 0 then
    begin
      LBodyStream := TBytesStream.Create(ACtx.RawBody);
      LBodyStream.Position := 0;
    end;

    try
      LResponse := LHTTPReq.Execute(ACtx.Method, LTargetURL, LBodyStream);

      ACtx.Status := LResponse.StatusCode;
      LContentType := LResponse.ContentType;
      if LContentType = '' then
        LContentType := 'application/octet-stream';
      ACtx.ContentType := LContentType;
      ACtx.Body := LResponse.ContentAsBytes;
    except
      on E: Exception do
      begin
        ACtx.Status := 502;
        ACtx.ContentType := 'application/problem+json';
        ACtx.Body := TEncoding.UTF8.GetBytes(
          '{"type":"about:blank","title":"Bad Gateway","status":502,' +
          '"detail":"' + E.Message + '"}');
      end;
    end;
    ACtx.Handled := True;
  finally
    LBodyStream.Free;
    LHTTPReq.Free;
    LClient.Free;
  end;
end;

function ProxyMiddleware(const AUpstream: string): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      ExecuteProxy(AUpstream, '', ACtx);
    end;
end;

function ProxyMiddlewareWithPrefix(const AUpstream, APrefix: string): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    begin
      if not ACtx.Path.StartsWith(APrefix, True) then
      begin
        ANext();
        Exit;
      end;
      ExecuteProxy(AUpstream, APrefix, ACtx);
    end;
end;

end.
