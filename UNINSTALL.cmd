@echo off
rem ===================================================================
rem  Luxstream - uninstall, one double-click
rem
rem  Short-name twin of Luxstream-ODINSTALIRAJ.cmd, the same way the
rem  installer has INSTALL.cmd next to Luxstream-INSTALIRAJ.cmd. Both
rem  uninstall names do exactly the same thing - this one only forwards.
rem
rem  All the work is in UNINSTALL.ps1, because double-clicking a .ps1
rem  opens an editor instead of running it.
rem
rem  Arguments are forwarded, so this works too:
rem      UNINSTALL.cmd -Samoprovjera
rem ===================================================================

if not exist "%~dp0Luxstream-ODINSTALIRAJ.cmd" (
  echo.
  echo   ERROR: Luxstream-ODINSTALIRAJ.cmd is missing next to this file.
  echo   This file must sit in the package folder: C:\Program Files\Luxstream
  echo.
  pause
  exit /b 1
)

call "%~dp0Luxstream-ODINSTALIRAJ.cmd" %*
