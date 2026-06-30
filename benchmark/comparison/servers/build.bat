@echo off
REM build.bat — Compile all benchmark servers (Win64)
REM Run from: benchmark\comparison\servers\

setlocal

set DCC=C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcc64.exe
set LIB=C:\Program Files (x86)\Embarcadero\Studio\22.0\lib\win64\release
set SRC=..\..\..\src
set PROV=..\..\..\providers\horse
set HORSE=..\vendor\horse\src
set HANDLERS=..\handlers
set OUTDIR=..\bin\win64
set DCUDIR=..\dcu
set NS=-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win

if not exist "%OUTDIR%" mkdir "%OUTDIR%"
if not exist "%DCUDIR%" mkdir "%DCUDIR%"

echo === Poseidon Native ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.Poseidon.dpr -U"%LIB%;%SRC%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -Q
if errorlevel 1 (echo FAILED & exit /b 1)

echo === Horse + Indy ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.HorseIndy.dpr -U"%LIB%;%SRC%;%PROV%;%HORSE%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -Q
if errorlevel 1 (echo FAILED & exit /b 1)

echo === Horse + Poseidon ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.HorsePoseidon.dpr -U"%LIB%;%SRC%;%PROV%;%HORSE%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -DHORSE_ASYNCIO -Q
if errorlevel 1 (echo FAILED & exit /b 1)

echo.
echo === All servers compiled ===
dir /b "%OUTDIR%\*.exe"
