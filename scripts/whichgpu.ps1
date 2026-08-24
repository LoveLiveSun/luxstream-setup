# Koji adapter dobije obicna aplikacija koja trazi hardverski D3D11 uredjaj?
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class WG {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DXGI_ADAPTER_DESC {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    public uint VendorId, DeviceId, SubSysId, Revision;
    public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    public LUID AdapterLuid;
  }

  [ComImport, Guid("54ec77fa-1377-44e6-8c32-88fd5f44c84c"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IDXGIDevice {
    void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
    [PreserveSig] int GetAdapter(out IDXGIAdapter a);
    void CreateSurface(); void QueryResourceResidency(); void SetGPUThreadPriority(); void GetGPUThreadPriority();
  }

  [ComImport, Guid("2411e7e1-12ac-4ccf-bd14-9798e8534dc0"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IDXGIAdapter {
    void SetPrivateData(); void SetPrivateDataInterface(); void GetPrivateData(); void GetParent();
    void EnumOutputs();
    [PreserveSig] int GetDesc(out DXGI_ADAPTER_DESC d);
    void CheckInterfaceSupport();
  }

  [DllImport("d3d11.dll")] static extern int D3D11CreateDevice(
    IntPtr adapter, uint driverType, IntPtr sw, uint flags,
    IntPtr featureLevels, uint numFL, uint sdk,
    [MarshalAs(UnmanagedType.IUnknown)] out object dev, out uint fl, IntPtr ctx);

  public static string Run() {
    var sb = new StringBuilder();
    // driverType 1 = D3D_DRIVER_TYPE_HARDWARE, adapter = null -> ono sto sustav sam odabere
    object dev; uint fl;
    int hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0, IntPtr.Zero, 0, 7, out dev, out fl, IntPtr.Zero);
    if (hr != 0) return string.Format("D3D11CreateDevice(HARDWARE) FAILED 0x{0:X8}", hr);

    var dxdev = (IDXGIDevice)dev;
    IDXGIAdapter ad;
    dxdev.GetAdapter(out ad);
    DXGI_ADAPTER_DESC d;
    ad.GetDesc(out d);
    sb.AppendLine("Aplikacija koja trazi HARDWARE uredjaj dobije:");
    sb.AppendFormat("   {0}", d.Description.Trim()).AppendLine();
    sb.AppendFormat("   LUID {0}-{1}   VRAM {2} MiB   VEN 0x{3:X4} DEV 0x{4:X4}   FeatureLevel 0x{5:X}",
      d.AdapterLuid.Low, d.AdapterLuid.High,
      (ulong)d.DedicatedVideoMemory.ToUInt64()/(1024*1024), d.VendorId, d.DeviceId, fl).AppendLine();
    return sb.ToString();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
[WG]::Run()
