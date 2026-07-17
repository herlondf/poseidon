unit Poseidon.Compat.DynLib;

// Free Pascal dynamic-library loading for Poseidon.Net.SSL (issue #5).
//
// Poseidon.Net.SSL loads libssl/libcrypto at runtime via LoadLibrary /
// GetProcAddress / FreeLibrary (Windows) or dlopen/dlsym/dlclose (POSIX). On
// FPC/Win64 those three Windows entry points live in the `Windows` unit — but
// pulling `Windows` into Poseidon.Net.SSL's scope SHADOWS syncobjs.TCriticalSection
// with the Win32 CRITICAL_SECTION record (Pascal is case-insensitive), breaking
// `TCriticalSection.Create`. `uses` is NOT transitive, so this unit re-exports
// just the three loaders under clean names and keeps `Windows` out of the SSL
// unit's scope. FPC-only; under Delphi SSL uses Winapi.Windows directly.

{$IFDEF FPC}
  {$MODE DELPHIUNICODE}
{$ENDIF}

interface

{$IFDEF FPC}
{$IFDEF MSWINDOWS}

// Signatures match the calls in Poseidon.Net.SSL.TryLoadLib / RequireProc:
// LoadLibrary(PChar(name)) and GetProcAddress(handle, PChar(name)); handles are
// carried as NativeUInt (TPoseidonLibHandle) on both platforms.
function LoadLibrary(AName: PChar): NativeUInt;
function GetProcAddress(ALib: NativeUInt; AName: PChar): Pointer;
function FreeLibrary(ALib: NativeUInt): Boolean;

{$ELSE}

// POSIX: the SSL unit's Linux branch calls dlopen/dlsym/dlclose with the Delphi
// Posix.Dlfcn shapes (MarshaledAString args, RTLD_* flags). FPC has no Posix.*
// units — this mirrors that slice over FPC's `dl` unit so the SSL body compiles
// unchanged. Handles are NativeUInt (TPoseidonLibHandle).
type
  MarshaledAString = PAnsiChar;

const
  RTLD_LAZY   = 1;
  RTLD_NOW    = 2;
  RTLD_GLOBAL = 256;
  RTLD_LOCAL  = 0;

function dlopen(AName: MarshaledAString; AFlag: LongInt): NativeUInt;
function dlsym(ALib: NativeUInt; AName: MarshaledAString): Pointer;
function dlclose(ALib: NativeUInt): LongInt;

{$ENDIF}
{$ENDIF}

implementation

{$IFDEF FPC}
{$IFDEF MSWINDOWS}

uses
  SysUtils,
  Windows;

function LoadLibrary(AName: PChar): NativeUInt;
begin
  Result := NativeUInt(Windows.LoadLibraryW(AName));
end;

function GetProcAddress(ALib: NativeUInt; AName: PChar): Pointer;
begin
  // GetProcAddress is ANSI-only at the OS level (no wide variant); convert.
  Result := Pointer(Windows.GetProcAddress(Windows.HMODULE(ALib),
    PAnsiChar(AnsiString(AName))));
end;

function FreeLibrary(ALib: NativeUInt): Boolean;
begin
  Result := Windows.FreeLibrary(Windows.HMODULE(ALib));
end;

{$ELSE}

uses
  dl;

function dlopen(AName: MarshaledAString; AFlag: LongInt): NativeUInt;
begin
  Result := NativeUInt(dl.dlopen(AName, AFlag));
end;

function dlsym(ALib: NativeUInt; AName: MarshaledAString): Pointer;
begin
  Result := dl.dlsym(Pointer(ALib), AName);
end;

function dlclose(ALib: NativeUInt): LongInt;
begin
  Result := dl.dlclose(Pointer(ALib));
end;

{$ENDIF}
{$ENDIF}

end.
