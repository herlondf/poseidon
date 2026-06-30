@echo off
REM build.bat — Compile all benchmark servers (Win64)
REM Run from: benchmark\comparison\servers\

setlocal enabledelayedexpansion

set DCC=C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcc64.exe
set LIB=C:\Program Files (x86)\Embarcadero\Studio\22.0\lib\win64\release
set SRC=..\..\..\src
set PROV=..\..\..\providers\horse
set H320=..\vendor\horse-3.2.0\src
set HLAT=..\vendor\horse-latest\src
set HANDLERS=..\handlers
set OUTDIR=..\bin\win64
set DCUDIR=..\dcu
set NS=-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win

if not exist "%OUTDIR%" mkdir "%OUTDIR%"
if not exist "%DCUDIR%" mkdir "%DCUDIR%"

set ERRORS=0

REM === 1. Poseidon Native ===
echo.
echo === 1. Poseidon Native ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.Poseidon.dpr -U"%LIB%;%SRC%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -Q
if errorlevel 1 (echo   FAILED & set /a ERRORS+=1) else (echo   OK)

REM === 2. Horse 3.2.0 + Indy ===
echo.
echo === 2. Horse 3.2.0 + Indy ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.HorseIndy320.dpr -U"%LIB%;%SRC%;%PROV%;%H320%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -Q
if errorlevel 1 (echo   FAILED & set /a ERRORS+=1) else (echo   OK)

REM === 3. Horse 3.2.0 + Poseidon ===
echo.
echo === 3. Horse 3.2.0 + Poseidon ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.HorsePoseidon320.dpr -U"%LIB%;%SRC%;%PROV%;%H320%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -DHORSE_ASYNCIO -Q
if errorlevel 1 (echo   FAILED & set /a ERRORS+=1) else (echo   OK)

REM === 4. Horse Latest + Indy ===
echo.
echo === 4. Horse Latest + Indy ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.HorseIndyLatest.dpr -U"%LIB%;%SRC%;%PROV%;%HLAT%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -Q
if errorlevel 1 (echo   FAILED & set /a ERRORS+=1) else (echo   OK)

REM === 5. Horse Latest + IOCP ===
echo.
echo === 5. Horse Latest + IOCP ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.HorseIOCP.dpr -U"%LIB%;%SRC%;%PROV%;%HLAT%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -DHORSE_PROVIDER_IOCP -Q
if errorlevel 1 (echo   FAILED - may need Delphi 12.5+ & set /a ERRORS+=1) else (echo   OK)

REM === 6. Horse Latest + HttpSys ===
echo.
echo === 6. Horse Latest + HttpSys ===
del /q "%DCUDIR%\*" 2>nul
"%DCC%" BenchServer.HorseHttpSys.dpr -U"%LIB%;%SRC%;%PROV%;%HLAT%;%HANDLERS%" -I"%LIB%" -N"%DCUDIR%" -E"%OUTDIR%" %NS% -DHORSE_PROVIDER_HTTPSYS -Q
if errorlevel 1 (echo   FAILED - may need Delphi 12.5+ & set /a ERRORS+=1) else (echo   OK)

echo.
echo === Build Summary ===
echo Errors: %ERRORS%
echo.
dir /b "%OUTDIR%\BenchServer.*.exe" 2>nul
if %ERRORS% gtr 0 (echo Some builds failed - check output above) else (echo All builds succeeded)
