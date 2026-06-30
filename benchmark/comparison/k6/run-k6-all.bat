@echo off
REM run-k6-all.bat — Runs k6 from WSL against Windows servers (one at a time on port 9801)
REM Execute from: benchmark\comparison\

setlocal enabledelayedexpansion

set BIN=%~dp0..\bin\win64
set K6=/home/herlon/benchmark/k6/k6-bin
set JS=/mnt/d/IA/Projetos/Delphi/Poseidon/benchmark/comparison/k6/bench-comparison.js
set USERS=200
set DURATION=2m
set PORT=9801

echo ============================================
echo   Poseidon vs Horse - k6 Win64
echo   %USERS% VUs, %DURATION%
echo ============================================

REM Get WSL host IP
for /f "tokens=*" %%i in ('wsl -d Totvs -- ip route show default ^| grep -oP "via \K[\d.]+"') do set WIN_IP=%%i
echo Host IP: %WIN_IP%

REM --- PoseidonFramework ---
echo.
echo === PoseidonFramework ===
start /b "" "%BIN%\BenchServer.PoseidonFramework.exe"
timeout /t 3 /nobreak >nul
for %%s in (ping json delay) do (
  echo   %%s ...
  wsl -d Totvs -- %K6% run --quiet -e BASE_URL=http://%WIN_IP%:%PORT% -e SCENARIO=%%s -e USERS=%USERS% -e DURATION=%DURATION% -e LABEL=PoseidonFramework %JS%
)
taskkill /f /im BenchServer.PoseidonFramework.exe >nul 2>&1
timeout /t 2 /nobreak >nul

REM --- PoseidonNative ---
echo.
echo === PoseidonNative ===
start /b "" "%BIN%\BenchServer.Poseidon.exe"
timeout /t 3 /nobreak >nul
for %%s in (ping json delay) do (
  echo   %%s ...
  wsl -d Totvs -- %K6% run --quiet -e BASE_URL=http://%WIN_IP%:%PORT% -e SCENARIO=%%s -e USERS=%USERS% -e DURATION=%DURATION% -e LABEL=PoseidonNative %JS%
)
taskkill /f /im BenchServer.Poseidon.exe >nul 2>&1
timeout /t 2 /nobreak >nul

REM --- Horse3.2+Indy ---
echo.
echo === Horse3.2+Indy ===
start /b "" "%BIN%\BenchServer.HorseIndy320.exe"
timeout /t 3 /nobreak >nul
for %%s in (ping json delay) do (
  echo   %%s ...
  wsl -d Totvs -- %K6% run --quiet -e BASE_URL=http://%WIN_IP%:9802 -e SCENARIO=%%s -e USERS=%USERS% -e DURATION=%DURATION% -e LABEL=Horse3.2+Indy %JS%
)
taskkill /f /im BenchServer.HorseIndy320.exe >nul 2>&1

echo.
echo Done.
