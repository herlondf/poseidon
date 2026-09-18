# Parses benchmark/results/raw/<framework>.log (wrk + bench.lua output) into
# the "Performance vs. the Field" Markdown table, ranked by throughput.
# Native PowerShell port of parse-results.sh (no bash needed on Windows).
param(
  [string[]]$Frameworks = @()
)

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $Here '..')
$Raw = Join-Path $Root 'results\raw'

$AllFrameworks = @('actix','poseidon-v2','gofiber','mormot2','nginx','horse-epoll','kestrel')
if ($Frameworks.Count -eq 0) { $Frameworks = $AllFrameworks }

$displayName = @{
  actix = 'Actix'; 'poseidon-v2' = 'Poseidon v2'; gofiber = 'Go Fiber'
  mormot2 = 'mORMot2'; nginx = 'nginx'; 'horse-epoll' = 'Horse'; kestrel = 'Kestrel'
}
$displayTech = @{
  actix = 'Rust'; 'poseidon-v2' = 'Object Pascal'; gofiber = 'Go'
  mormot2 = 'Object Pascal'; nginx = 'C'; 'horse-epoll' = 'Object Pascal'; kestrel = 'C#/.NET'
}

$rows = @()

foreach ($fw in $Frameworks) {
  $name = if ($displayName.ContainsKey($fw)) { $displayName[$fw] } else { $fw }
  $tech = if ($displayTech.ContainsKey($fw)) { $displayTech[$fw] } else { '?' }
  $logPath = Join-Path $Raw "$fw.log"

  if (-not (Test-Path $logPath) -or (Get-Item $logPath).Length -eq 0) {
    $rows += [pscustomobject]@{ ReqPs = -1; Name = $name; Tech = $tech; P50 = 'no data'; P99 = 'no data'; Max = 'no data'; Errors = 'no data' }
    continue
  }
  $content = Get-Content $logPath -Raw

  $reqpsMatch = [regex]::Match($content, 'Requests/sec:\s*([0-9.]+)')
  $p50Match = [regex]::Match($content, 'p50=(\d+)')
  $p99Match = [regex]::Match($content, 'p99=(\d+)')
  $maxMatches = [regex]::Matches($content, 'max=(\d+)')
  $errLineMatch = [regex]::Match($content, 'connect=(\d+)\s+read=(\d+)\s+write=(\d+)\s+timeout=(\d+)\s+status=(\d+)')

  if (-not $reqpsMatch.Success -or -not $p50Match.Success -or -not $p99Match.Success) {
    $rows += [pscustomobject]@{ ReqPs = -1; Name = $name; Tech = $tech; P50 = 'parse error'; P99 = 'parse error'; Max = 'parse error'; Errors = 'parse error' }
    continue
  }

  $reqps = [double]$reqpsMatch.Groups[1].Value
  $p50ms = [math]::Round([double]$p50Match.Groups[1].Value / 1000, 2)
  $p99ms = [math]::Round([double]$p99Match.Groups[1].Value / 1000, 2)
  $maxus = if ($maxMatches.Count -gt 0) { [double]$maxMatches[$maxMatches.Count - 1].Groups[1].Value } else { 0 }
  $maxms = [math]::Round($maxus / 1000, 0)
  $errors = 0
  if ($errLineMatch.Success) {
    for ($g = 1; $g -le 5; $g++) { $errors += [int]$errLineMatch.Groups[$g].Value }
  }

  $rows += [pscustomobject]@{
    ReqPs = $reqps; Name = $name; Tech = $tech
    P50 = "$p50ms ms"; P99 = "$p99ms ms"; Max = "$maxms ms"; Errors = $errors
  }
}

$sorted = $rows | Sort-Object -Property ReqPs -Descending

Write-Output "| Posição | Framework | Tecnologia | Req/s | p50 | p99 | Máx | Erros |"
Write-Output "|---:|---|---|---:|---:|---:|---:|---:|"

$rank = 1
foreach ($r in $sorted) {
  if ($r.ReqPs -eq -1) {
    Write-Output "| — | $($r.Name) | $($r.Tech) | $($r.P50) | $($r.P99) | $($r.Max) | $($r.Errors) |"
  } else {
    $reqpsFmt = [math]::Round($r.ReqPs, 0).ToString('N0')
    Write-Output "| $rank | $($r.Name) | $($r.Tech) | $reqpsFmt | $($r.P50) | $($r.P99) | $($r.Max) | $($r.Errors) |"
    $rank++
  }
}
