# Build + run the FULL Poseidon server closure under Free Pascal / Win64 (#5).
#
# Two gates:
#   server_smoke — `uses Poseidon` forces the whole server graph (facade,
#     HttpServer, IOCP/RIO, Connection, SSL, HTTP2, WebSocket, pools) to build
#     and link, and proves init/finalization runs clean.
#   server_run   — boots a real TPoseidonServer (IOCP backend, SyncDispatch) in
#     a thread and issues real HTTP GETs, proving the native server actually
#     SERVES when compiled by FPC.
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

if (-not (Test-Path (Join-Path $FpcBin 'fpc.exe'))) {
  Write-Error "fpc.exe not found under $FpcBin. Build FPC 3.3.1 trunk or pass -FpcBin."
}

$env:PATH = "$FpcBin;$env:PATH"
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

Write-Host "FPC:    $((fpc -iV))  (target x86_64-win64)"
Write-Host "src:    $srcDir`n"

function Build-And-Run([string]$prog) {
  Write-Host "=== $prog ==="
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
    (Join-Path $here "$prog.pas") | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Error "${prog}: FPC compilation FAILED (exit $LASTEXITCODE)." }

  $exe = Join-Path $outDir "$prog.exe"
  & $exe
  $rc = $LASTEXITCODE
  Write-Host "--- $prog exit: $rc ---`n"
  if ($rc -ne 0) { Write-Error "${prog}: FAILED at runtime (exit $rc)." }
}

Build-And-Run 'server_smoke'
Build-And-Run 'server_run'

Write-Host 'FPC SERVER GATE: PASSED (compile+link+init AND runtime serve)'
