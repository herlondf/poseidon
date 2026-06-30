unit Poseidon.Middleware.Compression;

// Gzip compression middleware for Poseidon.
//
// Compresses text-like responses (JSON, HTML, JS, CSS, XML) when the client
// advertises Accept-Encoding: gzip. Responses smaller than AMinSize bytes
// are left uncompressed to avoid overhead on tiny payloads.
//
// Usage:
//   TPoseidon.Use(TPoseidonMiddlewareCompression.New);         // default: 860 bytes
//   TPoseidon.Use(TPoseidonMiddlewareCompression.New(2048));   // custom threshold

interface

uses
  Poseidon.Callback,
  Poseidon.Request,
  Poseidon.Response,
  Poseidon.Proc;

type
  TPoseidonMiddlewareCompression = class
  public
    class function New(AMinSize: Integer = 860): TPoseidonCallback;
  end;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.ZLib,
  Web.HTTPApp;

function IsCompressibleType(const AContentType: string): Boolean;
begin
  Result := AContentType.Contains('text/') or
            AContentType.Contains('application/json') or
            AContentType.Contains('application/javascript') or
            AContentType.Contains('application/xml') or
            AContentType.Contains('application/x-www-form-urlencoded') or
            AContentType.Contains('image/svg+xml');
end;

procedure GzipBytes(const AInput: TBytes; out AOutput: TBytes);
var
  LOutput: TMemoryStream;
  LZip: TZCompressionStream;
begin
  LOutput := TMemoryStream.Create;
  try
    // WindowBits = 31 (15 + 16) produces a proper gzip stream
    LZip := TZCompressionStream.Create(LOutput, zcDefault, 31);
    try
      if Length(AInput) > 0 then
        LZip.WriteBuffer(AInput[0], Length(AInput));
    finally
      LZip.Free;
    end;
    AOutput := Copy(LOutput.Memory, 0, LOutput.Size);
  finally
    LOutput.Free;
  end;
end;

class function TPoseidonMiddlewareCompression.New(AMinSize: Integer): TPoseidonCallback;
begin
  Result :=
    procedure(Req: TPoseidonRequest; Res: TPoseidonResponse; Next: TNextProc)
    var
      LAcceptEncoding: string;
      LRaw: TWebResponse;
      LContent: string;
      LInput, LCompressed: TBytes;
      LStream: TMemoryStream;
    begin
      Next;

      LAcceptEncoding := Req.Headers.Get('Accept-Encoding');
      if not LAcceptEncoding.Contains('gzip') then
        Exit;

      LRaw := Res.RawWebResponse;

      if not IsCompressibleType(LRaw.ContentType) then
        Exit;

      // ContentStream takes priority over Content in WebBroker;
      // only compress if the response was set via Content (string)
      if LRaw.ContentStream <> nil then
        Exit;

      LContent := LRaw.Content;
      if LContent.IsEmpty then
        Exit;

      LInput := TEncoding.UTF8.GetBytes(LContent);
      if Length(LInput) < AMinSize then
        Exit;

      GzipBytes(LInput, LCompressed);

      LStream := TMemoryStream.Create;
      LStream.WriteBuffer(LCompressed[0], Length(LCompressed));
      LStream.Position := 0;

      LRaw.Content       := '';
      LRaw.ContentStream := LStream;
      LRaw.ContentLength := LStream.Size;
      LRaw.SetCustomHeader('Content-Encoding', 'gzip');
      LRaw.SetCustomHeader('Vary', 'Accept-Encoding');
    end;
end;

end.
