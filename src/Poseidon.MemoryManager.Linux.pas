unit Poseidon.MemoryManager.Linux;

// Replaces Delphi's default FastMM memory manager with libc malloc/free on Linux.
//
// WHY: FastMM uses global heap locks that create severe contention under high
// concurrency on Linux. glibc malloc uses per-thread arenas (ptmalloc2) that
// scale linearly with core count — the same approach FPC uses via its `cmem`
// unit that achieves 8.6x more throughput than Delphi's FastMM.
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
// via o proprio MM — o RTL invoca esses ponteiros durante shutdown/relatorio
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

// Windows: no-op — FastMM remains active

{$ENDIF}

end.
