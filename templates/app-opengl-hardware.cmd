@echo off
REM OpenGL preko D3D12 - HARDVERSKI na pravom GPU-u. GL 4.2.
REM Zahtijeva: opengl32.dll, libgallium_wgl.dll, dxil.dll pored .exe
REM            + High performance GPU za taj .exe

set GALLIUM_DRIVER=d3d12

REM Ako aplikacija trazi visi GL nego 4.2, probaj podici PRIJAVLJENU verziju.
REM Ne daje nove sposobnosti - ako joj stvarno nesto nedostaje, past ce dalje.
REM set MESA_GL_VERSION_OVERRIDE=4.3COMPAT
REM set MESA_GLSL_VERSION_OVERRIDE=430
REM set MESA_EXTENSION_OVERRIDE=+GL_ARB_texture_view

cd /d "%~dp0"
start "" "%~dp0APP.exe" %*