<#
    sync-vendor.ps1 — keep the vendored Poseidon copy used by the Benchmark repo
    in sync with this repo, and detect drift (issue #206).

    The Benchmark repo bundles a COPY of Poseidon under vendor/poseidon-v2 (src +
    middlewares) so its perf harness builds against a fixed snapshot. That copy
    silently drifts from the source, which makes benchmarks measure stale code.

    Modes:
      -Check   (default) — report drift (files that differ / are missing / extra)
                           and exit 1 if any drift is found. Safe, read-only.
      -Sync              — overwrite the vendored copy from this repo (mirrors
                           src/ and middlewares/, deletes extra files).

    Usage:
      pwsh ci/sync-vendor.ps1                                   # check drift
      pwsh ci/sync-vendor.ps1 -Sync                             # update vendor
      pwsh ci/sync-vendor.ps1 -Vendor D:\path\to\poseidon-v2    # custom target
#>
param(
  [string]$Vendor = 'D:\IA\Projetos\Delphi\Benchmark\vendor\poseidon-v2',
  [switch]$Sync
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot     # ...\Poseidon
$dirs = @('src', 'middlewares')

if (-not (Test-Path $Vendor)) {
  Write-Host "Vendor target not found: $Vendor" -ForegroundColor Red
  Write-Host "(pass -Vendor <path> if the Benchmark repo lives elsewhere)" -ForegroundColor Yellow
  exit 2
}

# Compare only the source files that actually get vendored (.pas / .inc / .dpr).
function Get-SrcFiles($base) {
  if (-not (Test-Path $base)) { return @{} }
  $map = @{}
  Get-ChildItem -Path $base -Recurse -File -Include *.pas,*.inc,*.dpr |
    ForEach-Object { $map[$_.FullName.Substring($base.Length).TrimStart('\')] = $_ }
  return $map
}

$drift = [System.Collections.Generic.List[string]]::new()

foreach ($d in $dirs) {
  $srcBase = Join-Path $root $d
  $dstBase = Join-Path $Vendor $d
  $srcMap  = Get-SrcFiles $srcBase
  $dstMap  = Get-SrcFiles $dstBase

  foreach ($rel in $srcMap.Keys) {
    $s = $srcMap[$rel]
    if (-not $dstMap.ContainsKey($rel)) { $drift.Add("MISSING  $d\$rel"); continue }
    $h1 = (Get-FileHash $s.FullName -Algorithm SHA256).Hash
    $h2 = (Get-FileHash $dstMap[$rel].FullName -Algorithm SHA256).Hash
    if ($h1 -ne $h2) { $drift.Add("DIFF     $d\$rel") }
  }
  foreach ($rel in $dstMap.Keys) {
    if (-not $srcMap.ContainsKey($rel)) { $drift.Add("EXTRA    $d\$rel") }
  }
}

if ($Sync) {
  Write-Host "Syncing vendor copy at $Vendor ..." -ForegroundColor Cyan
  foreach ($d in $dirs) {
    $srcBase = Join-Path $root $d
    $dstBase = Join-Path $Vendor $d
    if (-not (Test-Path $srcBase)) { continue }
    # robocopy /MIR mirrors and removes extras. Exit codes 0-7 are success.
    robocopy $srcBase $dstBase *.pas *.inc *.dpr /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed for $d (code $LASTEXITCODE)" }
    $global:LASTEXITCODE = 0
  }
  Write-Host ("    synced ({0} file(s) were drifted before sync)" -f $drift.Count) -ForegroundColor Green
  exit 0
}

# Check mode
if ($drift.Count -eq 0) {
  Write-Host "vendor/poseidon-v2 is IN SYNC with the source." -ForegroundColor Green
  exit 0
}
Write-Host "DRIFT detected ($($drift.Count) file(s)) — run with -Sync to update:" -ForegroundColor Red
$drift | Sort-Object | ForEach-Object { Write-Host "    $_" }
exit 1
