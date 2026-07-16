# Builds and runs the Free Pascal slice-1 smoke test (issue #5).
#
# Compiles the pure-logic Poseidon units + tests/fpc/smoke.pas as an
# x86_64-win64 target using the FPC cross compiler, then runs the resulting
# executable. Exit code 0 = every unit compiled under FPC and the smoke passed.
#
# Requires FPC 3.2.2+ (winget: FreePascal.FreePascalCompiler). Override the
# location with -FpcBin if it is not at the default winget path.

[CmdletBinding()]
param(
  [string]$FpcBin = 'C:\FPC\3.2.2\bin\i386-win32'
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

# -Px86_64 -Twin64 : cross to Win64 (matches Delphi Win64)
# -MDELPHIUNICODE  : Delphi-compatible mode, UnicodeString default
# -Fu / -FU / -FE  : unit search path / unit output / exe output
# -Sew -vw         : warnings visible; do NOT treat notes as errors
& fpc `
  -Px86_64 -Twin64 `
  -MDELPHIUNICODE `
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
