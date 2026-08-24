<#
    glext.ps1
    Ispisuje GL verziju i provjerava kljucne ekstenzije. Korisno kad se
    MESA_GL_VERSION_OVERRIDE koristi da se vidi sto driver STVARNO ima,
    a ne samo sto prijavljuje.

      .\glext.ps1 -MesaDir C:\Mesa\x64 -Driver d3d12
#>
[CmdletBinding()]
param([string]$MesaDir, [string]$Driver, [switch]$All,
      [int]$X = 0, [int]$Y = 0,          # gdje stvoriti prozor
      [string]$OnDisplay)                # ili: ime displaya, npr. \\.\DISPLAY8

if ($OnDisplay) {
  Add-Type -AssemblyName System.Windows.Forms
  $s = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $OnDisplay }
  if (-not $s) { throw "Display $OnDisplay ne postoji" }
  $X = $s.Bounds.X + 8; $Y = $s.Bounds.Y + 8
  Write-Host "Prozor na $OnDisplay -> ($X,$Y)"
}

if ($Driver)  { $env:GALLIUM_DRIVER = $Driver }
if ($MesaDir) { $env:PATH = "$MesaDir;$env:PATH" }

$src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class GLE {
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
  [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr hwnd, IntPtr hdc);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
  [DllImport("gdi32.dll")] static extern int ChoosePixelFormat(IntPtr hdc, ref PIXELFORMATDESCRIPTOR pfd);
  [DllImport("gdi32.dll")] static extern bool SetPixelFormat(IntPtr hdc, int fmt, ref PIXELFORMATDESCRIPTOR pfd);
  [DllImport("opengl32.dll")] static extern IntPtr wglCreateContext(IntPtr hdc);
  [DllImport("opengl32.dll")] static extern bool   wglMakeCurrent(IntPtr hdc, IntPtr hglrc);
  [DllImport("opengl32.dll")] static extern bool   wglDeleteContext(IntPtr hglrc);
  [DllImport("opengl32.dll")] static extern IntPtr wglGetProcAddress(string name);
  [DllImport("opengl32.dll")] static extern IntPtr glGetString(uint name);
  [DllImport("opengl32.dll")] static extern void   glGetIntegerv(uint pname, out int data);

  delegate IntPtr GetStringiDel(uint name, uint index);

  public static string Run(string mesaDll, bool all, int px, int py) {
    var sb = new StringBuilder();
    if (!string.IsNullOrEmpty(mesaDll)) {
      if (LoadLibraryW(mesaDll) == IntPtr.Zero)
        return "NEUSPJESNO ucitavanje " + mesaDll;
      sb.AppendLine("Ucitan " + mesaDll);
    }

    IntPtr hwnd = CreateWindowExW(0, "static", "glext", 0x80000000, px, py, 64, 64,
                                  IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    IntPtr hdc = GetDC(hwnd);
    var pfd = new PIXELFORMATDESCRIPTOR();
    pfd.nSize = (ushort)Marshal.SizeOf(typeof(PIXELFORMATDESCRIPTOR));
    pfd.nVersion = 1; pfd.dwFlags = 0x4 | 0x20 | 0x1; pfd.cColorBits = 32; pfd.cDepthBits = 24;
    int fmt = ChoosePixelFormat(hdc, ref pfd);
    if (fmt == 0) return sb.AppendLine("ChoosePixelFormat FAILED").ToString();
    SetPixelFormat(hdc, fmt, ref pfd);
    IntPtr rc = wglCreateContext(hdc);
    if (rc == IntPtr.Zero) return sb.AppendLine("wglCreateContext FAILED").ToString();
    wglMakeCurrent(hdc, rc);

    sb.AppendLine("GL_RENDERER : " + Marshal.PtrToStringAnsi(glGetString(0x1F01)));
    sb.AppendLine("GL_VERSION  : " + Marshal.PtrToStringAnsi(glGetString(0x1F02)));
    sb.AppendLine("GLSL        : " + Marshal.PtrToStringAnsi(glGetString(0x8B8C)));

    var exts = new HashSet<string>();
    int n = 0;
    glGetIntegerv(0x821D, out n);   // GL_NUM_EXTENSIONS
    IntPtr p = wglGetProcAddress("glGetStringi");
    if (p != IntPtr.Zero && n > 0) {
      var f = (GetStringiDel)Marshal.GetDelegateForFunctionPointer(p, typeof(GetStringiDel));
      for (uint i = 0; i < n; i++) {
        string e = Marshal.PtrToStringAnsi(f(0x1F03, i));
        if (e != null) exts.Add(e);
      }
    }
    sb.AppendLine("ekstenzija  : " + exts.Count);
    sb.AppendLine();

    // Ono sto dijeli OpenGL 4.2 od 4.3, plus sto emulatori tipicno trebaju
    string[] key = {
      "GL_ARB_compute_shader",
      "GL_ARB_shader_storage_buffer_object",
      "GL_ARB_explicit_uniform_location",
      "GL_ARB_vertex_attrib_binding",
      "GL_ARB_texture_storage_multisample",
      "GL_ARB_copy_image",
      "GL_ARB_ES3_compatibility",
      "GL_ARB_texture_view",
      "GL_ARB_transform_feedback2",
      "GL_ARB_transform_feedback3",
      "GL_ARB_gpu_shader5",
      "GL_ARB_tessellation_shader",
      "GL_ARB_shader_image_load_store",
      "GL_ARB_separate_shader_objects",
      "GL_ARB_direct_state_access",
      "GL_ARB_clip_control",
      "GL_ARB_get_program_binary",
      "GL_ARB_clear_texture",
      "GL_ARB_buffer_storage",
      "GL_ARB_multi_bind",
      "GL_KHR_debug"
    };
    sb.AppendLine("KLJUCNE EKSTENZIJE");
    foreach (string k in key)
      sb.AppendLine(string.Format("  {0,-40} {1}", k, exts.Contains(k) ? "ima" : "NEMA"));

    if (all) {
      sb.AppendLine();
      sb.AppendLine("SVE EKSTENZIJE");
      var arr = new List<string>(exts); arr.Sort();
      foreach (string e in arr) sb.AppendLine("  " + e);
    }

    wglMakeCurrent(IntPtr.Zero, IntPtr.Zero);
    wglDeleteContext(rc); ReleaseDC(hwnd, hdc); DestroyWindow(hwnd);
    return sb.ToString();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
$dll = if ($MesaDir) { Join-Path $MesaDir 'opengl32.dll' } else { '' }
[GLE]::Run($dll, $All.IsPresent, $X, $Y)
