@echo off
setlocal
rem ===================================================================
rem  Luxstream - pokretac instalacije
rem
rem  Dvoklik je dovoljan. Ako nije pokrenut kao administrator, sam se
rem  ponovno pokrece uz UAC odzivnik.
rem
rem  Sve ostalo radi INSTALL.ps1 - ovo je samo omotac za elevaciju,
rem  jer .ps1 na dvoklik otvara editor, ne pokrece se.
rem ===================================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting administrator rights...
  rem argumenti se moraju proslijediti, inace se -PreskociUac i slicno gube
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "$a='%*'; if ($a.Trim()) { Start-Process -FilePath '%~f0' -ArgumentList $a -Verb RunAs } else { Start-Process -FilePath '%~f0' -Verb RunAs }"  exit /b
)

rem cd /d ne podnosi UNC putanje - javi "CMD does not support UNC paths as
rem current directories" i ostane u C:\Windows. pushd UNC-u mapira privremeno
rem slovo diska, pa radi i s mreznog mjesta. Vidjeno 23.8.2026. pri instalaciji
rem s \\ds\a\VM\...
pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0INSTALL.ps1" %*
popdecho.
pause
