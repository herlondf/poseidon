@echo off
setlocal
set BDS=C:\Program Files (x86)\Embarcadero\Studio\22.0
set DCC64="%BDS%\bin\dcc64.exe"

cd /d "D:\IA\Projetos\Delphi\Poseidon\tests"

if not exist dcu\Debug md dcu\Debug

%DCC64% ^
  --no-config ^
  -B ^
  -CC ^
  "-NSSystem;Xml;Data;Datasnap;Web;Soap;Winapi;System.Win;Data.Win;Datasnap.Win;Web.Win;Soap.Win;Xml.Win" ^
  "-U%BDS%\lib\Win64\release;..\src;.\mocks" ^
  "-I..\src;.\mocks" ^
  -E. ^
  "-N0.\dcu\Debug" ^
  Poseidon.Tests.dpr > build_tests_out.txt 2>&1

echo Exit code: %ERRORLEVEL%
