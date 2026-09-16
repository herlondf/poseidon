unit Poseidon.Net.SendFile;

// Zero-copy file transfer via sendfile(2) on Linux.
// Falls back to read+send on Windows.
//
// #251 (2026-09-16): attempted TransmitFile on Windows here and reverted -
// see the "NOT DONE" note below before trying again.
//
// #251-adjacent finding, unrelated to the attempt below: as of 2026-09-16,
// NOTHING in this repo actually calls PoseidonSendFile - grep the whole
// tree. The Static middleware (Poseidon.Middleware.Static.pas) serves files
// via TFile.ReadAllBytes into Ctx.Body, going through the normal buffered
// response path on BOTH platforms, not this unit. So today the real
// sendfile(2) path on Linux is equally unused - wiring this into Static (or
// a future streaming-response feature) means bypassing the normal Ctx.Body
// pipeline for large static files, which touches response-completion/
// keep-alive bookkeeping and deserves its own scoped session.
//
// NOT DONE: TransmitFile was implemented (both as a raw mswsock.dll static
// import, then again resolved properly via
// WSAIoctl(SIO_GET_EXTENSION_FUNCTION_POINTER, WSAID_TRANSMITFILE) - the
// same pattern Poseidon.Net.IO.IOCP._LoadExtensions uses for AcceptEx) and
// validated with a live loopback smoke test (real listener + client socket,
// real file, byte-for-byte comparison) before being considered for commit.
// BOTH versions hung forever on the actual TransmitFile call itself on this
// dev machine - reproduced repeatedly, resolution succeeded
// (Assigned(LFunc) = True) but the call never returned, with a synchronous
// (lpOverlapped = nil) invocation. This was caught specifically BECAUSE it
// was tested live rather than just compiled - reverted rather than shipped,
// since a synchronous hang on every static-file response would be a much
// worse regression than the existing (correct, if not zero-copy) read+send
// fallback. Root cause not confirmed - plausible suspects: a Layered
// Service Provider in this machine's Winsock catalog (corporate VPN/
// endpoint security software is common on a managed dev box) intercepting
// TransmitFile with a broken/hanging implementation of its own, or some
// other environment-specific Winsock quirk. Whoever picks this up next
// should: (1) test on a clean Windows host with no corporate security
// software first, to rule out environment-specific interference; (2) if it
// still hangs, use the OVERLAPPED-with-a-real-event pattern (not
// lpOverlapped = nil) with a bounded WaitForSingleObject timeout, so a
// broken implementation degrades to the read+send fallback instead of
// hanging the request forever, no matter the environment it eventually
// deploys to.

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
