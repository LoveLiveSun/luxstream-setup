<#
    wgcframe.ps1
    PUNI test Windows.Graphics.Capture: capture item -> D3D uredaj -> frame pool
    -> sesija -> STVARNI KADAR.

    Sve preko sirovog COM-a (RoGetActivationFactory), bez winmd reference,
    jer Add-Type ne moze referencirati .winmd.

    Koristi CreateFreeThreaded da izbjegne potrebu za DispatcherQueue.
#>
$src = @'
using System;
using System.Text;
using System.Threading;
using System.Runtime.InteropServices;

public static class WGCF {

  [DllImport("combase.dll", CharSet = CharSet.Unicode)]
  static extern int WindowsCreateString(string src, int len, out IntPtr hstring);
  [DllImport("combase.dll")] static extern int WindowsDeleteString(IntPtr hstring);
  [DllImport("combase.dll")] static extern int RoGetActivationFactory(IntPtr classId, ref Guid iid, out IntPtr factory);
  [DllImport("combase.dll")] static extern int RoInitialize(int type);
  [DllImport("combase.dll", CharSet = CharSet.Unicode)]
  static extern IntPtr WindowsGetStringRawBuffer(IntPtr hstring, out int length);

  [DllImport("d3d11.dll")]
  static extern int D3D11CreateDevice(IntPtr adapter, uint driverType, IntPtr sw, uint flags,
    IntPtr featureLevels, uint numFL, uint sdk, out IntPtr device, out uint fl, out IntPtr ctx);
  [DllImport("d3d11.dll", EntryPoint = "CreateDirect3D11DeviceFromDXGIDevice")]
  static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

  [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct SIZEI { public int Width, Height; }

  // IGraphicsCaptureItemInterop : IUnknown
  [ComImport, Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IGraphicsCaptureItemInterop {
    [PreserveSig] int CreateForWindow(IntPtr hwnd, ref Guid iid, out IntPtr result);
    [PreserveSig] int CreateForMonitor(IntPtr hmon, ref Guid iid, out IntPtr result);
  }

  // IGraphicsCaptureItem : IInspectable
  [ComImport, Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IGraphicsCaptureItem {
    [PreserveSig] int GetIids(out int c, out IntPtr i);
    [PreserveSig] int GetRuntimeClassName(out IntPtr n);
    [PreserveSig] int GetTrustLevel(out int l);
    [PreserveSig] int get_DisplayName(out IntPtr name);
    [PreserveSig] int get_Size(out SIZEI size);
  }

  // IDirect3D11CaptureFramePoolStatics2 : IInspectable  (CreateFreeThreaded)
  [ComImport, Guid("589B103F-6BBC-5DF5-A991-02E28B3B66D5"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IFramePoolStatics2 {
    [PreserveSig] int GetIids(out int c, out IntPtr i);
    [PreserveSig] int GetRuntimeClassName(out IntPtr n);
    [PreserveSig] int GetTrustLevel(out int l);
    [PreserveSig] int CreateFreeThreaded(IntPtr device, int pixelFormat, int numberOfBuffers,
                                         SIZEI size, out IntPtr framePool);
  }

  // IDirect3D11CaptureFramePool : IInspectable
  [ComImport, Guid("24EB6D22-1975-422E-82E7-780DBD8DDF24"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IFramePool {
    [PreserveSig] int GetIids(out int c, out IntPtr i);
    [PreserveSig] int GetRuntimeClassName(out IntPtr n);
    [PreserveSig] int GetTrustLevel(out int l);
    // TOCAN redoslijed iz IDL-a: Recreate, TryGetNextFrame, add, remove, CreateCaptureSession, DispatcherQueue
    [PreserveSig] int Recreate(IntPtr device, int pixelFormat, int numberOfBuffers, SIZEI size);
    [PreserveSig] int TryGetNextFrame(out IntPtr frame);
    [PreserveSig] int add_FrameArrived(IntPtr handler, out long token);
    [PreserveSig] int remove_FrameArrived(long token);
    [PreserveSig] int CreateCaptureSession(IntPtr item, out IntPtr session);
    [PreserveSig] int get_DispatcherQueue(out IntPtr queue);
  }

  // IGraphicsCaptureSession : IInspectable
  [ComImport, Guid("814E42A9-F70F-4AD7-939B-FDDCC6EB880D"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ICaptureSession {
    [PreserveSig] int GetIids(out int c, out IntPtr i);
    [PreserveSig] int GetRuntimeClassName(out IntPtr n);
    [PreserveSig] int GetTrustLevel(out int l);
    [PreserveSig] int StartCapture();
  }

  // IDirect3D11CaptureFrame : IInspectable
  [ComImport, Guid("FA50C623-38DA-4B32-ACF3-FA9734AD800E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ICaptureFrame {
    [PreserveSig] int GetIids(out int c, out IntPtr i);
    [PreserveSig] int GetRuntimeClassName(out IntPtr n);
    [PreserveSig] int GetTrustLevel(out int l);
    [PreserveSig] int get_Surface(out IntPtr surface);
    [PreserveSig] int get_SystemRelativeTime(out long time);
    [PreserveSig] int get_ContentSize(out SIZEI size);
  }

  static string HStr(IntPtr h) {
    if (h == IntPtr.Zero) return "";
    int len; IntPtr b = WindowsGetStringRawBuffer(h, out len);
    return Marshal.PtrToStringUni(b, len);
  }

  static int Factory(string cls, Guid iid, out IntPtr f) {
    IntPtr h; int hr = WindowsCreateString(cls, cls.Length, out h);
    if (hr != 0) { f = IntPtr.Zero; return hr; }
    hr = RoGetActivationFactory(h, ref iid, out f);
    WindowsDeleteString(h);
    return hr;
  }

  public static string Run(int x, int y, string label) {
    var sb = new StringBuilder();
    sb.AppendLine("--- " + label + " ---");
    RoInitialize(1);

    var pt = new POINT(); pt.x = x; pt.y = y;
    IntPtr hmon = MonitorFromPoint(pt, 2);
    if (hmon == IntPtr.Zero) return sb.AppendLine("  nema monitora").ToString();

    // 1. capture item
    IntPtr fInterop;
    int hr = Factory("Windows.Graphics.Capture.GraphicsCaptureItem",
                     new Guid("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356"), out fInterop);
    if (hr != 0) return sb.AppendLine(string.Format("  interop factory 0x{0:X8}", hr)).ToString();

    var interop = (IGraphicsCaptureItemInterop)Marshal.GetObjectForIUnknown(fInterop);
    Guid itemIid = new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    IntPtr itemPtr;
    hr = interop.CreateForMonitor(hmon, ref itemIid, out itemPtr);
    if (hr != 0) return sb.AppendLine(string.Format("  CreateForMonitor 0x{0:X8}", hr)).ToString();

    var item = (IGraphicsCaptureItem)Marshal.GetObjectForIUnknown(itemPtr);
    SIZEI size; item.get_Size(out size);
    IntPtr nm; item.get_DisplayName(out nm);
    sb.AppendLine("  item OK: '" + HStr(nm) + "'  " + size.Width + "x" + size.Height);

    // 2. D3D uredaj -> IDirect3DDevice
    IntPtr dev, ctx; uint fl;
    hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0x20, IntPtr.Zero, 0, 7, out dev, out fl, out ctx);
    if (hr != 0) return sb.AppendLine(string.Format("  D3D11CreateDevice 0x{0:X8}", hr)).ToString();
    Guid dxgiIid = new Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c");
    IntPtr dxgiDev; Marshal.QueryInterface(dev, ref dxgiIid, out dxgiDev);
    IntPtr gDev;
    hr = CreateDirect3D11DeviceFromDXGIDevice(dxgiDev, out gDev);
    if (hr != 0) return sb.AppendLine(string.Format("  CreateDirect3D11DeviceFromDXGIDevice 0x{0:X8}", hr)).ToString();
    sb.AppendLine("  IDirect3DDevice OK");

    // 3. frame pool (free threaded - ne treba DispatcherQueue)
    IntPtr fPool;
    hr = Factory("Windows.Graphics.Capture.Direct3D11CaptureFramePool",
                 new Guid("589B103F-6BBC-5DF5-A991-02E28B3B66D5"), out fPool);
    if (hr != 0) return sb.AppendLine(string.Format("  framepool factory 0x{0:X8}", hr)).ToString();

    var statics = (IFramePoolStatics2)Marshal.GetObjectForIUnknown(fPool);
    IntPtr poolPtr;
    hr = statics.CreateFreeThreaded(gDev, 87 /* B8G8R8A8UIntNormalized */, 2, size, out poolPtr);
    if (hr != 0) return sb.AppendLine(string.Format("  CreateFreeThreaded 0x{0:X8}", hr)).ToString();
    sb.AppendLine("  frame pool OK");

    // 4. sesija
    var pool = (IFramePool)Marshal.GetObjectForIUnknown(poolPtr);
    IntPtr sessPtr;
    hr = pool.CreateCaptureSession(itemPtr, out sessPtr);
    if (hr != 0) return sb.AppendLine(string.Format("  CreateCaptureSession 0x{0:X8}", hr)).ToString();
    var sess = (ICaptureSession)Marshal.GetObjectForIUnknown(sessPtr);
    hr = sess.StartCapture();
    if (hr != 0) return sb.AppendLine(string.Format("  StartCapture 0x{0:X8}", hr)).ToString();
    sb.AppendLine("  StartCapture OK - cekam kadrove...");

    // 5. stvarni kadrovi
    int got = 0;
    for (int i = 0; i < 100 && got < 3; i++) {
      IntPtr framePtr;
      if (pool.TryGetNextFrame(out framePtr) == 0 && framePtr != IntPtr.Zero) {
        var f = (ICaptureFrame)Marshal.GetObjectForIUnknown(framePtr);
        SIZEI cs; f.get_ContentSize(out cs);
        long t; f.get_SystemRelativeTime(out t);
        got++;
        sb.AppendLine("  *** KADAR " + got + " *** " + cs.Width + "x" + cs.Height + "  t=" + t);
        Marshal.ReleaseComObject(f);
      } else {
        Thread.Sleep(50);
      }
    }
    if (got == 0) sb.AppendLine("  NIJEDAN KADAR u 5 s - sesija radi ali kadrovi ne stizu");
    else sb.AppendLine("  UKUPNO KADROVA: " + got);
    return sb.ToString();
  }
}
'@
if (-not ('WGCF' -as [type])) { Add-Type -TypeDefinition $src -Language CSharp }

Add-Type -AssemblyName System.Windows.Forms
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  $cx = $s.Bounds.X + [int]($s.Bounds.Width / 2)
  $cy = $s.Bounds.Y + [int]($s.Bounds.Height / 2)
  [WGCF]::Run($cx, $cy, "$($s.DeviceName)  $($s.Bounds.Width)x$($s.Bounds.Height)  primary=$($s.Primary)")
}
