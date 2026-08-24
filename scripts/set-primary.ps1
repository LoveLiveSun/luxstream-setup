# Postavlja zadani display kao primarni preko ChangeDisplaySettingsEx.
# Ne prikazuje "Keep these display settings?" dijalog jer ne mijenja mod, samo poziciju/primarnost.
# Upotreba:  .\set-primary.ps1 -Target '\\.\DISPLAY3'
param(
  [Parameter(Mandatory=$true)][string]$Target
)

$sig = @'
using System;
using System.Runtime.InteropServices;

public class DispApi {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion; public short dmDriverVersion; public short dmSize; public short dmDriverExtra;
    public int dmFields; public int dmPositionX; public int dmPositionY;
    public int dmDisplayOrientation; public int dmDisplayFixedOutput;
    public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel; public int dmPelsWidth; public int dmPelsHeight;
    public int dmDisplayFlags; public int dmDisplayFrequency; public int dmICMMethod; public int dmICMIntent;
    public int dmMediaType; public int dmDitherType; public int dmReserved1; public int dmReserved2;
    public int dmPanningWidth; public int dmPanningHeight;
  }

  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=128)] public string DeviceKey;
  }

  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern bool EnumDisplayDevicesA(string dev, int devNum, ref DISPLAY_DEVICE d, int flags);

  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern bool EnumDisplaySettingsA(string dev, int mode, ref DEVMODE dm);

  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern int ChangeDisplaySettingsExA(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr param);

  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern int ChangeDisplaySettingsExA(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr param);
}
'@
if (-not ('DispApi' -as [type])) { Add-Type -TypeDefinition $sig }

$ENUM_CURRENT_SETTINGS = -1
$CDS_UPDATEREGISTRY    = 0x00000001
$CDS_NORESET           = 0x10000000
$CDS_SET_PRIMARY       = 0x00000010
$DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 0x00000001

# 1. Popis prikacenih displaya (Screen::AllScreens je pouzdaniji od EnumDisplayDevices u ovoj sesiji)
Add-Type -AssemblyName System.Windows.Forms
$attached = [System.Windows.Forms.Screen]::AllScreens | ForEach-Object { $_.DeviceName.Trim() }

if ($attached -notcontains $Target) {
  throw "Ciljni display '$Target' nije prikacen na desktop. Prikaceni: $($attached -join ', ')"
}

# 2. Trenutni modovi
$modes = @{}
foreach ($d in $attached) {
  $dm = New-Object DispApi+DEVMODE
  $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
  if ([DispApi]::EnumDisplaySettingsA($d, $ENUM_CURRENT_SETTINGS, [ref]$dm)) { $modes[$d] = $dm }
}

$offsetX = $modes[$Target].dmPositionX
$offsetY = $modes[$Target].dmPositionY
Write-Output "Pomak svih displaya za (-$offsetX, -$offsetY) da '$Target' dodje na 0,0"

# 3. Upisi nove pozicije, bez primjene (CDS_NORESET)
$DM_POSITION = 0x00000020
foreach ($d in $attached) {
  $dm = $modes[$d]
  $dm.dmPositionX = $dm.dmPositionX - $offsetX
  $dm.dmPositionY = $dm.dmPositionY - $offsetY
  $dm.dmFields    = $DM_POSITION

  $flags = $CDS_UPDATEREGISTRY -bor $CDS_NORESET
  if ($d -eq $Target) { $flags = $flags -bor $CDS_SET_PRIMARY }

  $r = [DispApi]::ChangeDisplaySettingsExA($d, [ref]$dm, [IntPtr]::Zero, $flags, [IntPtr]::Zero)
  Write-Output ("  {0,-14} -> ({1},{2})  rc={3}" -f $d, $dm.dmPositionX, $dm.dmPositionY, $r)
}

# 4. Primijeni sve odjednom
$rc = [DispApi]::ChangeDisplaySettingsExA($null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
Write-Output "Primjena: rc=$rc  (0 = DISP_CHANGE_SUCCESSFUL)"
exit $rc
