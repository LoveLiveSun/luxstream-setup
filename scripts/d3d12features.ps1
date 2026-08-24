<#
    d3d12features.ps1
    Ispituje D3D12 mogucnosti svakog adaptera: najvisi Shader Model i Resource Binding Tier.
    Mesin Dozen (Vulkan preko D3D12) trazi Shader Model 6.0+ i Resource Binding Tier 2+.
#>
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class D12F {
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

  // ID3D12Device: 3 IUnknown + 4 ID3D12Object + GetNodeCount, CreateCommandQueue,
  // CreateCommandAllocator, CreateGraphicsPipelineState, CreateComputePipelineState,
  // CreateCommandList, CheckFeatureSupport
  [ComImport, Guid("189819f1-1db6-4b57-be54-1821339b85f7"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface ID3D12Device {
    void GetPrivateData(); void SetPrivateData(); void SetPrivateDataInterface(); void SetName();
    void GetNodeCount(); void CreateCommandQueue(); void CreateCommandAllocator();
    void CreateGraphicsPipelineState(); void CreateComputePipelineState(); void CreateCommandList();
    [PreserveSig] int CheckFeatureSupport(uint feature, IntPtr data, uint size);
  }

  [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid r,
    [MarshalAs(UnmanagedType.Interface)] out IDXGIFactory1 f);

  [DllImport("d3d12.dll")] static extern int D3D12CreateDevice(
    [MarshalAs(UnmanagedType.IUnknown)] object adapter, uint minFeatureLevel,
    ref Guid riid, [MarshalAs(UnmanagedType.Interface)] out ID3D12Device device);

  static string SM(uint v) {
    switch (v) {
      case 0x51: return "5.1"; case 0x60: return "6.0"; case 0x61: return "6.1";
      case 0x62: return "6.2"; case 0x63: return "6.3"; case 0x64: return "6.4";
      case 0x65: return "6.5"; case 0x66: return "6.6"; case 0x67: return "6.7";
      default: return "0x" + v.ToString("X");
    }
  }

  public static string Run() {
    var sb = new StringBuilder();
    var iid = new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    IDXGIFactory1 fac;
    if (CreateDXGIFactory1(ref iid, out fac) != 0) return "CreateDXGIFactory1 FAILED";
    var devIid = new Guid("189819f1-1db6-4b57-be54-1821339b85f7");

    for (uint ai = 0; ai < 16; ai++) {
      IDXGIAdapter1 ad;
      if (fac.EnumAdapters1(ai, out ad) != 0) break;
      DXGI_ADAPTER_DESC1 d; ad.GetDesc1(out d);
      sb.AppendLine();
      sb.AppendFormat("ADAPTER {0}: {1}   VRAM {2} MiB", ai, d.Description.Trim(),
                      (ulong)d.DedicatedVideoMemory.ToUInt64()/(1024*1024)).AppendLine();

      ID3D12Device dev;
      if (D3D12CreateDevice(ad, 0xb000, ref devIid, out dev) != 0) {
        sb.AppendLine("   D3D12 uredaj se ne moze stvoriti");
        continue;
      }

      // D3D12_FEATURE_SHADER_MODEL = 7 : probaj od najviseg prema nizem
      IntPtr buf = Marshal.AllocHGlobal(256);
      try {
        uint[] probe = { 0x67, 0x66, 0x65, 0x64, 0x63, 0x62, 0x61, 0x60, 0x51 };
        string found = "nijedan";
        foreach (uint p in probe) {
          Marshal.WriteInt32(buf, 0, (int)p);
          if (dev.CheckFeatureSupport(7, buf, 4) == 0) {
            found = SM((uint)Marshal.ReadInt32(buf, 0));
            break;
          }
        }
        sb.AppendFormat("   najvisi Shader Model : {0}", found).AppendLine();

        // D3D12_FEATURE_D3D12_OPTIONS = 0 ; ResourceBindingTier je 4. DWORD (offset 12)
        for (int i = 0; i < 64; i++) Marshal.WriteInt32(buf, i*4, 0);
        if (dev.CheckFeatureSupport(0, buf, 40) == 0) {
          int tier = Marshal.ReadInt32(buf, 12);
          sb.AppendFormat("   Resource Binding Tier: {0}", tier).AppendLine();
        } else {
          sb.AppendLine("   Resource Binding Tier: upit neuspjesan");
        }
      } finally { Marshal.FreeHGlobal(buf); }
    }
    return sb.ToString();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
[D12F]::Run()
