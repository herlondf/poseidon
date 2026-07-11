@echo off
rem Linux64 compile check (issue #204). Compiles the epoll / io_uring backends
rem with dcclinux64. Without the Linux SDK the LINK step fails on libc symbols
rem (expected); a clean COMPILE is what the gate checks. Log: ci\linux_check.txt
setlocal
if "%BDS%"=="" set BDS=C:\Program Files (x86)\Embarcadero\Studio\22.0
set DCCLINUX="%BDS%\bin\dcclinux64.exe"

cd /d "%~dp0"

if not exist dculinux md dculinux

%DCCLINUX% ^
  --no-config ^
  -B ^
  "-NSSystem;Xml;Data;Datasnap;Web;Soap;Posix" ^
  "-U%BDS%\lib\Linux64\release;..\src;..\middlewares" ^
  "-I..\src;..\middlewares" ^
  -E. ^
  "-N0.\dculinux" ^
  linux-compile-check.dpr > linux_check.txt 2>&1

echo Exit code: %ERRORLEVEL%
endlocal
