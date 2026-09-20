# Poseidon "Performance vs. the Field" benchmark - full reproduction (Windows).
#
# Mirrors run-all.sh exactly (same build/run/measure/teardown sequence, same
# defaults) for a Docker Desktop host with no WSL2/bash required.
#
# Usage:
#   .\run-all.ps1                       # all 7 contenders, 300s measurement each
#   .\run-all.ps1 poseidon-v2 actix       # only these two
#   .\run-all.ps1 -Duration 30           # short smoke-test run
param(
  [string[]]$Frameworks = @(),
  [string]$Cpus = "2.0",
  [string]$Memory = "1g",
  [int]$Duration = 300,
  [int]$Threads = 4,
  [int]$Conns = 200,
  [int]$WarmupS = 5,
  [int]$CooldownS = 5,
  # CPU isolation (see run-all.sh for the full rationale): pin server and
  # load generator to disjoint cores so neither's scheduler noise touches the
  # other. $null (default) auto-picks a split on a >=4-core host; pass "" to
  # force the old unpinned behavior.
  [string]$CpusetServer = $null,
  [string]$CpusetLoadgen = $null
)

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Resolve-Path (Join-Path $Here '..')
$Repo = Resolve-Path (Join-Path $Root '..')
$Results = Join-Path $Root 'results'
$Raw = Join-Path $Results 'raw'
$Net = 'bench-net'

if ($null -eq $CpusetServer -and $null -eq $CpusetLoadgen -and [Environment]::ProcessorCount -ge 4) {
  $CpusetServer = "0,1"
  $CpusetLoadgen = "2,3"
}
if ($null -eq $CpusetServer) { $CpusetServer = "" }
if ($null -eq $CpusetLoadgen) { $CpusetLoadgen = "" }

$AllFrameworks = @('actix','poseidon-v2','gofiber','mormot2','nginx','horse-epoll','kestrel','express','fastapi','django','rails','laravel','spring-boot')
if ($Frameworks.Count -eq 0) { $Frameworks = $AllFrameworks }

New-Item -ItemType Directory -Force -Path $Raw | Out-Null

function Log($msg) { Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" }

# ---- one-time setup ---------------------------------------------------------

Log "Building shared FPC trunk base image (slow the first time, cached after)..."
docker build -t poseidon-bench/fpc-trunk -f "$Root\docker\fpc-trunk\Dockerfile" "$Root\docker\fpc-trunk\"
if ($LASTEXITCODE -ne 0) { Write-Error "FPC trunk base image build FAILED"; exit 1 }

Log "Building load generator image (wrk)..."
docker build -t poseidon-bench/loadgen "$Root\loadgen\"
if ($LASTEXITCODE -ne 0) { Write-Error "loadgen image build FAILED"; exit 1 }

$netExists = docker network inspect $Net 2>$null
if (-not $netExists) {
  Log "Creating dedicated bridge network $Net"
  docker network create $Net | Out-Null
}

# ---- per-framework build ----------------------------------------------------

function Build-One([string]$Name) {
  $dir = Join-Path $Root "frameworks\$Name"
  $dockerfile = Join-Path $dir 'Dockerfile'
  if (-not (Test-Path $dockerfile)) {
    Log "  SKIP $Name: no Dockerfile at $dir"
    return $false
  }
  # The 3 Pascal contenders build from Poseidon's own src/ (repo root as
  # context); the other 5 are fully self-contained in their own directory.
  $context = $dir
  if ($Name -in @('poseidon-v2','mormot2','horse-epoll')) { $context = $Repo }
  Log "Building bench-$Name (context: $context) ..."
  $buildLog = Join-Path $Raw "$Name.build.log"
  docker build -t "bench-$Name" -f $dockerfile $context *> $buildLog
  if ($LASTEXITCODE -ne 0) {
    Log "  BUILD FAILED for $Name - see $buildLog"
    Get-Content $buildLog -Tail 30
    return $false
  }
  Log "  built bench-$Name"
  return $true
}

# ---- run one framework: start, wait, measure, teardown ----------------------

function Run-One([string]$Name) {
  $container = 'bench-target'
  docker rm -f $container *> $null

  $serverCpusetArgs = @()
  if ($CpusetServer -ne "") { $serverCpusetArgs = @("--cpuset-cpus=$CpusetServer") }
  $loadgenCpusetArgs = @()
  if ($CpusetLoadgen -ne "") { $loadgenCpusetArgs = @("--cpuset-cpus=$CpusetLoadgen") }

  Log "[$Name] starting container (--cpus=$Cpus --memory=$Memory$(if ($CpusetServer -ne '') { " --cpuset-cpus=$CpusetServer" }))"
  # seccomp=unconfined: Docker's default profile blocks io_uring_setup/enter,
  # silently forcing Poseidon down to epoll - applied to every contender
  # uniformly, not just Poseidon (see run-all.sh for the confirmed repro).
  docker run -d --name $container --network $Net --cpus $Cpus --memory $Memory @serverCpusetArgs --security-opt seccomp=unconfined "bench-$Name" | Out-Null
  if ($LASTEXITCODE -ne 0) { Log "[$Name] docker run FAILED"; return }

  Log "[$Name] waiting for readiness..."
  $ready = $false
  for ($i = 0; $i -lt 30; $i++) {
    docker run --rm --network $Net --entrypoint curl poseidon-bench/loadgen -sf -o NUL "http://${container}:8080/plaintext" 2>$null
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 1
  }
  if (-not $ready) {
    Log "[$Name] NEVER BECAME READY - skipping, dumping container log"
    docker logs $container 2>&1 | Select-Object -Last 40
    docker rm -f $container *> $null
    return
  }

  Log "[$Name] warmup ${WarmupS}s..."
  docker run --rm --network $Net @loadgenCpusetArgs poseidon-bench/loadgen -t $Threads -c $Conns -d "${WarmupS}s" -s /bench.lua "http://${container}:8080" *> $null

  Log "[$Name] measuring for ${Duration}s (t=$Threads c=$Conns)...$(if ($CpusetLoadgen -ne '') { " [loadgen pinned to $CpusetLoadgen]" })"
  $log = Join-Path $Raw "$Name.log"
  docker run --rm --network $Net @loadgenCpusetArgs poseidon-bench/loadgen -t $Threads -c $Conns -d "${Duration}s" --latency -s /bench.lua "http://${container}:8080" *> $log

  Log "[$Name] tearing down"
  docker rm -f $container *> $null

  Log "[$Name] cooldown ${CooldownS}s"
  Start-Sleep -Seconds $CooldownS
}

# ---- main loop ---------------------------------------------------------------

foreach ($fw in $Frameworks) {
  Write-Host ""
  Write-Host "=================================================================="
  Write-Host " $fw"
  Write-Host "=================================================================="
  if (Build-One $fw) { Run-One $fw }
}

Log "Parsing results..."
$resultsMd = Join-Path $Results 'RESULTS.md'
& "$Here\parse-results.ps1" -Frameworks $Frameworks | Tee-Object -FilePath $resultsMd
Log "Done. Table written to $resultsMd"
