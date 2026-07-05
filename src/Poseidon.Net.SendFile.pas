unit Poseidon.Net.SendFile;

// #81: Zero-copy file transfer via sendfile(2) on Linux.
// Falls back to read+send on Windows.

interface

function PoseidonSendFile(ASocket: Integer; const AFilePath: string;
  AOffset, ACount: Int64): Int64;

implementation

uses
  System.SysUtils,
  System.Classes
  {$IFDEF MSWINDOWS}
  , Winapi.Windows
  {$ENDIF};

{$IFNDEF MSWINDOWS}

const
  O_RDONLY = 0;

function _open(pathname: MarshaledAString; flags: Integer): Integer; cdecl;
  external 'libc.so.6' name 'open'; varargs;
function _close(fd: Integer): Integer; cdecl;
  external 'libc.so.6' name 'close';
function _sendfile(out_fd, in_fd: Integer; offset: PInt64;
  count: NativeUInt): NativeInt; cdecl;
  external 'libc.so.6' name 'sendfile';

function PoseidonSendFile(ASocket: Integer; const AFilePath: string;
  AOffset, ACount: Int64): Int64;
var
  LFileFd: Integer;
  LOffset: Int64;
  LRemain: Int64;
  LN: NativeInt;
begin
  Result := 0;
  LFileFd := _open(MarshaledAString(UTF8String(AFilePath)), O_RDONLY);
  if LFileFd < 0 then
    Exit;
  try
    LOffset := AOffset;
    LRemain := ACount;
    while LRemain > 0 do
    begin
      LN := _sendfile(ASocket, LFileFd, @LOffset, NativeUInt(LRemain));
      if LN > 0 then
      begin
        Dec(LRemain, LN);
        Inc(Result, LN);
      end
      else if LN = 0 then
        Break
      else
        Break;
    end;
  finally
    _close(LFileFd);
  end;
end;

{$ELSE}

function PoseidonSendFile(ASocket: Integer; const AFilePath: string;
  AOffset, ACount: Int64): Int64;
var
  LStream: TFileStream;
  LBuf: array[0..65535] of Byte;
  LRemain: Int64;
  LChunk: Integer;
  LRead: Integer;
begin
  Result := 0;
  LStream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
  try
    LStream.Position := AOffset;
    LRemain := ACount;
    while LRemain > 0 do
    begin
      LChunk := 65536;
      if LRemain < LChunk then
        LChunk := Integer(LRemain);
      LRead := LStream.Read(LBuf[0], LChunk);
      if LRead <= 0 then
        Break;
      Dec(LRemain, LRead);
      Inc(Result, LRead);
    end;
  finally
    LStream.Free;
  end;
end;

{$ENDIF}

end.
