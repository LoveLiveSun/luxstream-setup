<#
    wgctest2.ps1
    Test WGC-a bez PowerShellove WinRT projekcije - sve preko sirovog COM-a
    (RoGetActivationFactory + IGraphicsCaptureItemInterop).

    Odgovara na jedno pitanje: moze li se stvoriti GraphicsCaptureItem za
    display koji pripada GPU-P adapteru, gdje Desktop Duplication pada.
#>
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WGC2 {

  [DllImport("combase.dll", CharSet = CharSet.Unicode)]
  static extern int WindowsCreateString(string src, int len, out IntPtr hstring);
  [DllImport("combase.dll")]
  static extern int WindowsDeleteString(IntPtr hstring);
  [DllImport("combase.dll")]
  static extern int RoGetActivationFactory(IntPtr classId, ref Guid iid, out IntPtr factory);
  [DllImport("combase.dll")]
  static extern int RoInitialize(int type);

  [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"),
   InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  // NASLJEDUJE IUnknown, NE IInspectable - nema GetIids/GetRuntimeClassName/GetTrustLevel
  interface IGraphicsCaptureItemInterop {
    [PreserveSig] int CreateForWindow(IntPtr window, ref Guid iid, out IntPtr result);
    [PreserveSig] int CreateForMonitor(IntPtr monitor, ref Guid iid, out IntPtr result);
  }

  [ComImport, Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760"),
   InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IGraphicsCaptureItem {
    [PreserveSig] int GetIids(out int count, out IntPtr iids);
    [PreserveSig] int GetRuntimeClassName(out IntPtr name);
    [PreserveSig] int GetTrustLevel(out int level);
    [PreserveSig] int get_DisplayName(out IntPtr name);
    [PreserveSig] int get_Size(out SIZEI size);
  }

  [StructLayout(LayoutKind.Sequential)] public struct SIZEI { public int Width, Height; }

  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }

  [DllImport("combase.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr WindowsGetStringRawBuffer(IntPtr hstring, out int length);

  static string FromHString(IntPtr h) {
    if (h == IntPtr.Zero) return "";
    int len; IntPtr buf = WindowsGetStringRawBuffer(h, out len);
    return Marshal.PtrToStringUni(buf, len);
  }

  public static IntPtr MonitorAt(int x, int y) {
    var p = new POINT(); p.x = x; p.y = y;
    return MonitorFromPoint(p, 2);
  }

  public static string TestMonitor(int x, int y, string label) {
    var sb = new StringBuilder();
    sb.AppendLine("--- " + label + " ---");

    RoInitialize(1); // RO_INIT_MULTITHREADED

    IntPtr hmon = MonitorAt(x, y);
    sb.AppendLine("  HMONITOR : 0x" + hmon.ToInt64().ToString("X"));
    if (hmon == IntPtr.Zero) return sb.AppendLine("  nema monitora").ToString();

    IntPtr cls;
    int hr = WindowsCreateString("Windows.Graphics.Capture.GraphicsCaptureItem",
                                 "Windows.Graphics.Capture.GraphicsCaptureItem".Length, out cls);
    if (hr != 0) return sb.AppendLine(string.Format("  WindowsCreateString 0x{0:X8}", hr)).ToString();

    Guid interopIid = new Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
    IntPtr factoryPtr;
    hr = RoGetActivationFactory(cls, ref interopIid, out factoryPtr);
    WindowsDeleteString(cls);
    if (hr != 0) return sb.AppendLine(string.Format("  RoGetActivationFactory 0x{0:X8}", hr)).ToString();
    sb.AppendLine("  activation factory OK");

    var interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(factoryPtr);
    Guid itemIid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    IntPtr itemPtr;
    hr = interop.CreateForMonitor(hmon, ref itemIid, out itemPtr);
    if (hr != 0 || itemPtr == IntPtr.Zero)
      return sb.AppendLine(string.Format("  CreateForMonitor NEUSPJESAN 0x{0:X8}", hr)).ToString();

    sb.AppendLine("  *** CreateForMonitor OK ***");
    var item = (IGraphicsCaptureItem)Marshal.GetObjectForIUnknown(itemPtr);
    IntPtr nm; item.get_DisplayName(out nm);
    SIZEI sz; item.get_Size(out sz);
    sb.AppendLine("  DisplayName : '" + FromHString(nm) + "'");
    sb.AppendLine("  Size        : " + sz.Width + "x" + sz.Height);
    return sb.ToString();
  }
}
'@
if (-not ('WGC2' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

Add-Type -AssemblyName System.Windows.Forms
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  $cx = $s.Bounds.X + [int]($s.Bounds.Width / 2)
  $cy = $s.Bounds.Y + [int]($s.Bounds.Height / 2)
  [WGC2]::TestMonitor($cx, $cy, "$($s.DeviceName)  $($s.Bounds.Width)x$($s.Bounds.Height)  primary=$($s.Primary)")
}
