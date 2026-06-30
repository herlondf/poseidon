# build-all.ps1 — Compiles all benchmark servers for Win64 (and optionally Linux64).
# Run from: D:\IA\Projetos\Delphi\Poseidon\benchmark\comparison\
# Usage: powershell -ExecutionPolicy Bypass -File scripts\build-all.ps1

param(
    [switch]$Linux,
    [switch]$SkipClone
)

$ErrorActionPreference = "Stop"
$Root     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)  # Poseidon root
$CompRoot = Join-Path $Root "benchmark\comparison"
$Servers  = Join-Path $CompRoot "servers"
$Handlers = Join-Path $CompRoot "handlers"
$BinWin   = Join-Path $CompRoot "bin\win64"
$BinLinux = Join-Path $CompRoot "bin\linux64"
$DcuDir   = Join-Path $CompRoot "dcu"
$Vendor   = Join-Path $CompRoot "vendor"
$HorseSrc = Join-Path $Vendor "horse\src"

$DCC64      = "C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcc64.exe"
$DCCLINUX64 = "C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcclinux64.exe"
$LIB_WIN64  = "C:\Program Files (x86)\Embarcadero\Studio\22.0\lib\win64\release"
$LIB_LINUX  = "C:\Program Files (x86)\Embarcadero\Studio\22.0\lib\linux64\release"

$PoseidonSrc  = Join-Path $Root "src"
$PoseidonProv = Join-Path $Root "providers\horse"

# --- Clone Horse if needed ---
if (-not $SkipClone -and -not (Test-Path (Join-Path $Vendor "horse"))) {
    Write-Host ">>> Cloning Horse framework..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $Vendor -Force | Out-Null
    git clone --depth 1 https://github.com/HashLoad/horse.git (Join-Path $Vendor "horse")
}

# --- Ensure output dirs ---
New-Item -ItemType Directory -Path $BinWin -Force | Out-Null
New-Item -ItemType Directory -Path $DcuDir -Force | Out-Null
Remove-Item "$DcuDir\*" -Force -ErrorAction SilentlyContinue

# --- Unit search paths ---
$UnitPath = "$LIB_WIN64;$Servers;$Handlers;$PoseidonSrc;$PoseidonProv;$HorseSrc"
$NSPrefix = "System;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win"

# --- Build function ---
function Build-Server {
    param([string]$DprFile, [string]$Compiler, [string]$LibPath, [string]$OutDir, [string]$Defines)

    $dprName = [System.IO.Path]::GetFileNameWithoutExtension($DprFile)
    $unitPath = "$LibPath;$Servers;$Handlers;$PoseidonSrc;$PoseidonProv;$HorseSrc"

    Write-Host "  Building $dprName..." -ForegroundColor Yellow -NoNewline

    $args = @(
        $DprFile,
        "-U$unitPath",
        "-I$LibPath",
        "-N$DcuDir",
        "-E$OutDir",
        "-NS$NSPrefix",
        "-Q", "-B"
    )
    if ($Defines) { $args += "-D$Defines" }

    $proc = Start-Process -FilePath $Compiler -ArgumentList $args -NoNewWindow -PassThru -Wait `
        -RedirectStandardOutput "$DcuDir\build_stdout.txt" -RedirectStandardError "$DcuDir\build_stderr.txt"

    if ($proc.ExitCode -ne 0) {
        Write-Host " FAILED" -ForegroundColor Red
        Get-Content "$DcuDir\build_stdout.txt" | Select-Object -Last 20
        Get-Content "$DcuDir\build_stderr.txt" | Select-Object -Last 10
        throw "Compilation failed for $dprName"
    }
    Write-Host " OK" -ForegroundColor Green
}

# --- Win64 builds ---
Write-Host "`n=== Building Win64 ===" -ForegroundColor Cyan

Build-Server (Join-Path $Servers "BenchServer.Poseidon.dpr") $DCC64 $LIB_WIN64 $BinWin ""
Build-Server (Join-Path $Servers "BenchServer.HorseIndy.dpr") $DCC64 $LIB_WIN64 $BinWin ""
Build-Server (Join-Path $Servers "BenchServer.HorsePoseidon.dpr") $DCC64 $LIB_WIN64 $BinWin "HORSE_ASYNCIO"

Write-Host "`n=== Win64 build complete ===" -ForegroundColor Green
Write-Host "Binaries in: $BinWin"

# --- Linux64 builds (optional) ---
if ($Linux) {
    if (-not (Test-Path $DCCLINUX64)) {
        Write-Host "`nSkipping Linux64 — dcclinux64.exe not found" -ForegroundColor Yellow
        return
    }

    New-Item -ItemType Directory -Path $BinLinux -Force | Out-Null
    Remove-Item "$DcuDir\*" -Force -ErrorAction SilentlyContinue

    Write-Host "`n=== Building Linux64 ===" -ForegroundColor Cyan

    Build-Server (Join-Path $Servers "BenchServer.Poseidon.dpr") $DCCLINUX64 $LIB_LINUX $BinLinux ""
    # Note: Horse+Indy depends on Indy which may not cross-compile cleanly.
    # Horse+Poseidon should work since Poseidon supports epoll/io_uring.
    Build-Server (Join-Path $Servers "BenchServer.HorsePoseidon.dpr") $DCCLINUX64 $LIB_LINUX $BinLinux "HORSE_ASYNCIO"

    Write-Host "`n=== Linux64 build complete ===" -ForegroundColor Green
    Write-Host "Binaries in: $BinLinux"
}

Write-Host "`nDone." -ForegroundColor Cyan
