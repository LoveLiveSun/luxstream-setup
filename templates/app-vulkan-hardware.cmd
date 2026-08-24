@echo off
REM Vulkan preko Mesinog Dozena - HARDVERSKI na pravom GPU-u. Vulkan 1.2.
REM
REM BEZ OVE VARIJABLE DOZEN NE RADI. vkCreateInstance vrati -3 bez ijedne
REM poruke - to je namjerna brana, jer driver nije konformantan.
set DZN_DEBUG=experimental

REM Zahtijeva jos:
REM   Windows Developer Mode ukljucen
REM   ICD registriran u HKLM\SOFTWARE\Khronos\Vulkan\Drivers
REM   dxil.dll pored .exe ili u System32
REM   High performance GPU za taj .exe

cd /d "%~dp0"
start "" "%~dp0APP.exe" %*