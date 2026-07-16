# Builds and runs the Free Pascal smoke test (issue #5).
#
# Compiles the Poseidon units in the FPC-supported slice + tests/fpc/smoke.pas
# as an x86_64-win64 target, then runs the resulting executable. Exit code 0 =
# every unit compiled under FPC and the smoke passed.
#
# Requires FPC 3.3.1 (trunk/main): the callback types (`reference to`) need the
# functionreferences / anonymousfunctions modeswitches, which do not exist in
# the 3.2.2 release. Build trunk from source (bootstrap with 3.2.2) or via
# fpcupdeluxe selecting the `trunk` FPC version. Override the compiler location
# with -FpcBin.

[CmdletBinding()]
param(
  [string]$FpcBin = 'C:\fpc-trunk\bin\x86_64-win64'
)

$ErrorActionPreference = 'Stop'
$here    = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir  = Resolve-Path (Join-Path $here '..\..\src')
$compatDir = Resolve-Path (Join-Path $here '..\..\src\compat')
$outDir  = Join-Path $here 'build'
$smoke   = Join-Path $here 'smoke.pas'

if (-not (Test-Path (Join-Path $FpcBin 'fpc.exe'))) {
  Write-Error "fpc.exe not found under $FpcBin. Install FPC 3.2.2+ or pass -FpcBin."
}

$env:PATH = "$FpcBin;$env:PATH"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host "FPC:    $((fpc -iV))  (target x86_64-win64)"
Write-Host "src:    $srcDir"
Write-Host "out:    $outDir`n"

# -Twin64                 : native Win64 target (matches Delphi Win64)
# -MDELPHIUNICODE         : Delphi-compatible mode, UnicodeString default
# -Mfunctionreferences    : enable Delphi `reference to` types (FPC 3.3.1+)
# -Manonymousfunctions    : enable inline anonymous method bodies (FPC 3.3.1+)
# -Fu / -FU / -FE         : unit search path / unit output / exe output
# -vw                     : warnings visible; notes are not errors
& fpc `
  -Twin64 `
  -MDELPHIUNICODE `
  -Mfunctionreferences `
  -Manonymousfunctions `
  -Fu"$srcDir" `
  -Fu"$compatDir" `
  -FU"$outDir" `
  -FE"$outDir" `
  -vw `
  "$smoke"

if ($LASTEXITCODE -ne 0) {
  Write-Error "FPC compilation FAILED (exit $LASTEXITCODE)."
}

$exe = Join-Path $outDir 'smoke.exe'
Write-Host "`n--- running $exe ---"
& $exe
$runExit = $LASTEXITCODE
Write-Host "--- smoke exit: $runExit ---"
exit $runExit
