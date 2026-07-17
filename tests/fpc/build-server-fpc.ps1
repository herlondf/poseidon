# Compile the FULL Poseidon server closure under Free Pascal / Win64 (issue #5).
#
# Unlike build-fpc.ps1 (pure-logic slice), this drives `uses Poseidon` through
# FPC to force the entire server graph to build + link: facade, HttpServer, the
# IOCP/RIO backends, Connection, SSL, HTTP2, WebSocket, pools. It is the
# compile-gate for the syscall-layer port. Exit 0 = the whole closure builds.
#
# Requires FPC 3.3.1 (trunk). Override the compiler dir with -FpcBin.

[CmdletBinding()]
param(
  [string]$FpcBin = 'C:\fpc-trunk\bin\x86_64-win64'
)

$ErrorActionPreference = 'Stop'
$here      = Split-Path -Parent $MyInvocation.MyCommand.Path
$srcDir    = Resolve-Path (Join-Path $here '..\..\src')
$compatDir = Resolve-Path (Join-Path $here '..\..\src\compat')
$outDir    = Join-Path $here 'build-server'
$prog      = Join-Path $here 'server_smoke.pas'

if (-not (Test-Path (Join-Path $FpcBin 'fpc.exe'))) {
  Write-Error "fpc.exe not found under $FpcBin. Build FPC 3.3.1 trunk or pass -FpcBin."
}

$env:PATH = "$FpcBin;$env:PATH"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host "FPC:    $((fpc -iV))  (target x86_64-win64)"
Write-Host "src:    $srcDir"
Write-Host "out:    $outDir`n"

& fpc `
  -Twin64 `
  -MDELPHIUNICODE `
  -Mfunctionreferences `
  -Manonymousfunctions `
  -Mprefixedattributes `
  -Fu"$srcDir" `
  -Fu"$compatDir" `
  -FU"$outDir" `
  -FE"$outDir" `
  -vw `
  "$prog"

if ($LASTEXITCODE -ne 0) {
  Write-Error "FPC server-closure compilation FAILED (exit $LASTEXITCODE)."
}

$exe = Join-Path $outDir 'server_smoke.exe'
Write-Host "`n--- running $exe ---"
& $exe
$runExit = $LASTEXITCODE
Write-Host "--- server_smoke exit: $runExit ---"
exit $runExit
