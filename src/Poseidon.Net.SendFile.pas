unit Poseidon.Net.SendFile;

// Zero-copy file transfer via sendfile(2) on Linux.
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
  {$ELSE}
  , Posix.Errno
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
      begin
        if GetLastError = EINTR then Continue;
        Break;
      end;
    end;
  finally
    _close(LFileFd);
  end;
end;

{$ELSE}

function _WinSend(ASocket: Integer; const ABuf; ALen: Integer): Integer;
type
  TSendFunc = function(s: NativeUInt; const buf; len, flags: Integer): Integer; stdcall;
var
  LSend: TSendFunc;
  LMod: HMODULE;
begin
  LMod := GetModuleHandle('ws2_32.dll');
  @LSend := GetProcAddress(LMod, 'send');
  Result := LSend(NativeUInt(ASocket), ABuf, ALen, 0);
end;

function PoseidonSendFile(ASocket: Integer; const AFilePath: string;
  AOffset, ACount: Int64): Int64;
const
  CReadBufSize = 65536;
var
  LStream: TFileStream;
  LBuf: array[0..CReadBufSize - 1] of Byte;
  LRemain: Int64;
  LChunk: Integer;
  LRead: Integer;
  LSent: Integer;
  LPos: Integer;
begin
  Result := 0;
  LStream := TFileStream.Create(AFilePath, fmOpenRead or fmShareDenyNone);
  try
    LStream.Position := AOffset;
    LRemain := ACount;
    while LRemain > 0 do
    begin
      LChunk := CReadBufSize;
      if LRemain < LChunk then
        LChunk := Integer(LRemain);
      LRead := LStream.Read(LBuf[0], LChunk);
      if LRead <= 0 then
        Break;
      LPos := 0;
      while LPos < LRead do
      begin
        LSent := _WinSend(ASocket, LBuf[LPos], LRead - LPos);
        if LSent <= 0 then
          Exit;
        Inc(LPos, LSent);
      end;
      Dec(LRemain, LRead);
      Inc(Result, LRead);
    end;
  finally
    LStream.Free;
  end;
end;

{$ENDIF}

end.
