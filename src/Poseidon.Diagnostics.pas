unit Poseidon.Diagnostics;

// Crash diagnostics - turns a fatal signal into a usable report instead of a
// bare address.
//
// WHY: without this, a heap corruption in a long-running server surfaces on
// Linux as nothing but glibc's own line plus the RTL's
//
//   malloc(): unaligned tcache chunk detected
//   Runtime error 232 at 000000000048A2C5
//
// (232 = "Fatal signal raised on a non-Delphi thread"). That address alone is
// useless without the exact binary, and the offending thread is not
// identified. glibc calls abort() the moment it detects corrupted heap
// metadata, so a backtrace taken from the SIGABRT handler points straight at
// the malloc/free call chain that tripped it.
//
// ASYNC-SIGNAL SAFETY: the handler must not allocate - the heap is exactly
// what is already broken when SIGABRT arrives. So it only calls write(2),
// backtrace(3) and backtrace_symbols_fd(3). Everything it prints is a literal
// or is formatted into a stack buffer; there is no string type in the path
// (passing a literal to a `string`/`RawByteString` parameter can allocate).
// backtrace_symbols_fd is specified as not calling malloc - unlike
// backtrace_symbols, which does and must never be used here.
//
// After reporting, the signal goes to the handler installed before this one. On
// a Delphi app that is the RTL's SignalDispatcher, which turns SIGSEGV/BUS/FPE/
// ILL into EAccessViolation, so a nil deref reports its stack here and fails as
// a 500 instead of taking the process down.
//
// SIGABRT is never delegated, since glibc raises it with the heap already
// corrupt, and neither is a signal with no previous handler: those restore the
// default disposition and re-raise so the kernel can still write a core dump.
//
// For readable frames the binary needs symbols: link with -g (dcclinux64 keeps
// them by default) and do NOT strip. Addresses still print without symbols.
//
// Usage:
//   TPoseidonDiagnostics.InstallCrashHandler;   // once, before Listen
//
// Windows: no-op (the RTL already reports faults with an address, and WER
// captures the rest).

interface

type
  TPoseidonDiagnostics = class
  public
    // Installs handlers for SIGSEGV/SIGABRT/SIGBUS/SIGFPE/SIGILL. Idempotent.
    // No-op on Windows.
    class procedure InstallCrashHandler; static;
    // True once InstallCrashHandler has run successfully.
    class function CrashHandlerInstalled: Boolean; static;
    // Short (6 hex chars) id generated once per process, stable for its
    // lifetime. Lets operators visually separate interleaved log lines from
    // different replicas/instances sharing one aggregated log stream, and
    // correlates a crash report back to that same instance's [health] lines.
    class function InstanceId: string; static;
    // The running binary's `.note.gnu.build-id`, as hex, or '' if the binary
    // has none or it could not be read. A crash report names the exact build
    // it came from, instead of the reader having to guess from a deploy
    // timestamp which artifact to fetch for `addr2line`.
    class function BuildId: string; static;
    // Records one line of what the app was doing (last 32 kept, oldest
    // dropped first) - printed with the NEXT crash report from any thread, in
    // the order they happened. A heap-corruption abort almost never happens
    // where it was caused (see the unit header), so the frames alone often
    // land on an innocent bystander; the breadcrumbs are what let a reader
    // reconstruct which request/route was in flight on which thread when it
    // broke, without needing the failure reproduced locally first.
    //
    // Safe to call from any thread. This path allocates (it is normal
    // request-handling code, not signal context) - never call it from inside
    // a signal handler.
    class procedure Breadcrumb(const ACategory, AMessage: string); static;
  end;

implementation

{$IFNDEF MSWINDOWS}

uses
  {$IFDEF FPC}
  SysUtils,
  Classes,
  syncobjs,
  Poseidon.Compat.Posix;
  {$ELSE}
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  Posix.Signal,
  Posix.Unistd;
  {$ENDIF}

const
  CMaxFrames = 64;
  CStdErr = 2;
  CInstanceIdLen = 6;
  // x86-64 syscall number. glibc only exposes gettid() as a function from
  // 2.30 on, and Poseidon targets Linux x86-64 only, so the raw syscall is
  // both safer across base images and async-signal-safe.
  CSysGetTid = 186;
  // sha1 build IDs (the default `ld` produces) are 20 bytes; a couple of
  // linkers emit md5/sha256 (16/32 bytes) instead. 32 covers all of them,
  // hex-encoded below.
  CMaxBuildIdBytes = 32;
  CBuildIdHexLen = CMaxBuildIdBytes * 2;
  // Enough for "who is doing what" without a breadcrumb call turning into a
  // small log line by itself: 31 for a category like 'nfce.emissao', 127 for
  // a message like a route plus an id.
  CMaxBreadcrumbs = 32;
  CBreadcrumbCategoryLen = 31;
  CBreadcrumbMessageLen = 127;
  // ELF64, .note.gnu.build-id: NT_GNU_BUILD_ID.
  CElfNoteTypeGnuBuildId = 3;

function backtrace(ABuffer: PPointer; ASize: Integer): Integer; cdecl;
  external 'libc.so.6' name 'backtrace';
procedure backtrace_symbols_fd(ABuffer: PPointer; ASize: Integer;
  AFd: Integer); cdecl;
  external 'libc.so.6' name 'backtrace_symbols_fd';
function _syscall(ANum: NativeInt): NativeInt; cdecl varargs;
  external 'libc.so.6' name 'syscall';

const
  CHandledSignals: array[0..4] of Integer =
    (SIGSEGV, SIGABRT, SIGBUS, SIGFPE, SIGILL);

type
  // One breadcrumb. Fixed-size and written last-field-first so a concurrent
  // reader either sees the previous complete entry (Seq not yet updated) or
  // this one (Seq updated last, once Category/Message are already in place) -
  // never a torn message attributed to the new Seq. A read racing a write to
  // the very same fields can still tear the text itself; that is an accepted,
  // cosmetic risk for a best-effort diagnostic, not a correctness one.
  TBreadcrumbSlot = record
    // 0 means "never written". Monotonic across the ring, so the reader can
    // tell which of the CMaxBreadcrumbs slots are the newest ones without a
    // separate (and racy) count/head variable.
    Seq: Integer;
    Category: array[0..CBreadcrumbCategoryLen] of AnsiChar;
    Message: array[0..CBreadcrumbMessageLen] of AnsiChar;
  end;

var
  GInstalled: Integer = 0;
  // Captured by sigaction's oldact at install time; read only from signal context.
  GPrevAction: array[0..High(CHandledSignals)] of sigaction_t;
  // Pre-touched at install time so the first backtrace() inside the handler
  // cannot be the one that lazily loads libgcc's unwinder (which allocates).
  GWarmup: array[0..CMaxFrames - 1] of Pointer;
  // Null-terminated, generated once by _EnsureInstanceId. Read directly (no
  // string type) from _CrashHandler, which must stay async-signal-safe.
  GInstanceId: array[0..CInstanceIdLen] of AnsiChar;
  GInstanceIdReady: Integer = 0;
  // Null-terminated hex, read once by _EnsureBuildId. Empty string ('' i.e.
  // GBuildId[0] = #0) when the binary has no build-id note or the ELF could
  // not be parsed - the crash report still prints, just without this line.
  GBuildId: array[0..CBuildIdHexLen] of AnsiChar;
  GBuildIdReady: Integer = 0;
  // The ring. Never resized, never freed - a fixed process-lifetime cost
  // (32 * ~164 bytes, under 6 KB) so the crash handler can read it without
  // allocating.
  GBreadcrumbs: array[0..CMaxBreadcrumbs - 1] of TBreadcrumbSlot;
  GBreadcrumbSeq: Integer = 0;

// Not called from signal context - TGUID.NewGuid is a normal (allocating)
// call, safe here because this only ever runs from ordinary thread code
// (InstanceId's first call, or InstallCrashHandler). _CrashHandler itself
// only ever READS the already-populated GInstanceId buffer.
procedure _EnsureInstanceId;
const
  CHexDigits: array[0..15] of AnsiChar = '0123456789abcdef';
var
  LGuid: TGUID;
  I: Integer;
begin
  if TInterlocked.CompareExchange(GInstanceIdReady, 1, 0) <> 0 then Exit;
  LGuid := TGUID.NewGuid;
  for I := 0 to CInstanceIdLen - 1 do
    GInstanceId[I] := CHexDigits[LGuid.D4[I] and $0F];
  GInstanceId[CInstanceIdLen] := #0;
end;

type
  // Only the fields this unit reads. `packed` matches the on-disk ELF64
  // layout exactly - no compiler-inserted padding to account for.
  TElf64Ehdr = packed record
    e_ident: array[0..15] of Byte;
    e_type, e_machine: Word;
    e_version: Cardinal;
    e_entry, e_phoff, e_shoff: UInt64;
    e_flags: Cardinal;
    e_ehsize, e_phentsize, e_phnum, e_shentsize, e_shnum, e_shstrndx: Word;
  end;

  TElf64Shdr = packed record
    sh_name, sh_type: Cardinal;
    sh_flags, sh_addr, sh_offset, sh_size: UInt64;
    sh_link, sh_info: Cardinal;
    sh_addralign, sh_entsize: UInt64;
  end;

// Reads the `.note.gnu.build-id` note from the running binary's own ELF
// section headers and leaves it hex-encoded in GBuildId. Not called from
// signal context - TFileStream and the byte arrays below allocate, same as
// _EnsureInstanceId, and for the same reason: this only ever runs from
// ordinary thread code (InstallCrashHandler), never from _CrashHandler, which
// only reads the already-populated GBuildId buffer.
procedure _EnsureBuildId;
const
  CHexDigits: array[0..15] of AnsiChar = '0123456789abcdef';
var
  LFile: TFileStream;
  LEhdr: TElf64Ehdr;
  LShdr: TElf64Shdr;
  LShStrTab: TBytes;
  LNote: TBytes;
  LSectionName: AnsiString;
  I: Integer;
  LPos, LNameSz, LDescSz, LNoteType, LPadded: Integer;
  LByteIndex, LOutPos: Integer;
begin
  if TInterlocked.CompareExchange(GBuildIdReady, 1, 0) <> 0 then Exit;
  GBuildId[0] := #0;
  try
    LFile := TFileStream.Create('/proc/self/exe', fmOpenRead or fmShareDenyNone);
    try
      LFile.ReadBuffer(LEhdr, SizeOf(LEhdr));
      if (LEhdr.e_ident[0] <> $7F) or (LEhdr.e_ident[1] <> Ord('E')) or
         (LEhdr.e_ident[2] <> Ord('L')) or (LEhdr.e_ident[3] <> Ord('F')) then
        Exit;

      // The section-header string table, to match ".note.gnu.build-id" by
      // name instead of assuming a fixed section index.
      LFile.Position := LEhdr.e_shoff + Int64(LEhdr.e_shstrndx) * LEhdr.e_shentsize;
      LFile.ReadBuffer(LShdr, SizeOf(LShdr));
      SetLength(LShStrTab, LShdr.sh_size);
      if LShdr.sh_size > 0 then
      begin
        LFile.Position := LShdr.sh_offset;
        LFile.ReadBuffer(LShStrTab[0], LShdr.sh_size);
      end;

      for I := 0 to LEhdr.e_shnum - 1 do
      begin
        LFile.Position := LEhdr.e_shoff + Int64(I) * LEhdr.e_shentsize;
        LFile.ReadBuffer(LShdr, SizeOf(LShdr));
        if (LShdr.sh_name = 0) or (Int64(LShdr.sh_name) >= Length(LShStrTab)) then
          Continue;
        LSectionName := PAnsiChar(@LShStrTab[LShdr.sh_name]);
        if LSectionName <> '.note.gnu.build-id' then
          Continue;
        if LShdr.sh_size = 0 then
          Exit;

        SetLength(LNote, LShdr.sh_size);
        LFile.Position := LShdr.sh_offset;
        LFile.ReadBuffer(LNote[0], LShdr.sh_size);

        // Elf64_Nota: namesz, descsz, type (4 bytes each), then name and desc,
        // each padded up to the next 4-byte boundary. desc is the build-id
        // itself; name is "GNU" and not needed here.
        LPos := 0;
        while LPos + 12 <= Length(LNote) do
        begin
          LNameSz := PCardinal(@LNote[LPos])^;
          LDescSz := PCardinal(@LNote[LPos + 4])^;
          LNoteType := PCardinal(@LNote[LPos + 8])^;
          LPos := LPos + 12;
          LPadded := (LNameSz + 3) and not 3;
          LPos := LPos + LPadded;
          if (LNoteType = CElfNoteTypeGnuBuildId) and (LDescSz > 0) and
             (LPos + LDescSz <= Length(LNote)) then
          begin
            LOutPos := 0;
            for LByteIndex := 0 to LDescSz - 1 do
            begin
              if LOutPos >= CBuildIdHexLen - 1 then Break;
              GBuildId[LOutPos] := CHexDigits[LNote[LPos + LByteIndex] shr 4];
              GBuildId[LOutPos + 1] := CHexDigits[LNote[LPos + LByteIndex] and $0F];
              Inc(LOutPos, 2);
            end;
            GBuildId[LOutPos] := #0;
            Exit;
          end;
          LPadded := (LDescSz + 3) and not 3;
          LPos := LPos + LPadded;
        end;
      end;
    finally
      LFile.Free;
    end;
  except
    // Unreadable /proc/self/exe, truncated ELF, no build-id note: the crash
    // report still prints, just without this line.
    GBuildId[0] := #0;
  end;
end;

procedure _Emit(AMsg: PAnsiChar);
var
  LLen: Integer;
begin
  if AMsg = nil then Exit;
  LLen := 0;
  while AMsg[LLen] <> #0 do Inc(LLen);
  if LLen > 0 then
    __write(CStdErr, AMsg, LLen);
end;

// Unsigned/signed to decimal in a stack buffer. IntToStr allocates.
procedure _EmitInt(AValue: Int64);
var
  LBuf: array[0..23] of AnsiChar;
  LPos: Integer;
  LNeg: Boolean;
begin
  LNeg := AValue < 0;
  if LNeg then AValue := -AValue;
  LPos := High(LBuf);
  if AValue = 0 then
  begin
    LBuf[LPos] := '0';
    Dec(LPos);
  end
  else
    while AValue > 0 do
    begin
      LBuf[LPos] := AnsiChar(Ord('0') + (AValue mod 10));
      AValue := AValue div 10;
      Dec(LPos);
    end;
  if LNeg then
  begin
    LBuf[LPos] := '-';
    Dec(LPos);
  end;
  __write(CStdErr, @LBuf[LPos + 1], High(LBuf) - LPos);
end;

// Returns a pointer to a literal - no allocation, unlike a string result.
function _SignalName(ASigNum: Integer): PAnsiChar;
begin
  if ASigNum = SIGSEGV then
    Result := 'SIGSEGV (invalid memory access)'
  else if ASigNum = SIGABRT then
    Result := 'SIGABRT (abort - usually glibc heap corruption)'
  else if ASigNum = SIGBUS then
    Result := 'SIGBUS (bad memory alignment/access)'
  else if ASigNum = SIGFPE then
    Result := 'SIGFPE (arithmetic fault)'
  else if ASigNum = SIGILL then
    Result := 'SIGILL (illegal instruction)'
  else
    Result := 'unknown signal';
end;

function _SignalSlot(ASigNum: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to High(CHandledSignals) do
    if CHandledSignals[I] = ASigNum then
      Exit(I);
end;

// Raw pointer compare so this does not depend on how SIG_DFL/SIG_IGN are typed
// on Delphi vs FPC.
function _HasPrevHandler(ASlot: Integer): Boolean;
var
  LPtr: Pointer;
begin
  LPtr := PPointer(@GPrevAction[ASlot]._u)^;
  Result := (LPtr <> nil) and (NativeUInt(LPtr) <> 1);
end;

// Prints the ring in the order the breadcrumbs happened, oldest first. Reads
// GBreadcrumbs directly with no lock: a write racing this read can tear one
// entry's text, never more, and never corrupts the walk itself, because Seq
// (checked below) is written only after Category/Message are already in
// place. Taking a lock here instead would risk the one failure mode a crash
// handler cannot survive - the crashing thread already holding it.
procedure _EmitBreadcrumbs;
var
  LNewestSeq, LOldestSeq, LSeq, LSlot: Integer;
begin
  LNewestSeq := TInterlocked.CompareExchange(GBreadcrumbSeq, 0, 0);
  if LNewestSeq <= 0 then Exit;
  LOldestSeq := LNewestSeq - CMaxBreadcrumbs + 1;
  if LOldestSeq < 1 then LOldestSeq := 1;

  _Emit('breadcrumbs:'#10);
  for LSeq := LOldestSeq to LNewestSeq do
  begin
    LSlot := (LSeq - 1) mod CMaxBreadcrumbs;
    // Seq <> LSeq means this slot was never written that far (process just
    // started) or a newer write already claimed it under a torn read of
    // GBreadcrumbSeq above - either way, nothing reliable to print for it.
    if GBreadcrumbs[LSlot].Seq <> LSeq then Continue;
    _Emit('  [');
    _Emit(PAnsiChar(@GBreadcrumbs[LSlot].Category[0]));
    _Emit('] ');
    _Emit(PAnsiChar(@GBreadcrumbs[LSlot].Message[0]));
    _Emit(#10);
  end;
end;

procedure _CrashHandler(ASigNum: Integer; ASigInfo: Psiginfo_t;
  AContext: Pointer); cdecl;
var
  LFrames: array[0..CMaxFrames - 1] of Pointer;
  LCount: Integer;
  LSlot: Integer;
begin
  _Emit(#10'=== POSEIDON CRASH REPORT (iid=');
  _Emit(PAnsiChar(@GInstanceId[0]));
  _Emit(') ==='#10);
  _Emit('build  : ');
  if GBuildId[0] = #0 then
    _Emit('(unknown - no .note.gnu.build-id, or unreadable at startup)')
  else
    _Emit(PAnsiChar(@GBuildId[0]));
  _Emit(#10'signal : ');
  _EmitInt(ASigNum);
  _Emit(' - ');
  _Emit(_SignalName(ASigNum));
  _Emit(#10'tid    : ');
  _EmitInt(_syscall(CSysGetTid));
  _Emit(#10'frames :'#10);

  LCount := backtrace(@LFrames[0], CMaxFrames);
  if LCount > 0 then
    backtrace_symbols_fd(@LFrames[0], LCount, CStdErr)
  else
    _Emit('  <backtrace unavailable>'#10);

  _EmitBreadcrumbs;

  _Emit('=== END CRASH REPORT ==='#10);

  LSlot := _SignalSlot(ASigNum);
  if (ASigNum <> SIGABRT) and (LSlot >= 0) and _HasPrevHandler(LSlot) then
  begin
    if (GPrevAction[LSlot].sa_flags and SA_SIGINFO) <> 0 then
      GPrevAction[LSlot]._u.sa_sigaction(ASigNum, ASigInfo, AContext)
    else
      GPrevAction[LSlot]._u.sa_handler(ASigNum);
    Exit;
  end;

  signal(ASigNum, TSignalHandler(SIG_DFL));
  __raise(ASigNum);
end;

class procedure TPoseidonDiagnostics.InstallCrashHandler;
var
  LSA: sigaction_t;
  I: Integer;
begin
  if TInterlocked.CompareExchange(GInstalled, 1, 0) <> 0 then Exit;

  // Load the unwinder NOW, while the heap is still healthy.
  backtrace(@GWarmup[0], CMaxFrames);
  // Same reasoning: read and parse the ELF now, not from _CrashHandler.
  _EnsureBuildId;

  FillChar(LSA, SizeOf(LSA), 0);
  LSA._u.sa_sigaction := @_CrashHandler;
  // SA_SIGINFO: the RTL's handler is installed that way and reads the fault
  // context, so delegating to it requires passing siginfo/ucontext through.
  LSA.sa_flags := SA_SIGINFO;
  sigemptyset(LSA.sa_mask);
  for I := 0 to High(CHandledSignals) do
    sigaction(CHandledSignals[I], @LSA, @GPrevAction[I]);
end;

class function TPoseidonDiagnostics.CrashHandlerInstalled: Boolean;
begin
  Result := TInterlocked.CompareExchange(GInstalled, 0, 0) <> 0;
end;

class function TPoseidonDiagnostics.InstanceId: string;
begin
  _EnsureInstanceId;
  Result := string(AnsiString(PAnsiChar(@GInstanceId[0])));
end;

class function TPoseidonDiagnostics.BuildId: string;
begin
  _EnsureBuildId;
  Result := string(AnsiString(PAnsiChar(@GBuildId[0])));
end;

class procedure TPoseidonDiagnostics.Breadcrumb(const ACategory, AMessage: string);
var
  LSeq, LSlot: Integer;
  LCategoryA, LMessageA: AnsiString;
begin
  // Claims a slot with one atomic increment; two threads landing on the same
  // slot (a wrap of exactly CMaxBreadcrumbs apart) can interleave their
  // writes below. Accepted for the same reason a lock is not used here: see
  // _EmitBreadcrumbs.
  LSeq := TInterlocked.Increment(GBreadcrumbSeq);
  LSlot := (LSeq - 1) mod CMaxBreadcrumbs;
  LCategoryA := AnsiString(ACategory);
  LMessageA := AnsiString(AMessage);
  FillChar(GBreadcrumbs[LSlot].Category, SizeOf(GBreadcrumbs[LSlot].Category), 0);
  FillChar(GBreadcrumbs[LSlot].Message, SizeOf(GBreadcrumbs[LSlot].Message), 0);
  StrLCopy(PAnsiChar(@GBreadcrumbs[LSlot].Category[0]), PAnsiChar(LCategoryA),
    High(GBreadcrumbs[LSlot].Category));
  StrLCopy(PAnsiChar(@GBreadcrumbs[LSlot].Message[0]), PAnsiChar(LMessageA),
    High(GBreadcrumbs[LSlot].Message));
  // Written last, on purpose: see TBreadcrumbSlot.
  GBreadcrumbs[LSlot].Seq := LSeq;
end;

{$ELSE}

uses
  {$IFDEF FPC}
  SysUtils,
  syncobjs;
  {$ELSE}
  System.SysUtils,
  System.SyncObjs;
  {$ENDIF}

const
  CInstanceIdLen = 6;

var
  GInstanceId: array[0..CInstanceIdLen] of AnsiChar;
  GInstanceIdReady: Integer = 0;

procedure _EnsureInstanceId;
const
  CHexDigits: array[0..15] of AnsiChar = '0123456789abcdef';
var
  LGuid: TGUID;
  I: Integer;
begin
  if TInterlocked.CompareExchange(GInstanceIdReady, 1, 0) <> 0 then Exit;
  LGuid := TGUID.NewGuid;
  for I := 0 to CInstanceIdLen - 1 do
    GInstanceId[I] := CHexDigits[LGuid.D4[I] and $0F];
  GInstanceId[CInstanceIdLen] := #0;
end;

class procedure TPoseidonDiagnostics.InstallCrashHandler;
begin
  // Windows: the RTL already reports faults with an address and WER captures
  // the rest.
end;

class function TPoseidonDiagnostics.CrashHandlerInstalled: Boolean;
begin
  Result := False;
end;

class function TPoseidonDiagnostics.InstanceId: string;
begin
  _EnsureInstanceId;
  Result := string(AnsiString(PAnsiChar(@GInstanceId[0])));
end;

class function TPoseidonDiagnostics.BuildId: string;
begin
  // No crash handler is installed on Windows (WER covers that), so nothing
  // ever reads this - a PE has the equivalent (the CodeView debug directory's
  // GUID+age), but there is no reader for it here yet.
  Result := '';
end;

class procedure TPoseidonDiagnostics.Breadcrumb(const ACategory, AMessage: string);
begin
  // Nothing on Windows ever prints these back (see BuildId) - keeping this a
  // true no-op instead of maintaining a ring nobody reads.
end;

{$ENDIF}

end.
