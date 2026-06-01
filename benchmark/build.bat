@echo off
setlocal
set BDS=C:\Program Files (x86)\Embarcadero\Studio\22.0
set DCC64="%BDS%\bin\dcc64.exe"
set RTLLIB="%BDS%\lib\Win64\release"

cd /d "%~dp0"

if not exist dcu\Release md dcu\Release
if not exist bin md bin

%DCC64% ^
  --no-config ^
  -B ^
  -CC ^
  -DRELEASE ^
  "-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win" ^
  "-U%BDS%\lib\Win64\release;.\src;..\src" ^
  "-I.\src;..\src" ^
  -E.\bin ^
  "-N0.\dcu\Release" ^
  Poseidon.Benchmark.dpr

if %ERRORLEVEL% equ 0 (
  echo.
  echo Compilacao concluida: bin\Poseidon.Benchmark.exe
) else (
  echo.
  echo ERRO na compilacao. Codigo: %ERRORLEVEL%
  exit /b %ERRORLEVEL%
)

%DCC64% ^
  --no-config ^
  -B ^
  -CC ^
  -DRELEASE ^
  "-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win" ^
  "-U%BDS%\lib\Win64\release;.\src;..\src" ^
  "-I.\src;..\src" ^
  -E.\bin ^
  "-N0.\dcu\Release" ^
  Poseidon.Benchmark.Workers.dpr

if %ERRORLEVEL% equ 0 (
  echo.
  echo Compilacao concluida: bin\Poseidon.Benchmark.Workers.exe
) else (
  echo.
  echo ERRO na compilacao. Codigo: %ERRORLEVEL%
)
endlocal
