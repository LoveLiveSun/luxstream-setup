<#
    gl-persist-test.ps1
    Stvori OpenGL kontekst, pa ga drzi zivim i svakih par sekundi zapise
    GL_RENDERER u datoteku. Time se vidi PREZIVI li kontekst promjenu
    primarnog displaya.

      .\gl-persist-test.ps1 -Seconds 45 -Out C:\Users\Public\gl_persist.txt
#>
[CmdletBinding()]
param([int]$Seconds = 45, [string]$Out = 'C:\Users\Public\gl_persist.txt', [string]$MesaDir)

if ($MesaDir) { $env:PATH = "$MesaDir;$env:PATH" }

$src = @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public static class GLP {
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
  public static extern IntPtr LoadLibraryW(string path);

  [StructLayout(LayoutKind.Sequential)]
  struct PIXELFORMATDESCRIPTOR {
    public ushort nSize, nVersion; public uint dwFlags;
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
  [DllImport("gdi32.dll")] static extern int ChoosePixelFormat(IntPtr hdc, ref PIXELFORMATDESCRIPTOR pfd);
  [DllImport("gdi32.dll")] static extern bool SetPixelFormat(IntPtr hdc, int fmt, ref PIXELFORMATDESCRIPTOR pfd);
  [DllImport("opengl32.dll")] static extern IntPtr wglCreateContext(IntPtr hdc);
  [DllImport("opengl32.dll")] static extern bool   wglMakeCurrent(IntPtr hdc, IntPtr hglrc);
  [DllImport("opengl32.dll")] static extern IntPtr glGetString(uint name);
  [DllImport("opengl32.dll")] static extern uint   glGetError();
  [DllImport("opengl32.dll")] static extern void   glClear(uint mask);

  public static void Run(int seconds, string outFile) {
    var sw = new StreamWriter(outFile, false);
    sw.AutoFlush = true;

    IntPtr hwnd = CreateWindowExW(0, "static", "glpersist", 0x80000000, 0, 0, 64, 64,
                                  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    IntPtr hdc = GetDC(hwnd);
    var pfd = new PIXELFORMATDESCRIPTOR();
    pfd.nSize = (ushort)Marshal.SizeOf(typeof(PIXELFORMATDESCRIPTOR));
    pfd.nVersion = 1; pfd.dwFlags = 0x4 | 0x20 | 0x1; pfd.cColorBits = 32; pfd.cDepthBits = 24;

    int fmt = ChoosePixelFormat(hdc, ref pfd);
    if (fmt == 0) { sw.WriteLine("ChoosePixelFormat FAILED"); sw.Close(); return; }
    SetPixelFormat(hdc, fmt, ref pfd);

    IntPtr rc = wglCreateContext(hdc);
    if (rc == IntPtr.Zero) { sw.WriteLine("wglCreateContext FAILED"); sw.Close(); return; }
    wglMakeCurrent(hdc, rc);

    sw.WriteLine("KONTEKST STVOREN " + DateTime.Now.ToString("HH:mm:ss"));
    sw.WriteLine("  GL_RENDERER : " + Marshal.PtrToStringAnsi(glGetString(0x1F01)));
    sw.WriteLine("  GL_VERSION  : " + Marshal.PtrToStringAnsi(glGetString(0x1F02)));
    sw.WriteLine();

    DateTime end = DateTime.Now.AddSeconds(seconds);
    int i = 0;
    while (DateTime.Now < end) {
      glClear(0x00004000);              // GL_COLOR_BUFFER_BIT - stvarni GL poziv
      uint err = glGetError();
      string r = Marshal.PtrToStringAnsi(glGetString(0x1F01));
      sw.WriteLine(string.Format("{0}  t+{1,3}s  glGetError=0x{2:X}  GL_RENDERER={3}",
        DateTime.Now.ToString("HH:mm:ss"), i, err, (r == null ? "<null>" : r)));
      Thread.Sleep(3000);
      i += 3;
    }
    sw.WriteLine("KRAJ");
    sw.Close();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
Write-Host "Drzim GL kontekst $Seconds s, zapisujem u $Out"
[GLP]::Run($Seconds, $Out)
Write-Host 'Gotovo.'
