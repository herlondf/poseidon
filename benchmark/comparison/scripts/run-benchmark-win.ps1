# run-benchmark-win.ps1 — Runs the benchmark suite on Windows.
# Execute from: benchmark/comparison/ directory
# Usage: powershell -ExecutionPolicy Bypass -File scripts\run-benchmark-win.ps1

$ErrorActionPreference = "Stop"

$BaseDir    = Split-Path -Parent $PSScriptRoot
$BinDir     = Join-Path $BaseDir "bin\win64"
$ResultsDir = Join-Path $BaseDir "results\win64"
$Payload    = Join-Path $BaseDir "payload5mb.bin"

# --- Detect bombardier ---
$Bombardier = $null
if (Get-Command bombardier -ErrorAction SilentlyContinue) {
    $Bombardier = "bombardier"
} elseif (Test-Path (Join-Path $BaseDir "bombardier.exe")) {
    $Bombardier = Join-Path $BaseDir "bombardier.exe"
} elseif (Test-Path "D:\IA\Projetos\WSL-Manager\benchmark\bombardier.exe") {
    $Bombardier = "D:\IA\Projetos\WSL-Manager\benchmark\bombardier.exe"
} else {
    Write-Error "bombardier.exe not found"
    exit 1
}

# --- Generate payload ---
if (-not (Test-Path $Payload)) {
    Write-Host ">>> Generating 5MB payload..."
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $buf = New-Object byte[] (5 * 1024 * 1024)
    $rng.GetBytes($buf)
    [System.IO.File]::WriteAllBytes($Payload, $buf)
}

# --- Server definitions ---
$Servers = @(
    @{ Name = "Poseidon";              Port = 9801; Binary = "BenchServer.Poseidon.exe" },
    @{ Name = "Horse3.2+Indy";         Port = 9802; Binary = "BenchServer.HorseIndy320.exe" },
    @{ Name = "Horse3.2+Poseidon";     Port = 9803; Binary = "BenchServer.HorsePoseidon320.exe" },
    @{ Name = "HorseLatest+Indy";      Port = 9804; Binary = "BenchServer.HorseIndyLatest.exe" },
    @{ Name = "HorseLatest+IOCP";      Port = 9805; Binary = "BenchServer.HorseIOCP.exe" },
    @{ Name = "HorseLatest+HttpSys";   Port = 9806; Binary = "BenchServer.HorseHttpSys.exe" }
)

$Connections     = 100
$Requests        = 20000
$UploadRequests  = 200
$WarmupRequests  = 500

New-Item -ItemType Directory -Path $ResultsDir -Force | Out-Null

function Wait-ForPort($port, $timeoutSec = 10) {
    $end = (Get-Date).AddSeconds($timeoutSec)
    while ((Get-Date) -lt $end) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect("127.0.0.1", $port)
            $tcp.Close()
            return $true
        } catch {
            Start-Sleep -Milliseconds 500
        }
    }
    return $false
}

function Run-Scenario($name, $port, $scenario) {
    $outFile = Join-Path $ResultsDir "${name}-${scenario}.json"
    Write-Host -NoNewline "    $scenario ... "

    $args = @("-c", $Connections)
    switch ($scenario) {
        "ping"   { $args += @("-n", $Requests, "http://127.0.0.1:${port}/ping") }
        "json"   { $args += @("-n", $Requests, "http://127.0.0.1:${port}/json") }
        "upload" { $args += @("-n", $UploadRequests, "-m", "POST", "-f", $Payload, "http://127.0.0.1:${port}/upload") }
        "delay"  { $args += @("-n", $Requests, "http://127.0.0.1:${port}/delay") }
    }
    $args += @("-o", "j")

    $rawOutput = & $Bombardier @args 2>$null | Out-String
    # bombardier outputs progress lines then JSON on the last line
    $jsonLine = ($rawOutput -split "`n" | Where-Object { $_ -match '^\s*\{' }) -join ""
    if ($jsonLine) {
        $jsonLine | Out-File -FilePath $outFile -Encoding utf8 -NoNewline
        try {
            $j = $jsonLine | ConvertFrom-Json
            $rps = [math]::Round($j.result.rps.mean, 2)
            Write-Host "$rps RPS" -ForegroundColor Green
        } catch {
            Write-Host "N/A (parse error)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "N/A (no output)" -ForegroundColor Yellow
    }
}

# --- Main ---
Write-Host "============================================"
Write-Host "  Poseidon Benchmark Comparison"
Write-Host "  Platform: Win64"
Write-Host "  Connections: $Connections"
Write-Host "  Requests: $Requests (upload: $UploadRequests)"
Write-Host "============================================"
Write-Host ""

foreach ($srv in $Servers) {
    $binaryPath = Join-Path $BinDir $srv.Binary
    if (-not (Test-Path $binaryPath)) {
        Write-Host ">>> SKIP $($srv.Name) - binary not found: $binaryPath" -ForegroundColor Yellow
        continue
    }

    Write-Host ">>> $($srv.Name) (port $($srv.Port))" -ForegroundColor Cyan

    # Start server in background (servers run until killed, no stdin needed)
    $proc = Start-Process -FilePath $binaryPath -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2

    if (-not (Wait-ForPort $srv.Port)) {
        Write-Host "    FAILED to start" -ForegroundColor Red
        Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
        continue
    }

    # Warmup
    Write-Host -NoNewline "    warmup ... "
    & $Bombardier -c 10 -n $WarmupRequests "http://127.0.0.1:$($srv.Port)/ping" -p r --print result 2>$null | Out-Null
    Write-Host "done"

    # Scenarios
    Run-Scenario $srv.Name $srv.Port "ping"
    Run-Scenario $srv.Name $srv.Port "json"
    Run-Scenario $srv.Name $srv.Port "upload"
    Run-Scenario $srv.Name $srv.Port "delay"

    # Stop
    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Write-Host ""
}

# --- Summary ---
Write-Host "=== SUMMARY ===" -ForegroundColor Cyan
Write-Host ("{0,-20} {1,12} {2,12} {3,12} {4,12}" -f "Provider", "Ping RPS", "JSON RPS", "Upload RPS", "Delay RPS")

foreach ($srv in $Servers) {
    $vals = @()
    foreach ($sc in @("ping", "json", "upload", "delay")) {
        $f = Join-Path $ResultsDir "$($srv.Name)-${sc}.json"
        if (Test-Path $f) {
            try {
                $raw = Get-Content $f -Raw
                $j = $raw | ConvertFrom-Json
                $vals += [math]::Round($j.result.rps.mean, 2).ToString()
            } catch { $vals += "N/A" }
        } else { $vals += "N/A" }
    }
    Write-Host ("{0,-20} {1,12} {2,12} {3,12} {4,12}" -f $srv.Name, $vals[0], $vals[1], $vals[2], $vals[3])
}

Write-Host "`nResults in: $ResultsDir"
