@echo off
setlocal
rem ===================================================================
rem  Luxstream - pokretac deinstalacije
rem
rem  Dvoklik je dovoljan. Ako nije pokrenut kao administrator, sam se
rem  ponovno pokrece uz UAC odzivnik.
rem
rem  Sve ostalo radi UNINSTALL.ps1 - ovo je samo omotac za elevaciju,
rem  jer .ps1 na dvoklik otvara editor, ne pokrece se.
rem
rem  Argumenti se prosljedjuju dalje, pa rade i -Samoprovjera, -Obrisi i
rem  ostalo. Primjer bez ikakvih promjena - samo popis:
rem      Luxstream-ODINSTALIRAJ.cmd -Samoprovjera
rem ===================================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  rem argumenti se moraju proslijediti, inace se -Samoprovjera i slicno gube
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$a='%*'; if ($a.Trim()) { Start-Process -FilePath '%~f0' -ArgumentList $a -Verb RunAs } else { Start-Process -FilePath '%~f0' -Verb RunAs }"
  exit /b
)

rem cd /d ne podnosi UNC putanje - javi "CMD does not support UNC paths as
rem current directories" i ostane u C:\Windows. pushd UNC-u mapira privremeno
rem slovo diska, pa radi i s mreznog mjesta.
pushd "%~dp0"

if not exist "%~dp0UNINSTALL.ps1" (
  echo.
  echo   ERROR: UNINSTALL.ps1 is missing next to this file.
  echo.
  pause
  exit /b 1
)

title Luxstream - uninstall
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0UNINSTALL.ps1" %*

popd
echo.
pause
