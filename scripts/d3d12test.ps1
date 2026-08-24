<#
    d3d12test.ps1
    Provjerava moze li se stvoriti D3D12 uredaj na svakom DXGI adapteru.
    Bitno jer Mesin Dozen (Vulkan preko D3D12) bez toga ne moze raditi.
#>
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class D12 {
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
  public struct DXGI_ADAPTER_DESC1 {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string Description;
    public uint VendorId, DeviceId, SubSysId, Revision;
    public UIntPtr DedicatedVideoMemory, DedicatedSystemMemory, SharedSystemMemory;
    public LUID AdapterLuid; public uint Flags;
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
    [PreserveSig] int EnumOutputs(uint i, out IntPtr o);
    void GetDesc(); void CheckInterfaceSupport();
    [PreserveSig] int GetDesc1(out DXGI_ADAPTER_DESC1 d);
  }

  [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid r,
    [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 f);

  [DllImport("d3d12.dll")] static extern int D3D12CreateDevice(
    [MarshalAs(UnmanagedType.IUnknown)] object adapter, uint minFeatureLevel,
    ref Guid riid, out IntPtr device);

  public static string Run() {
    var sb = new StringBuilder();
    var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    IDXGIFactory1 fac;
    if (CreateDXGIFactory1(ref iid, out fac) != 0) return "CreateDXGIFactory1 FAILED";

    // ID3D12Device
    var devIid = new Guid("189819f1-1db6-4b57-be54-1821339b85f7");
    uint[] levels = { 0xc000, 0xb100, 0xb000 };          // 12_0, 11_1, 11_0
    string[] names = { "12_0", "11_1", "11_0" };

    for (uint ai = 0; ai < 16; ai++) {
      IDXGIAdapter1 ad;
      if (fac.EnumAdapters1(ai, out ad) != 0) break;
      DXGI_ADAPTER_DESC1 d; ad.GetDesc1(out d);
      sb.AppendLine();
      sb.AppendFormat("ADAPTER {0}: {1}", ai, d.Description.Trim()).AppendLine();
      sb.AppendFormat("   LUID {0}-{1}   VRAM {2} MiB", d.AdapterLuid.Low, d.AdapterLuid.High,
                      (ulong)d.DedicatedVideoMemory.ToUInt64()/(1024*1024)).AppendLine();

      bool any = false;
      for (int i = 0; i < levels.Length; i++) {
        IntPtr dev;
        int hr = D3D12CreateDevice(ad, levels[i], ref devIid, out dev);
        if (hr == 0) {
          sb.AppendFormat("   D3D12 OK na feature level {0}", names[i]).AppendLine();
          Marshal.Release(dev);
          any = true;
          break;
        }
      }
      if (!any) {
        IntPtr dev2;
        int hr = D3D12CreateDevice(ad, 0xb000, ref devIid, out dev2);
        sb.AppendFormat("   D3D12 NE RADI  (HRESULT 0x{0:X8})", hr).AppendLine();
      }
    }
    return sb.ToString();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
[D12]::Run()
