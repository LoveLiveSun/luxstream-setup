<#
    snimi-display-stanje.ps1

    Snimi detaljno stanje display podsustava u datoteku, da se dva stanja mogu
    usporediti red po red.

    ZASTO
      NVIDIA-in ICD u GPU-P gostu nabraja uredaje samo dok postoji aktivan
      NVIDIA-in display put. Znamo ISHOD (bez Hyper-V displaya Vulkan javi 0),
      ali ne znamo STO mu tocno nedostaje. Ova skripta snimi sve sto se dade
      ocitati, pa se stanja usporede diffom.

    UPOTREBA
      .\snimi-display-stanje.ps1 -Oznaka "s-monitorom"
      .\snimi-display-stanje.ps1 -Oznaka "bez-monitora"
#>
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Oznaka)

$out = "C:\Users\Public\display-stanje-$Oznaka.txt"
$R = New-Object System.Collections.Generic.List[string]
function W($m){ $R.Add($m) }

W "===== $Oznaka  $(Get-Date -Format 'HH:mm:ss') ====="
W ''

# ---------------------------------------------------------------- CCD putevi
$ccd = @'
using System;using System.Runtime.InteropServices;
public class CCD {
  [DllImport("user32.dll")] public static extern int GetDisplayConfigBufferSizes(uint flags, out uint np, out uint nm);
  [DllImport("user32.dll")] public static extern int QueryDisplayConfig(uint flags, ref uint np, [Out] PATH[] pa, ref uint nm, [Out] MODE[] ma, IntPtr topo);
  [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
  [StructLayout(LayoutKind.Sequential)] public struct SRC { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct TGT { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation; public uint scaling; public ulong refreshRate; public uint scanLineOrdering; public bool targetAvailable; public uint statusFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct PATH { public SRC sourceInfo; public TGT targetInfo; public uint flags; }
  [StructLayout(LayoutKind.Sequential)] public struct MODE { public uint infoType; public uint id; public LUID adapterId; public ulong a,b,c,d,e,f,g,h; }
}
'@
if(-not ('CCD' -as [type])){ Add-Type -TypeDefinition $ccd }

foreach($q in @(@{n='SVI';v=1}, @{n='AKTIVNI';v=2})){
  $np=0;$nm=0
  [CCD]::GetDisplayConfigBufferSizes($q.v,[ref]$np,[ref]$nm) | Out-Null
  $pa=New-Object 'CCD+PATH[]' $np
  $ma=New-Object 'CCD+MODE[]' $nm
  $rc=[CCD]::QueryDisplayConfig($q.v,[ref]$np,$pa,[ref]$nm,$ma,[IntPtr]::Zero)
  W "--- CCD putevi ($($q.n)): rc=$rc, putova=$np, modova=$nm ---"
  for($i=0;$i -lt $np;$i++){
    $p=$pa[$i]
    $akt = ($p.flags -band 1) -ne 0
    if($akt -or $q.v -eq 2){
      W ("  put {0,-3} aktivan={1,-5} src.adapter={2}-{3} src.id={4}  tgt.id={5} tech={6} refresh={7} available={8} tgtStatus=0x{9:X}" -f `
         $i,$akt,$p.sourceInfo.adapterId.Low,$p.sourceInfo.adapterId.High,$p.sourceInfo.id,`
         $p.targetInfo.id,$p.targetInfo.outputTechnology,$p.targetInfo.refreshRate,$p.targetInfo.targetAvailable,$p.targetInfo.statusFlags)
    }
  }
  W ''
}

# ---------------------------------------------------------------- DXGI adapteri
$dxgi = @'
using System;using System.Runtime.InteropServices;using System.Text;
public class DXA {
  [DllImport("dxgi.dll")] static extern int CreateDXGIFactory1(ref Guid iid, out IntPtr f);
  [ComImport,Guid("770aae78-f26f-4dba-a829-253c83d1b387"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IF1 { void a();void b();void c();void d();void e();void f();void g();
    [PreserveSig] int EnumAdapters1(uint i, out IntPtr ad); }
  [ComImport,Guid("29038f61-3839-4626-91fd-086879011a05"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IA1 { void a();void b();void c();
    [PreserveSig] int EnumOutputs(uint i, out IntPtr o);
    [PreserveSig] int GetDesc(IntPtr d);
    void e();
    [PreserveSig] int GetDesc1(IntPtr d); }
  [ComImport,Guid("ae02eedb-c735-4690-8d52-5a8dc20213aa"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IO { [PreserveSig] int GetDesc(IntPtr d); }
  public static string Dump(){
    var sb=new StringBuilder();
    Guid iid=new Guid("770aae78-f26f-4dba-a829-253c83d1b387");
    IntPtr fp; if(CreateDXGIFactory1(ref iid,out fp)!=0) return "  CreateDXGIFactory1 pao";
    var f=(IF1)Marshal.GetObjectForIUnknown(fp);
    for(uint i=0;i<16;i++){
      IntPtr ap; if(f.EnumAdapters1(i,out ap)!=0) break;
      var a=(IA1)Marshal.GetObjectForIUnknown(ap);
      IntPtr buf=Marshal.AllocHGlobal(1024);
      a.GetDesc1(buf);
      string name=Marshal.PtrToStringUni(buf,128).TrimEnd('\0');
      uint ven=(uint)Marshal.ReadInt32(buf,256);
      uint dev=(uint)Marshal.ReadInt32(buf,260);
      long vram=Marshal.ReadInt64(buf,272);
      uint lo=(uint)Marshal.ReadInt32(buf,296); int hi=Marshal.ReadInt32(buf,300);
      int nOut=0;
      for(uint j=0;j<8;j++){ IntPtr op; if(a.EnumOutputs(j,out op)!=0) break; nOut++; Marshal.Release(op); }
      sb.AppendLine(string.Format("  adapter {0}: {1,-34} VEN=0x{2:X4} DEV=0x{3:X4} VRAM={4} MiB LUID={5}-{6} outputa={7}",
        i,name,ven,dev,vram/1048576,lo,hi,nOut));
      Marshal.FreeHGlobal(buf);
    }
    return sb.ToString();
  }
}
'@
if(-not ('DXA' -as [type])){ Add-Type -TypeDefinition $dxgi }
W '--- DXGI adapteri i broj izlaza ---'
[DXA]::Dump() -split "`r?`n" | Where-Object { $_ } | ForEach-Object { W $_ }
W ''

# ---------------------------------------------------------------- displayi
Add-Type -AssemblyName System.Windows.Forms
W '--- prikaceni displayi ---'
foreach($s in [System.Windows.Forms.Screen]::AllScreens){
  W ("  {0,-14} primary={1,-5} {2}x{3} @ {4},{5}" -f $s.DeviceName,$s.Primary,$s.Bounds.Width,$s.Bounds.Height,$s.Bounds.X,$s.Bounds.Y)
}
W ''

# ---------------------------------------------------------------- PnP
W '--- display adapteri (PnP) ---'
Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Sort-Object InstanceId | ForEach-Object {
  W ("  {0,-8} {1,-36} {2}" -f $_.Status,$_.FriendlyName,$_.InstanceId)
}
W ''
W '--- monitori (PnP) ---'
Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue | Sort-Object InstanceId | ForEach-Object {
  $par=(Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data
  W ("  {0,-8} parent={1}" -f $_.Status,$par)
}
W ''

# ---------------------------------------------------------------- grafika
$S='C:\Users\Public\sunshine-gpup-setup\scripts'
W '--- VULKAN ---'
(& "$S\vulkantest.ps1" 2>&1) | ForEach-Object { W "  $_" }
W '--- OPENGL ---'
(& "$S\gltest.ps1" 2>&1) | ForEach-Object { W "  $_" }

[System.IO.File]::WriteAllLines($out,$R,(New-Object System.Text.UTF8Encoding($false)))
Write-Host "zapisano: $out  ($($R.Count) redaka)"
