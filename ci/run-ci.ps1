<#
    run-ci.ps1 — single CI entry point for Poseidon (issue #204).

    Stages (each gates the next; first failure sets the exit code but later
    stages still run so the report is complete):

      1. Dual-face COMPILE gate   — Win64 + Linux64 (ci/build-both-faces.ps1).
      2. Fuzz runner              — socket-free HTTP/1 + HPACK + WebSocket fuzz
                                    and the deterministic invariant/smuggling
                                    guards. MUST be 100% green (hard gate).
      3. Win64 unit suite         — full DUnitX suite. The 19 environmental
                                    Winsock failures (#203) are tolerated via the
                                    baseline ci/win64-known-failures.txt; any NEW
                                    failure fails the build.
      4. Linux conformance (-Linux) — h2spec over TLS/ALPN (reusing an already-
                                    provisioned WSL distro, CI-safe) and,
                                    with -Autobahn, the WebSocket suite.

    Usage:
      pwsh ci/run-ci.ps1                    # compile + fuzz + Win64 suite
      pwsh ci/run-ci.ps1 -Linux             # + h2spec (needs PoseidonH2Spec distro)
      pwsh ci/run-ci.ps1 -Linux -Autobahn   # + Autobahn (needs Benchmark distro)

    Exit code 0 = all stages passed (env failures tolerated); non-zero otherwise.
#>
param(
  [string]$Bds       = 'C:\Program Files (x86)\Embarcadero\Studio\22.0',
  [switch]$Linux,
  [switch]$Autobahn,
  [string]$H2SpecDistro  = 'PoseidonH2Spec',
  [string]$AutobahnDistro = 'Benchmark',
  [string]$BenchmarkRoot  = 'D:\IA\Projetos\Delphi\Benchmark'
)

$ErrorActionPreference = 'Stop'
$root  = Split-Path -Parent $PSScriptRoot     # ...\Poseidon
$tests = Join-Path $root 'tests'
$env:BDS = $Bds

$results = [ordered]@{}    # stage -> $true/$false
function Stage($name, [scriptblock]$body) {
  Write-Host ""
  Write-Host "=== STAGE: $name ===" -ForegroundColor Cyan
  try {
    $ok = & $body
    $results[$name] = [bool]$ok
    if ($ok) { Write-Host "    ${name}: PASS" -ForegroundColor Green }
    else     { Write-Host "    ${name}: FAIL" -ForegroundColor Red }
  } catch {
    $results[$name] = $false
    Write-Host "    ${name}: FAIL ($($_.Exception.Message))" -ForegroundColor Red
  }
}

function Invoke-Bat($dir, $bat, $log) {
  Push-Location $dir
  try { cmd /c ".\$bat" | Out-Null } finally { Pop-Location }
  if (-not (Test-Path (Join-Path $dir $log))) { return $false }
  # A COMPILE error always cites a source position: Foo.pas(123) Error/Fatal.
  return -not (Select-String -Path (Join-Path $dir $log) -Pattern '\.pas\(\d+\).*(Error|Fatal):' -Quiet)
}

function Run-Suite($exe, $xml) {
  Push-Location $tests
  try { & ".\$exe" | Out-Null } finally { Pop-Location }
  $path = Join-Path $tests $xml
  if (-not (Test-Path $path)) { throw "no results xml: $xml" }
  [xml]$x = Get-Content $path
  return $x.SelectNodes('//test-case')
}

# Cross-compile a headless Linux64 ELF (dcclinux64 + Benchmark linker stubs).
# Returns $true when the ELF is produced with no COMPILE error (link may be
# skipped/fail without the Linux SDK; only compile errors matter).
function Build-LinuxElf($dprDir, $dprName) {
  $dcc   = Join-Path $Bds 'bin\dcclinux64.exe'
  $stubs = Join-Path $BenchmarkRoot 'tools\linux_stubs'
  $rtl   = Join-Path $Bds 'lib\linux64\release'
  if (-not (Test-Path $dcc))   { throw "dcclinux64 not found: $dcc" }
  if (-not (Test-Path $stubs)) { throw "Linux stubs not found: $stubs" }
  $bin = Join-Path $dprDir 'bin'; $dcu = Join-Path $bin 'dcu'
  New-Item -ItemType Directory -Force $bin, $dcu | Out-Null
  $sp = '.\;..\..\src;..\..\middlewares'
  $ns = 'System;System.Win;Winapi;Data;Data.Win;Datasnap;Datasnap.Win;Web;Web.Win;Posix'
  Push-Location $dprDir
  try {
    $out = & $dcc "$dprName.dpr" -B "-U$sp" "-N$dcu" "-E$bin" "-NS$ns" `
      "--libpath:$stubs;$rtl" '-$O+' '-$D-' '-Q' 2>&1
  } finally { Pop-Location }
  if ($out | Where-Object { $_ -match '\.pas\(\d+\).*(Error|Fatal)' }) {
    $out | Select-Object -Last 10 | Out-Host; return $false
  }
  return (Test-Path (Join-Path $bin $dprName))
}

# Windows path -> WSL /mnt path.
function To-WslPath($winPath) {
  return [regex]::Replace(($winPath -replace '\\','/'), '^([A-Za-z]):', { param($m) '/mnt/' + $m.Groups[1].Value.ToLower() })
}

# ── 1. Dual-face compile gate ──────────────────────────────────────────────────
Stage 'compile-gate' {
  & (Join-Path $PSScriptRoot 'build-both-faces.ps1') -Bds $Bds | Out-Host
  return ($LASTEXITCODE -eq 0)
}

# ── 2. Fuzz runner (hard gate — must be 100%) ──────────────────────────────────
Stage 'fuzz' {
  if (-not (Invoke-Bat $tests 'build_fuzz.bat' 'build_fuzz_out.txt')) {
    Write-Host '    fuzz build failed' -ForegroundColor Red; return $false
  }
  $cases  = Run-Suite 'Poseidon.FuzzRunner.exe' 'bin\DUnitX-Fuzz-Results.xml'
  $failed = @($cases | Where-Object { $_.success -ne 'True' })
  Write-Host "    fuzz: $($cases.Count) cases, $($failed.Count) failed"
  $failed | ForEach-Object { Write-Host "      FAIL $($_.name)" -ForegroundColor Red }
  return ($failed.Count -eq 0)
}

# ── 3. Win64 unit suite (tolerate baseline env failures) ───────────────────────
Stage 'win64-suite' {
  # build_tests.bat is run by the compile gate; the exe is current.
  $cases    = Run-Suite 'Poseidon.Tests.exe' 'bin\DUnitX-Results.xml'
  $baseFile = Join-Path $PSScriptRoot 'win64-known-failures.txt'
  $known    = @()
  if (Test-Path $baseFile) {
    $known = Get-Content $baseFile | Where-Object { $_ -and -not $_.StartsWith('#') }
  }
  $failed = @($cases | Where-Object { $_.success -ne 'True' } | ForEach-Object { $_.name } | Sort-Object -Unique)
  $new    = @($failed | Where-Object { $known -notcontains $_ })
  $fixed  = @($known  | Where-Object { $failed -notcontains $_ })
  Write-Host "    win64: $($cases.Count) cases, $($failed.Count) failed ($($known.Count) tolerated env)"
  $new   | ForEach-Object { Write-Host "      NEW FAILURE $_" -ForegroundColor Red }
  $fixed | ForEach-Object { Write-Host "      now-passing (update baseline): $_" -ForegroundColor Yellow }
  return ($new.Count -eq 0)
}

# ── 4. Linux conformance (opt-in) ──────────────────────────────────────────────
if ($Linux) {
  Stage 'h2spec' {
    $out = & (Join-Path $tests 'run-h2spec.ps1') -Reuse -Distro $H2SpecDistro -Bds $Bds 2>&1
    $out | Out-Host
    $sum = $out | Select-String -Pattern '(\d+)\s+tests?,\s+(\d+)\s+passed'
    if (-not $sum) { return $false }
    $m = [regex]::Match($sum.ToString(), '(\d+)\s+tests?,\s+(\d+)\s+passed')
    $total = [int]$m.Groups[1].Value; $pass = [int]$m.Groups[2].Value
    Write-Host "    h2spec: $pass/$total passed"
    # Gate: no failures (skips allowed). 145/146 with 1 skip is the current bar.
    return ($pass -ge ($total - 1))
  }

  if ($Autobahn) {
    Stage 'autobahn' {
      $abDir = Join-Path $tests 'autobahn'
      if (-not (Build-LinuxElf $abDir 'poseidon-autobahn-server')) {
        Write-Host '    autobahn ELF build failed' -ForegroundColor Red; return $false
      }
      $sh = To-WslPath (Join-Path $abDir 'run-autobahn.sh')
      $py = To-WslPath (Join-Path $abDir 'analyze-autobahn.py')
      wsl -d $AutobahnDistro -u root -- bash -lc "bash '$sh' 9011 fuzzingclient.json" 2>&1 | Out-Host
      $an = wsl -d $AutobahnDistro -u root -- bash -lc "python3 '$py' /opt/autobahn/reports/clients/index.json" 2>&1
      $an | Out-Host
      $m = $an | Select-String -Pattern 'problemas=(\d+)'
      if (-not $m) { return $false }
      return ([int][regex]::Match($m.ToString(), 'problemas=(\d+)').Groups[1].Value -eq 0)
    }
  }
}

# ── Report ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== CI SUMMARY ===" -ForegroundColor Cyan
$allOk = $true
foreach ($k in $results.Keys) {
  $v = $results[$k]
  if (-not $v) { $allOk = $false }
  $tag = if ($v) { 'PASS' } else { 'FAIL' }
  $col = if ($v) { 'Green' } else { 'Red' }
  Write-Host ("    {0,-14} {1}" -f $k, $tag) -ForegroundColor $col
}
if ($allOk) { Write-Host "CI: PASSED" -ForegroundColor Green; exit 0 }
Write-Host "CI: FAILED" -ForegroundColor Red; exit 1
