<#
  gen-api.ps1 — generate a browsable HTML API reference from the Poseidon
  public source doc-comments using PasDoc (https://pasdoc.github.io/).

  Output: docs/api/html/index.html

  PasDoc is not bundled. If it is not on PATH, install it:
    - Download a release from https://github.com/pasdoc/pasdoc/releases
    - Unzip and either add its bin/ to PATH or pass -PasDoc <path-to-pasdoc.exe>

  Usage (from repo root or anywhere):
    pwsh docs/api/gen-api.ps1
    pwsh docs/api/gen-api.ps1 -PasDoc "C:\tools\pasdoc\bin\pasdoc.exe"

  The unit list mirrors the public surface documented in docs/API-REFERENCE.md:
  the facade, its re-exported units, and the middleware factories.
#>
[CmdletBinding()]
param(
  [string]$PasDoc = 'pasdoc',
  [string]$Title  = 'Poseidon API Reference'
)

$ErrorActionPreference = 'Stop'

# Repo root = two levels up from this script (docs/api/ -> repo).
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$OutDir   = Join-Path $PSScriptRoot 'html'
$SrcDir   = Join-Path $RepoRoot 'src'
$MwDir    = Join-Path $RepoRoot 'middlewares'

# Public surface — keep in sync with docs/API-REFERENCE.md.
$PublicUnits = @(
  'Poseidon.pas',
  'Poseidon.Native.Server.pas',
  'Poseidon.Native.Types.pas',
  'Poseidon.Native.Group.pas',
  'Poseidon.Net.WebSocket.pas',
  'Poseidon.Net.Types.pas',
  'Poseidon.Status.pas',
  'Poseidon.Problem.pas',
  'Poseidon.Exception.pas',
  'Poseidon.Validation.pas'
) | ForEach-Object { Join-Path $SrcDir $_ }

# All middleware factories.
$MwUnits = Get-ChildItem -Path $MwDir -Filter 'Poseidon.Middleware.*.pas' |
           Select-Object -ExpandProperty FullName

$Files = @($PublicUnits + $MwUnits) | Where-Object { Test-Path $_ }

# Verify PasDoc is available.
$pd = Get-Command $PasDoc -ErrorAction SilentlyContinue
if (-not $pd) {
  Write-Host "PasDoc not found ('$PasDoc')." -ForegroundColor Yellow
  Write-Host "Install from https://github.com/pasdoc/pasdoc/releases and re-run," -ForegroundColor Yellow
  Write-Host "or pass -PasDoc <path-to-pasdoc.exe>. The hand-maintained reference" -ForegroundColor Yellow
  Write-Host "at docs/API-REFERENCE.md covers the same surface in the meantime." -ForegroundColor Yellow
  exit 2
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host "Generating API reference for $($Files.Count) units -> $OutDir" -ForegroundColor Cyan

& $PasDoc `
  --format html `
  --output $OutDir `
  --title $Title `
  --auto-abstract `
  --visible-members public,published,automated `
  --define MSWINDOWS `
  @Files

if ($LASTEXITCODE -eq 0) {
  Write-Host "Done. Open $(Join-Path $OutDir 'index.html')" -ForegroundColor Green
} else {
  Write-Host "PasDoc exited with code $LASTEXITCODE" -ForegroundColor Red
  exit $LASTEXITCODE
}
