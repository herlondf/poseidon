unit Poseidon.Middleware.Compression;

// Gzip compression middleware.
// Compresses text-like responses when client advertises Accept-Encoding: gzip.
//
// Usage:
//   App.Use(CompressionMiddleware);
//   App.Use(CompressionMiddleware(2048));

interface

uses
  Poseidon.Native.Types;

function CompressionMiddleware(AMinSize: Integer = 860): TNativeMiddlewareFunc;

implementation

uses
  System.SysUtils,
  System.Classes,
  System.ZLib;

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
    LZip := TZCompressionStream.Create(LOutput, zcDefault, 31);
    try
      if Length(AInput) > 0 then
        LZip.WriteBuffer(AInput[0], Length(AInput));
    finally
      LZip.Free;
    end;
    SetLength(AOutput, LOutput.Size);
    if LOutput.Size > 0 then
      Move(LOutput.Memory^, AOutput[0], LOutput.Size);
  finally
    LOutput.Free;
  end;
end;

procedure AddHeader(var ACtx: TNativeRequestContext; const AName, AValue: string);
var
  LLen: Integer;
begin
  LLen := Length(ACtx.ExtraHeaders);
  SetLength(ACtx.ExtraHeaders, LLen + 1);
  ACtx.ExtraHeaders[LLen] := TPair<string,string>.Create(AName, AValue);
end;

function CompressionMiddleware(AMinSize: Integer): TNativeMiddlewareFunc;
begin
  Result :=
    procedure(var ACtx: TNativeRequestContext; ANext: TProc)
    var
      LAcceptEncoding: string;
      LCompressed: TBytes;
    begin
      ANext();

      LAcceptEncoding := ACtx.Header('Accept-Encoding');
      if not LAcceptEncoding.Contains('gzip') then
        Exit;

      if not IsCompressibleType(ACtx.ContentType) then
        Exit;

      if Length(ACtx.Body) < AMinSize then
        Exit;

      GzipBytes(ACtx.Body, LCompressed);

      ACtx.Body := LCompressed;
      AddHeader(ACtx, 'Content-Encoding', 'gzip');
      AddHeader(ACtx, 'Vary', 'Accept-Encoding');
    end;
end;

end.
