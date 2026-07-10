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
  System.Generics.Collections,
  System.JSON,
  System.Net.URLClient,
  System.Net.HttpClient,
  System.Net.HttpClientComponent;

// Upstream response headers the proxy must NOT copy verbatim: hop-by-hop
// headers (RFC 7230 §6.1) plus the ones the response builder manages itself
// (Content-Type via ACtx.ContentType, Content-Length recomputed from the body).
function SkipUpstreamHeader(const AName: string): Boolean;
const
  CSkip: array[0..9] of string = (
    'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'te', 'trailer', 'transfer-encoding', 'upgrade',
    'content-type', 'content-length');
var
  I: Integer;
begin
  Result := True;
  for I := 0 to High(CSkip) do
    if SameText(AName, CSkip[I]) then
      Exit;
  Result := False;
end;

function StreamToBytes(AStream: TStream): TBytes;
begin
  if AStream = nil then
    Exit(nil);
  AStream.Position := 0;
  SetLength(Result, AStream.Size);
  if Length(Result) > 0 then
    AStream.ReadBuffer(Result[0], Length(Result));
end;

// Strips the ":port" suffix from a "host:port" RemoteAddr (IPv4 form).
function HostOnly(const AAddr: string): string;
var
  LPos: Integer;
begin
  LPos := AAddr.LastDelimiter(':');
  if LPos >= 0 then
    Result := AAddr.Substring(0, LPos)
  else
    Result := AAddr;
end;

procedure ExecuteProxy(const AUpstream, APrefix: string;
  var ACtx: TNativeRequestContext);
var
  LClient: TNetHTTPClient;
  LHTTPReq: TNetHTTPRequest;
  LResponse: IHTTPResponse;
  LPath, LTargetURL: string;
  LBodyStream: TBytesStream;
  LContentType: string;
  LVal: string;
  LClientXFF: string;
  LHdr: TNetHeader;
  LErrObj: TJSONObject;
  LIdx: Integer;
  I: Integer;
const
  CForwardHeaders: array[0..6] of string = (
    'Authorization', 'Accept', 'Accept-Language', 'Accept-Encoding',
    'Content-Type', 'Cache-Control', 'X-Request-Id');
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
    LHTTPReq.MethodString := ACtx.Method;
    LHTTPReq.URL := LTargetURL;

    for I := 0 to High(CForwardHeaders) do
    begin
      LVal := ACtx.Header(CForwardHeaders[I]);
      if LVal <> '' then
        LHTTPReq.CustomHeaders[CForwardHeaders[I]] := LVal;
    end;

    // #185: append our real peer to X-Forwarded-For instead of trusting the
    // client's header verbatim (which is spoofable).
    LClientXFF := ACtx.Header('X-Forwarded-For');
    if LClientXFF <> '' then
      LHTTPReq.CustomHeaders['X-Forwarded-For'] :=
        LClientXFF + ', ' + HostOnly(ACtx.RemoteAddr)
    else
      LHTTPReq.CustomHeaders['X-Forwarded-For'] := HostOnly(ACtx.RemoteAddr);

    if Length(ACtx.RawBody) > 0 then
    begin
      LBodyStream := TBytesStream.Create(ACtx.RawBody);
      LBodyStream.Position := 0;
      LHTTPReq.SourceStream := LBodyStream;
    end;

    try
      LResponse := LHTTPReq.Execute;

      ACtx.Status := LResponse.StatusCode;
      LContentType := LResponse.MimeType;
      if LContentType = '' then
        LContentType := 'application/octet-stream';
      ACtx.ContentType := LContentType;
      ACtx.Body := StreamToBytes(LResponse.ContentStream);

      // #185: forward all upstream response headers (Set-Cookie, Location,
      // Cache-Control, ETag, ...) except hop-by-hop / builder-managed ones.
      // Drop any value carrying CR/LF to prevent response splitting from a
      // hostile upstream.
      for LHdr in LResponse.Headers do
        if not SkipUpstreamHeader(LHdr.Name) and
           (Pos(#13, LHdr.Name) = 0) and (Pos(#10, LHdr.Name) = 0) and
           (Pos(#13, LHdr.Value) = 0) and (Pos(#10, LHdr.Value) = 0) then
        begin
          LIdx := Length(ACtx.ExtraHeaders);
          SetLength(ACtx.ExtraHeaders, LIdx + 1);
          ACtx.ExtraHeaders[LIdx] :=
            TPair<string, string>.Create(LHdr.Name, LHdr.Value);
        end;
    except
      on E: Exception do
      begin
        ACtx.Status := 502;
        ACtx.ContentType := 'application/problem+json';
        // Build via TJSONObject so E.Message is properly escaped (no injection).
        LErrObj := TJSONObject.Create;
        try
          LErrObj.AddPair('type', 'about:blank');
          LErrObj.AddPair('title', 'Bad Gateway');
          LErrObj.AddPair('status', TJSONNumber.Create(502));
          LErrObj.AddPair('detail', E.Message);
          ACtx.Body := TEncoding.UTF8.GetBytes(LErrObj.ToJSON);
        finally
          LErrObj.Free;
        end;
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
