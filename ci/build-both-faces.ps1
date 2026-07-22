<#
    build-both-faces.ps1 — dual-face build gate (issue #204)

    Compiles Poseidon for BOTH targets so a platform-specific bug can never sit
    latent behind an {$IFDEF} that the other platform's CI never exercises:

      * Windows (Win64) : full build of the DUnitX test project (dcc64).
      * Linux   (Linux64): compile check of the epoll / io_uring backends
                           (dcclinux64).

    Linux link step: with the Linux SDK installed (a Linux runner, or PAServer
    on Windows) the harness links fully. Without it (bare Windows box) the LINK
    fails on libc symbols — that is expected and tolerated; only COMPILE errors
    (lines citing a .pas(line)) fail the gate.

    The Windows face invokes dcc64 directly via a PowerShell argument array
    (`& $dcc @argsArr`) rather than `cmd /c build_tests.bat`. The .bat + `cmd /c`
    path was found to fail silently (no output, no build_tests_out.txt) when run
    under the GitHub Actions runner service's process context — reproduced
    consistently there even though the same .bat runs fine from an interactive
    shell. Passing arguments as a PowerShell array sidesteps both the cmd/console
    dependency and the quoting issues a naive single-string PowerShell call used
    to have.

    Usage:  pwsh ci/build-both-faces.ps1  [-Bds "<Studio path>"]
    Exit code 0 = both faces OK; non-zero = a real compile error on some face.
#>
param(
  [string]$Bds = 'C:\Program Files (x86)\Embarcadero\Studio\22.0'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$env:BDS = $Bds

function Test-CompileErrors([string]$log, [string]$face) {
  # A COMPILE error always cites a source position: Foo.pas(123) Error: ...
  # A LINK error cites an object file (Foo.o:) — tolerated for the Linux face.
  if (-not (Test-Path $log)) {
    Write-Host "    ${face}: log not found ($log)" -ForegroundColor Red
    return $true
  }
  $compileErrors = Select-String -Path $log -Pattern '\.pas\(\d+\).*(Error|Fatal):' -AllMatches
  if ($compileErrors) {
    Write-Host "=== $face COMPILE ERRORS ===" -ForegroundColor Red
    $compileErrors | Select-Object -First 40 | ForEach-Object { $_.Line }
    return $true
  }
  return $false
}

$failed = $false

# ---- Windows face: full build of the test suite -------------------------------
Write-Host '=== [1/2] Windows (Win64) — full build of test suite ===' -ForegroundColor Cyan
$testsDir  = Join-Path $root 'tests'
$win64Log  = Join-Path $testsDir 'build_tests_out.txt'
$dcc64     = Join-Path $Bds 'bin\dcc64.exe'
$dcuDebug  = Join-Path $testsDir 'dcu\Debug'
New-Item -ItemType Directory -Force $dcuDebug | Out-Null
$dccArgs = @(
  '--no-config', '-B', '-CC',
  '-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win',
  "-U$Bds\lib\Win64\release;..\src;..\middlewares;.\mocks",
  '-I..\src;..\middlewares;.\mocks',
  '-E.',
  '-N0.\dcu\Debug',
  'Poseidon.Tests.dpr'
)
Push-Location $testsDir
try {
  & $dcc64 @dccArgs 2>&1 | Out-File -FilePath $win64Log -Encoding utf8
} finally { Pop-Location }
if (Test-CompileErrors $win64Log 'Win64') {
  $failed = $true
} else {
  Write-Host '    Win64 OK' -ForegroundColor Green
}

# ---- Linux face: compile check of epoll / io_uring ----------------------------
Write-Host '=== [2/2] Linux (Linux64) — compile check (epoll / io_uring) ===' -ForegroundColor Cyan
cmd /c "`"$root\ci\build-linux-check.bat`"" | Out-Null
$lxLog = "$root\ci\linux_check.txt"
if (Test-CompileErrors $lxLog 'Linux64') {
  $failed = $true
} else {
  $linkOnly = Select-String -Path $lxLog -Pattern "undefined reference to '(socket|bind|listen|recv|send|epoll_|io_uring)" -Quiet
  if ($linkOnly) {
    Write-Host '    Linux64 COMPILE OK (link skipped — no Linux SDK on this host)' -ForegroundColor Green
  } else {
    Write-Host '    Linux64 OK (compiled and linked)' -ForegroundColor Green
  }
}

if ($failed) { Write-Host 'DUAL-FACE GATE: FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'DUAL-FACE GATE: PASSED' -ForegroundColor Green
exit 0
