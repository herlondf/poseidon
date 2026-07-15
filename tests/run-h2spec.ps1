<#
    run-h2spec.ps1 — HTTP/2 conformance of Poseidon (h2spec) on a throwaway WSL distro.

    Self-contained: (1) cross-compiles a headless h2-over-TLS Poseidon server for
    Linux64 (dcclinux64 + the Benchmark linker stubs — no PAServer/SDK needed),
    (2) DESTROYS the target WSL distro if it exists and creates it fresh from
    Ubuntu-24.04, (3) provisions it (openssl + h2spec), (4) runs the server and
    h2spec against it, (5) prints the conformance summary. Optionally tears the
    distro down again.

    Why WSL: the h2 server is exercised on LINUX because this project's Windows
    hosts can have a Winsock that rejects AcceptEx/RIO (WSAEINVAL — see #203),
    while the Linux epoll/io_uring build serves normally.

    Usage:
      pwsh tests/run-h2spec.ps1                 # create, test, keep the distro
      pwsh tests/run-h2spec.ps1 -Cleanup        # unregister the distro when done
      pwsh tests/run-h2spec.ps1 -Distro Foo -Port 9445

    Requires: RAD Studio (dcclinux64), WSL2, and the Benchmark repo's
    tools\linux_stubs (BenchmarkRoot below).
#>
param(
  [string]$Distro        = 'PoseidonH2Spec',
  [int]   $Port          = 9444,
  [string]$Bds           = 'C:\Program Files (x86)\Embarcadero\Studio\22.0',
  [string]$BenchmarkRoot = 'D:\IA\Projetos\Delphi\Benchmark',
  [switch]$Cleanup,
  [switch]$SkipBuild,
  # CI-safe mode: reuse an ALREADY-provisioned distro instead of unregister/
  # install/wsl --shutdown (which would kill the user's other running distros).
  # The distro must already exist and have openssl + h2spec installed (a prior
  # non-Reuse run provisions it). Only the ELF is rebuilt and h2spec re-run.
  [switch]$Reuse
)

$ErrorActionPreference = 'Stop'
$here      = $PSScriptRoot                      # ...\Poseidon\tests
$repoRoot  = Split-Path -Parent $here           # ...\Poseidon
$h2dir     = Join-Path $here 'h2spec'
$dprName   = 'poseidon-h2spec-server'
$elfWin    = Join-Path $h2dir "bin\$dprName"
# Windows path -> WSL /mnt path (drive letter lowercased)
$elfWsl    = [regex]::Replace(($elfWin -replace '\\','/'), '^([A-Za-z]):', { param($m) '/mnt/' + $m.Groups[1].Value.ToLower() })
$h2dirWsl  = [regex]::Replace(($h2dir  -replace '\\','/'), '^([A-Za-z]):', { param($m) '/mnt/' + $m.Groups[1].Value.ToLower() })

function Say($m, $c='Cyan') { Write-Host $m -ForegroundColor $c }

# ── 1. Cross-compile the Linux h2 server ───────────────────────────────────────
if (-not $SkipBuild) {
  Say '=== [1/5] Cross-compiling headless h2-over-TLS server for Linux64 ==='
  $dcc   = Join-Path $Bds 'bin\dcclinux64.exe'
  $stubs = Join-Path $BenchmarkRoot 'tools\linux_stubs'
  $rtl   = Join-Path $Bds 'lib\linux64\release'
  if (-not (Test-Path $dcc))   { throw "dcclinux64 not found: $dcc" }
  if (-not (Test-Path $stubs)) { throw "Linux linker stubs not found: $stubs (Benchmark repo)" }
  $bin = Join-Path $h2dir 'bin'; $dcu = Join-Path $bin 'dcu'
  New-Item -ItemType Directory -Force $bin, $dcu | Out-Null
  $sp = @('.\', '..\..\src', '..\..\middlewares') -join ';'
  $ns = @('System','System.Win','Winapi','Data','Data.Win','Datasnap','Datasnap.Win','Web','Web.Win','Posix') -join ';'
  $a = @("$dprName.dpr", '-B', "-U$sp", "-N$dcu", "-E$bin", "-NS$ns", "--libpath:$stubs;$rtl", '-$O+', '-$D-', '-Q')
  Push-Location $h2dir
  try { $out = & $dcc @a 2>&1; $code = $LASTEXITCODE } finally { Pop-Location }
  $errs = $out | Where-Object { $_ -match '\bError\b|\bFatal\b' }
  if ($code -ne 0 -or $errs) { $errs | Select-Object -First 20 | ForEach-Object { $_ }; throw "Linux build failed (exit $code)" }
  if (-not (Test-Path $elfWin)) { throw "ELF not produced: $elfWin" }
  Say "    Linux ELF: $elfWin" Green
}

# ── 2. (Re)create the throwaway distro ─────────────────────────────────────────
function Try-Boot { (wsl -d $Distro -u root -- bash -c 'echo BOOT_OK' 2>&1 | ForEach-Object { $_ -replace '\0','' }) -match 'BOOT_OK' }

if ($Reuse) {
  Say "=== [2/5] Reusing existing distro '$Distro' (CI-safe: no recreate) ==="
  $existing = (wsl --list --quiet 2>$null | ForEach-Object { $_ -replace '\0','' }) -contains $Distro
  if (-not $existing) {
    throw "Distro '$Distro' not found. Run once WITHOUT -Reuse to create+provision it."
  }
  if (-not (Try-Boot)) { throw "Distro '$Distro' will not boot (do NOT wsl --shutdown in -Reuse mode)." }
  Say '    distro up (reused)' Green

  Say '=== [3/5] Provisioning skipped (-Reuse) ==='
} else {
  Say "=== [2/5] Recreating WSL distro '$Distro' (Ubuntu-24.04) ==="
  $existing = (wsl --list --quiet 2>$null | ForEach-Object { $_ -replace '\0','' }) -contains $Distro
  if ($existing) { Say "    unregistering existing '$Distro'"; wsl --unregister $Distro | Out-Null }
  $loc = Join-Path $h2dir ".wsl\$Distro"
  New-Item -ItemType Directory -Force $loc | Out-Null
  wsl --install Ubuntu-24.04 --name $Distro --location $loc --no-launch | Out-Null

  # First boot on a busy WSL host often needs a VM reset (HCS timeout).
  if (-not (Try-Boot)) {
    Say '    first boot timed out — wsl --shutdown then retry (briefly stops other distros)' Yellow
    wsl --shutdown | Out-Null; Start-Sleep 6
    if (-not (Try-Boot)) { throw "Distro '$Distro' will not boot." }
  }
  Say '    distro up' Green

  # ── 3. Provision (openssl + h2spec) ──────────────────────────────────────────
  Say '=== [3/5] Provisioning (openssl, h2spec) ==='
  $prov = wsl -d $Distro -u root -- bash "$h2dirWsl/provision-in-wsl.sh" 2>&1
  $prov | ForEach-Object { $_ }
  if (-not ($prov -match 'PROVISION_OK')) { throw 'Provisioning failed.' }
}

# ── 4. Run the server + h2spec ─────────────────────────────────────────────────
Say '=== [4/5] Running h2spec against Poseidon (TLS/ALPN h2) ==='
$run = wsl -d $Distro -u root -- bash "$h2dirWsl/run-in-wsl.sh" $elfWsl $Port 2>&1
$run | ForEach-Object { $_ }

# ── 5. Report / cleanup ────────────────────────────────────────────────────────
Say '=== [5/5] Result ==='
$summary = $run | Select-String -Pattern 'tests,.*passed'
if ($summary) { Say ("    " + $summary.ToString().Trim()) Green } else { Say '    (no summary — see output above; server may have crashed)' Yellow }

if ($Cleanup) {
  Say "    cleanup: unregistering '$Distro'"
  wsl --unregister $Distro | Out-Null
}
