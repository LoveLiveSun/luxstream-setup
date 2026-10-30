@echo off
setlocal enabledelayedexpansion
rem ===================================================================
rem  Luxstream - instalacija u jednom kliku
rem
rem  Stavi ovu datoteku na \\server\share, uz mapu sunshine-gpup-setup.
rem  Na novom VM-u: dvoklik. Nista se ne raspakirava rucno.
rem
rem  Sto radi:
rem    1. trazi administratorske ovlasti
rem    2. kopira paket s mreze na C:\Luxstream-setup
rem    3. pokrece INSTALL.ps1 odande
rem
rem  ZASTO se kopira lokalno
rem    Instalacija traje, restarta drivere i gubi mrezu iz vida. Uz to `cd`
rem    ne podnosi UNC putanje. Lokalna kopija oboje rjesava.
rem ===================================================================

title Luxstream - installer

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$a='%*'; if ($a.Trim()) { Start-Process -FilePath '%~f0' -ArgumentList $a -Verb RunAs } else { Start-Process -FilePath '%~f0' -Verb RunAs }"
  exit /b
)

set "IZVOR=%~dp0sunshine-gpup-setup"
set "CILJ=C:\Luxstream-setup"

if not exist "%IZVOR%\INSTALL.ps1" (
  echo.
  echo   ERROR: package not found at "%IZVOR%"
  echo   This file must sit NEXT TO the sunshine-gpup-setup folder.
  echo.
  pause
  exit /b 1
)

echo.
echo   Copying package
echo     from: %IZVOR%
echo     to  : %CILJ%
echo.
robocopy "%IZVOR%" "%CILJ%" /MIR /R:2 /W:5 /NFL /NDL /NJH /NJS /NP
if errorlevel 8 (
  echo.
  echo   ERROR: copy failed ^(robocopy %errorlevel%^).
  echo   Check network share availability and free disk space.
  echo.
  pause
  exit /b 1
)

echo   Package copied. Starting the installer.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%CILJ%\INSTALL.ps1" %*

echo.
echo   Install finished. The package remains in %CILJ%
echo   You can run it again from there, without the network.
echo.
echo   To remove everything again later:
echo     - Start Menu  ^>  Uninstall Luxstream
echo     - or run    %CILJ%\Luxstream-ODINSTALIRAJ.cmd
echo   Add -Samoprovjera to just see what it would remove.
echo.
pause
