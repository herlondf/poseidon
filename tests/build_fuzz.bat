@echo off
setlocal
set BDS=C:\Program Files (x86)\Embarcadero\Studio\22.0
set DCC64="%BDS%\bin\dcc64.exe"

cd /d "%~dp0"

if not exist dcu\Fuzz md dcu\Fuzz
if not exist bin md bin

%DCC64% ^
  --no-config ^
  -B ^
  -CC ^
  "-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win" ^
  "-U%BDS%\lib\Win64\release;..\src;..\middlewares;.\mocks" ^
  "-I..\src;..\middlewares;.\mocks" ^
  -E. ^
  "-N0.\dcu\Fuzz" ^
  Poseidon.FuzzRunner.dpr > build_fuzz_out.txt 2>&1

echo Exit code: %ERRORLEVEL%
