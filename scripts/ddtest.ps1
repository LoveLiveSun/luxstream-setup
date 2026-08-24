# Izravan test IDXGIOutput1::DuplicateOutput nad svakom kombinacijom adapter/output.
# Cijela logika je u C# jer PowerShell lose barata ComImport sucejima.

$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class DD {

  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DXGI_ADAPTER_DESC1 {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    public uint VendorId, DeviceId, SubSysId, Revision;
    public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    public LUID AdapterLuid; public uint Flags;
  }

  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DXGI_OUTPUT_DESC {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string DeviceName;
    public RECT DesktopCoordinates;
    [MarshalAs(UnmanagedType.Bool)] public bool AttachedToDesktop;
    public uint Rotation; public IntPtr Monitor;
  }

  [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IDXGIFactory1 {
    void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
    [PreserveSig] int EnumAdapters(uint i, out IntPtr a);
    void MakeWindowAssociation(); void GetWindowAssociation(); void CreateSwapChain(); void CreateSoftwareAdapter();
    [PreserveSig] int EnumAdapters1(uint i, out IDXGIAdapter1 a);
    [PreserveSig] int IsCurrent();
  }

  [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IDXGIAdapter1 {
    void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
    [PreserveSig] int EnumOutputs(uint i, out IDXGIOutput1 o);
    void GetDesc(); void CheckInterfaceSupport();
    [PreserveSig] int GetDesc1(out DXGI_ADAPTER_DESC1 d);
  }

  [ComImport, Guid("00cddea8-939b-4b83-a340-a685226666cc"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IDXGIOutput1 {
    void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
    [PreserveSig] int GetDesc(out DXGI_OUTPUT_DESC d);
    void GetDisplayModeList(); void FindClosestMatchingMode(); void WaitForVBlank();
    void TakeOwnership(); void ReleaseOwnership();
    void GetGammaControlCapabilities(); void SetGammaControl(); void GetGammaControl();
    void SetDisplaySurface(); void GetDisplaySurfaceData(); void GetFrameStatistics();
    void GetDisplayModeList1(); void FindClosestMatchingMode1(); void GetDisplaySurfaceData1();
    [PreserveSig] int DuplicateOutput([MarshalAs(UnmanagedType.IUnknown)] object dev, out IntPtr dup);
  }

  [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid r,
    [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 f);

  [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(
    IDXGIAdapter1 adapter, uint driverType, IntPtr sw, uint flags,
    IntPtr featureLevels, uint numFL, uint sdk,
    [MarshalAs(UnmanagedType.IUnknown)] out object dev, out uint fl, IntPtr ctx);

  public static string Run() {
    var sb = new StringBuilder();
    var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    IDXGIFactory1 fac;
    int hr = CreateDXGIFactory1(ref iid, out fac);
    if (hr != 0) return string.Format("CreateDXGIFactory1 FAILED 0x{0:X8}", hr);

    for (uint ai = 0; ai < 16; ai++) {
      IDXGIAdapter1 ad;
      if (fac.EnumAdapters1(ai, out ad) != 0) break;

      DXGI_ADAPTER_DESC1 d;
      ad.GetDesc1(out d);
      sb.AppendLine();
      sb.AppendFormat("ADAPTER {0}: {1}", ai, d.Description.Trim()).AppendLine();
      sb.AppendFormat("   LUID {0}-{1}   VRAM {2} MiB   VEN 0x{3:X4} DEV 0x{4:X4}",
        d.AdapterLuid.Low, d.AdapterLuid.High,
        (ulong)d.DedicatedVideoMemory.ToUInt64() / (1024*1024), d.VendorId, d.DeviceId).AppendLine();

      object dev; uint fl;
      int hrd = D3D11CreateDevice(ad, 0, IntPtr.Zero, 0, IntPtr.Zero, 0, 7, out dev, out fl, IntPtr.Zero);
      if (hrd != 0) {
        sb.AppendFormat("   D3D11CreateDevice FAILED 0x{0:X8}", hrd).AppendLine();
        continue;
      }
      sb.AppendFormat("   D3D11 device OK (FeatureLevel 0x{0:X})", fl).AppendLine();

      bool any = false;
      for (uint oi = 0; oi < 16; oi++) {
        IDXGIOutput1 outp;
        if (ad.EnumOutputs(oi, out outp) != 0) break;
        any = true;
        DXGI_OUTPUT_DESC od;
        outp.GetDesc(out od);
        int w = od.DesktopCoordinates.R - od.DesktopCoordinates.L;
        int h = od.DesktopCoordinates.B - od.DesktopCoordinates.T;
        IntPtr dup;
        int hx = outp.DuplicateOutput(dev, out dup);
        string verdict = (hx == 0) ? "*** DUPLICATE OK ***" : string.Format("FAIL 0x{0:X8}", hx);
        sb.AppendFormat("   OUTPUT {0}: {1,-14} {2}x{3} attached={4}  -> {5}",
          oi, od.DeviceName.Trim(), w, h, od.AttachedToDesktop, verdict).AppendLine();
        if (dup != IntPtr.Zero) Marshal.Release(dup);
      }
      if (!any) sb.AppendLine("   (nema outputa)");
    }
    return sb.ToString();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
[DD]::Run()
