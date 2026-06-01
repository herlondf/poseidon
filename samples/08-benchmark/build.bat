@echo off
setlocal
set BDS=C:\Program Files (x86)\Embarcadero\Studio\22.0
set DCC64="%BDS%\bin\dcc64.exe"

cd /d "%~dp0"

if not exist dcu\Release md dcu\Release
if not exist bin\Release md bin\Release

%DCC64% ^
  --no-config ^
  -B ^
  -CC ^
  -DRELEASE ^
  "-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win" ^
  "-U%BDS%\lib\Win64\release;.;..\..\src" ^
  "-I.;..\..\src" ^
  "-E.\bin\Release" ^
  "-N0.\dcu\Release" ^
  Poseidon.Sample.Benchmark.dpr

if %ERRORLEVEL% equ 0 (
  echo.
  echo Compilacao concluida: bin\Release\Poseidon.Sample.Benchmark.exe
) else (
  echo.
  echo ERRO na compilacao. Codigo: %ERRORLEVEL%
)
endlocal
