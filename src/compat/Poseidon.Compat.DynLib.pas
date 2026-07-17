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

{$ENDIF}
{$ENDIF}

end.
