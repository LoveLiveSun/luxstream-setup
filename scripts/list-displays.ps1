# list-displays.ps1
#
# Ispise prikacene displaye, po jedan u retku:
#   \\.\DISPLAY31|1920|1080|60|True
#   ime|sirina|visina|osvjezavanje|primarni
#
# Postoji zato sto se [System.Windows.Forms.Screen]::AllScreens u .NET Frameworku
# KESIRA po procesu - nakon promjene topologije isti proces vraca staro stanje.
# Zato ga pozivatelj pokrece kao SVJEZ proces svaki put.

Add-Type -AssemblyName System.Windows.Forms

$sig = @'
using System;using System.Runtime.InteropServices;
public class LD {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)]
 public struct DEVMODE {
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmDeviceName;
  public ushort dmSpecVersion,dmDriverVersion,dmSize,dmDriverExtra;
  public uint dmFields; public int dmPositionX,dmPositionY;
  public uint dmDisplayOrientation,dmDisplayFixedOutput;
  public short dmColor,dmDuplex,dmYResolution,dmTTOption,dmCollate;
  [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)] public string dmFormName;
  public ushort dmLogPixels; public uint dmBitsPerPel,dmPelsWidth,dmPelsHeight;
  public uint dmDisplayFlags,dmDisplayFrequency,dmICMMethod,dmICMIntent,dmMediaType;
  public uint dmDitherType,dmReserved1,dmReserved2,dmPanningWidth,dmPanningHeight;
 }
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettingsW(string d,int m,ref DEVMODE dm);
}
'@
if (-not ('LD' -as [type])) { Add-Type -TypeDefinition $sig }

foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  $dm = New-Object LD+DEVMODE
  $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'LD+DEVMODE')
  [LD]::EnumDisplaySettingsW($s.DeviceName, -1, [ref]$dm) | Out-Null
  # stvarne vrijednosti iz DEVMODE, ne DPI-virtualizirane iz Bounds
  '{0}|{1}|{2}|{3}|{4}' -f $s.DeviceName, $dm.dmPelsWidth, $dm.dmPelsHeight, $dm.dmDisplayFrequency, $s.Primary
}
