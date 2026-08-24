<#
    gltest.ps1
    Stvara OpenGL kontekst i ispisuje GL_VENDOR / GL_RENDERER / GL_VERSION.

    -MesaDir  ucitaj Mesin opengl32.dll iz zadane mape umjesto sistemskog
    -Driver   vrijednost za GALLIUM_DRIVER (npr. d3d12, llvmpipe)

    Primjeri:
      .\gltest.ps1                                   # sistemski OpenGL
      .\gltest.ps1 -MesaDir C:\Mesa\x64 -Driver d3d12
#>
[CmdletBinding()]
param([string]$MesaDir, [string]$Driver)

if ($Driver)  { $env:GALLIUM_DRIVER = $Driver }
if ($MesaDir) { $env:PATH = "$MesaDir;$env:PATH" }

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class GLT {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr LoadLibraryW(string path);

  [StructLayout(LayoutKind.Sequential)]
  struct PIXELFORMATDESCRIPTOR {
    public ushort nSize, nVersion;
    public uint dwFlags;
    public byte iPixelType, cColorBits, cRedBits, cRedShift, cGreenBits, cGreenShift,
                cBlueBits, cBlueShift, cAlphaBits, cAlphaShift, cAccumBits, cAccumRedBits,
                cAccumGreenBits, cAccumBlueBits, cAccumAlphaBits, cDepthBits, cStencilBits,
                cAuxBuffers, iLayerType, bReserved;
    public uint dwLayerMask, dwVisibleMask, dwDamageMask;
  }

  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  static extern IntPtr CreateWindowExW(uint ex, string cls, string name, uint style,
    int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
  [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr hwnd);
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);

  [DllImport("gdi32.dll")] static extern int ChoosePixelFormat(IntPtr hdc, ref PIXELFORMATDESCRIPTOR pfd);
  [DllImport("gdi32.dll")] static extern bool SetPixelFormat(IntPtr hdc, int fmt, ref PIXELFORMATDESCRIPTOR pfd);

  [DllImport("opengl32.dll")] static extern IntPtr wglCreateContext(IntPtr hdc);
  [DllImport("opengl32.dll")] static extern bool   wglMakeCurrent(IntPtr hdc, IntPtr hglrc);
  [DllImport("opengl32.dll")] static extern bool   wglDeleteContext(IntPtr hglrc);
  [DllImport("opengl32.dll")] static extern IntPtr glGetString(uint name);

  public static string Run(string mesaDll) {
    var sb = new StringBuilder();
    if (!string.IsNullOrEmpty(mesaDll)) {
      IntPtr h = LoadLibraryW(mesaDll);
      sb.AppendLine(h != IntPtr.Zero
        ? "Ucitan " + mesaDll
        : "NEUSPJESNO ucitavanje " + mesaDll + " (Win32 " + Marshal.GetLastWin32Error() + ")");
      if (h == IntPtr.Zero) return sb.ToString();
    }

    // "static" klasa postoji uvijek, ne treba registrirati vlastitu
    IntPtr hwnd = CreateWindowExW(0, "static", "gltest", 0x80000000, 0, 0, 64, 64,
                                  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    if (hwnd == IntPtr.Zero) return sb.AppendLine("CreateWindow FAILED").ToString();

    IntPtr hdc = GetDC(hwnd);
    var pfd = new PIXELFORMATDESCRIPTOR();
    pfd.nSize = (ushort)Marshal.SizeOf(typeof(PIXELFORMATDESCRIPTOR));
    pfd.nVersion = 1;
    pfd.dwFlags = 0x4 | 0x20 | 0x1;   // DOUBLEBUFFER | SUPPORT_OPENGL | DRAW_TO_WINDOW
    pfd.iPixelType = 0;               // RGBA
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;

    int fmt = ChoosePixelFormat(hdc, ref pfd);
    if (fmt == 0) { sb.AppendLine("ChoosePixelFormat FAILED"); ReleaseDC(hwnd, hdc); DestroyWindow(hwnd); return sb.ToString(); }
    SetPixelFormat(hdc, fmt, ref pfd);

    IntPtr rc = wglCreateContext(hdc);
    if (rc == IntPtr.Zero) { sb.AppendLine("wglCreateContext FAILED"); ReleaseDC(hwnd, hdc); DestroyWindow(hwnd); return sb.ToString(); }
    wglMakeCurrent(hdc, rc);

    sb.AppendLine("GL_VENDOR   : " + Marshal.PtrToStringAnsi(glGetString(0x1F00)));
    sb.AppendLine("GL_RENDERER : " + Marshal.PtrToStringAnsi(glGetString(0x1F01)));
    sb.AppendLine("GL_VERSION  : " + Marshal.PtrToStringAnsi(glGetString(0x1F02)));

    wglMakeCurrent(IntPtr.Zero, IntPtr.Zero);
    wglDeleteContext(rc);
    ReleaseDC(hwnd, hdc);
    DestroyWindow(hwnd);
    return sb.ToString();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp

$dll = if ($MesaDir) { Join-Path $MesaDir 'opengl32.dll' } else { '' }
[GLT]::Run($dll)
