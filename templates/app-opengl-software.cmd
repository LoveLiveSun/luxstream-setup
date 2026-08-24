@echo off
REM OpenGL preko llvmpipe - SOFTVERSKI, sve na procesoru. GL 4.6, potpun.
REM Koristi kad aplikaciji treba vise od GL 4.2 i brzina nije presudna.
REM Ocekuj jednoznamenkasti broj kadrova u sekundi za 3D.

set GALLIUM_DRIVER=llvmpipe

cd /d "%~dp0"
start "" "%~dp0APP.exe" %*