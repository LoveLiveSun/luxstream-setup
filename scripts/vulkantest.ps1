<#
    vulkantest.ps1
    Nabraja Vulkan uredaje izravno preko vulkan-1.dll.
    Daje istinu neovisno o aplikacijama - ako ovdje nema uredaja, nijedna Vulkan
    aplikacija nece raditi.
#>
$src = @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class VK {
  [StructLayout(LayoutKind.Sequential)]
  public struct VkInstanceCreateInfo {
    public int    sType;
    public IntPtr pNext;
    public uint   flags;
    public IntPtr pApplicationInfo;
    public uint   enabledLayerCount;
    public IntPtr ppEnabledLayerNames;
    public uint   enabledExtensionCount;
    public IntPtr ppEnabledExtensionNames;
  }

  [DllImport("vulkan-1.dll")] static extern int vkCreateInstance(ref VkInstanceCreateInfo ci, IntPtr alloc, out IntPtr instance);
  [DllImport("vulkan-1.dll")] static extern void vkDestroyInstance(IntPtr instance, IntPtr alloc);
  [DllImport("vulkan-1.dll")] static extern int vkEnumeratePhysicalDevices(IntPtr instance, ref uint count, [In,Out] IntPtr[] devices);
  [DllImport("vulkan-1.dll")] static extern void vkGetPhysicalDeviceProperties(IntPtr device, IntPtr props);

  static string DeviceTypeName(uint t) {
    switch (t) {
      case 0: return "Other";
      case 1: return "Integrated GPU";
      case 2: return "Discrete GPU";
      case 3: return "Virtual GPU";
      case 4: return "CPU (softverski)";
      default: return "?";
    }
  }

  public static string Run() {
    var sb = new StringBuilder();
    var ci = new VkInstanceCreateInfo();
    ci.sType = 1;   // VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO

    IntPtr inst;
    int r = vkCreateInstance(ref ci, IntPtr.Zero, out inst);
    if (r != 0) {
      sb.AppendLine("vkCreateInstance NEUSPJESAN, kod " + r);
      if (r == -9) sb.AppendLine("  -9 = VK_ERROR_INCOMPATIBLE_DRIVER : loader nije nasao nijedan ICD.");
      return sb.ToString();
    }
    sb.AppendLine("vkCreateInstance OK");

    uint count = 0;
    vkEnumeratePhysicalDevices(inst, ref count, null);
    sb.AppendLine("Vulkan uredaja: " + count);
    if (count == 0) {
      sb.AppendLine("  Loader radi, ali nema registriranog drivera (ICD).");
      vkDestroyInstance(inst, IntPtr.Zero);
      return sb.ToString();
    }

    var devs = new IntPtr[count];
    vkEnumeratePhysicalDevices(inst, ref count, devs);

    IntPtr buf = Marshal.AllocHGlobal(1024);
    try {
      for (int i = 0; i < count; i++) {
        vkGetPhysicalDeviceProperties(devs[i], buf);
        uint apiVer  = (uint)Marshal.ReadInt32(buf, 0);
        uint drvVer  = (uint)Marshal.ReadInt32(buf, 4);
        uint vendor  = (uint)Marshal.ReadInt32(buf, 8);
        uint devId   = (uint)Marshal.ReadInt32(buf, 12);
        uint devType = (uint)Marshal.ReadInt32(buf, 16);
        string name  = Marshal.PtrToStringAnsi(new IntPtr(buf.ToInt64() + 20));

        sb.AppendLine();
        sb.AppendLine("  [" + i + "] " + name);
        sb.AppendLine(string.Format("      tip       : {0}", DeviceTypeName(devType)));
        sb.AppendLine(string.Format("      Vulkan API: {0}.{1}.{2}", (apiVer >> 22), ((apiVer >> 12) & 0x3FF), (apiVer & 0xFFF)));
        sb.AppendLine(string.Format("      vendor    : 0x{0:X4}   device: 0x{1:X4}", vendor, devId));
        sb.AppendLine(string.Format("      driver    : {0}", drvVer));
      }
    } finally { Marshal.FreeHGlobal(buf); }

    vkDestroyInstance(inst, IntPtr.Zero);
    return sb.ToString();
  }
}
'@
Add-Type -TypeDefinition $src -Language CSharp
[VK]::Run()
