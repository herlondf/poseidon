unit Poseidon.MemoryManager.Linux;

// Replaces Delphi's default FastMM memory manager with libc malloc/free on Linux.
//
// WHY: FastMM uses global heap locks that create severe contention under high
// concurrency on Linux. glibc malloc uses per-thread arenas (ptmalloc2) that
// scale linearly with core count - conceptually the same approach FPC's
// `cmem` unit takes.
//
// #256 (2026-09-16): this unit existed but was not linked into any .dpr, and
// the "8.6x more throughput than FastMM" figure that used to be claimed here
// had NO benchmark or experiment backing it anywhere in this repo - treat it
// as unverified, not as a measured result. Now linked into
// `samples/memory-manager-bench` (see that sample's README for how to run
// it), but the actual before/after measurement still has not been run: doing
// so needs a host that can fully LINK a Linux64 binary (the Linux SDK/
// PAServer sysroot - this repo's own bare Windows dev boxes cannot, see
// `ci/build-both-faces.ps1`'s comment on link-skipped compile checks; the
// CI runner can). Do not restate a throughput number here until that sample
// has actually been run and the result recorded.
//
// USAGE: This unit MUST be the FIRST unit in the .dpr uses clause:
//
//   program MyServer;
//   uses
//     Poseidon.MemoryManager.Linux,  // <-- MUST BE FIRST
//     System.SysUtils,
//     ...
//
// On Windows this unit is a no-op (FastMM remains active).

{$IFDEF LINUX}

interface

implementation

function _malloc(Size: NativeUInt): Pointer; cdecl;
  external 'libc.so.6' name 'malloc';
procedure _free(P: Pointer); cdecl;
  external 'libc.so.6' name 'free';
function _realloc(P: Pointer; Size: NativeUInt): Pointer; cdecl;
  external 'libc.so.6' name 'realloc';
function _calloc(Count, Size: NativeUInt): Pointer; cdecl;
  external 'libc.so.6' name 'calloc';

function LibcGetMem(Size: NativeInt): Pointer;
begin
  Result := _malloc(NativeUInt(Size));
end;

function LibcFreeMem(P: Pointer): Integer;
begin
  _free(P);
  Result := 0;
end;

function LibcReallocMem(P: Pointer; Size: NativeInt): Pointer;
begin
  Result := _realloc(P, NativeUInt(Size));
end;

function LibcAllocMem(Size: NativeInt): Pointer;
begin
  Result := _calloc(1, NativeUInt(Size));
end;

// Stub hooks para leak tracking. Retornam False (nao rastreado). NAO alocam
// via o proprio MM - o RTL invoca esses ponteiros durante shutdown/relatorio
// de leaks; nil aqui causa AV.
function LibcRegisterExpectedMemoryLeak(P: Pointer): Boolean;
begin
  Result := False;
end;

function LibcUnregisterExpectedMemoryLeak(P: Pointer): Boolean;
begin
  Result := False;
end;

procedure _InstallLibcMM;
var
  LMM: TMemoryManagerEx;
begin
  FillChar(LMM, SizeOf(LMM), 0);
  LMM.GetMem := LibcGetMem;
  LMM.FreeMem := LibcFreeMem;
  LMM.ReallocMem := LibcReallocMem;
  LMM.AllocMem := LibcAllocMem;
  LMM.RegisterExpectedMemoryLeak := LibcRegisterExpectedMemoryLeak;
  LMM.UnregisterExpectedMemoryLeak := LibcUnregisterExpectedMemoryLeak;
  SetMemoryManager(LMM);
end;

initialization
  _InstallLibcMM;

{$ELSE}

interface

implementation

// Windows: no-op - FastMM remains active

{$ENDIF}

end.
