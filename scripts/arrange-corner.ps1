<#
    arrange-corner.ps1
    Postavi sekundarni display DIJAGONALNO od primarnog, tako da se dodiruju
    samo u jednoj tocki (kutu). Mis tada prakticki ne moze prijeci na njega,
    a display ostaje prikacen.

    Zasto je to korisno u GPU-P gostu:
      NVIDIA-in Vulkan ICD prijavi 0 uredaja ako NVIDIA adapter nema nijedan
      prikacen display. Hyper-V monitor je taj display. Mora ostati prikacen,
      ali ne mora smetati.

      .\arrange-corner.ps1                          # automatski nade sekundarni
      .\arrange-corner.ps1 -Secondary \\.\DISPLAY8
      .\arrange-corner.ps1 -Restore                 # vrati desno od primarnog
#>
[CmdletBinding()]
param([string]$Secondary, [switch]$Restore)

$sig = @'
using System;
using System.Runtime.InteropServices;
public class ARR {
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Ansi)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public int dmFields, dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels;
    public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern bool EnumDisplaySettingsA(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern int ChangeDisplaySettingsExA(string dev, ref DEVMODE dm, IntPtr hwnd, int flags, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Ansi)]
  public static extern int ChangeDisplaySettingsExA(string dev, IntPtr dm, IntPtr hwnd, int flags, IntPtr p);
  [DllImport("user32.dll")]
  public static extern int ChangeDisplaySettingsA(IntPtr dm, int flags);
}
'@
if (-not ('ARR' -as [type])) { Add-Type -TypeDefinition $sig }

Add-Type -AssemblyName System.Windows.Forms
$screens = [System.Windows.Forms.Screen]::AllScreens
$primary = $screens | Where-Object Primary | Select-Object -First 1
if (-not $primary) { throw 'Nema primarnog displaya.' }

if (-not $Secondary) {
  $sec = $screens | Where-Object { -not $_.Primary } | Select-Object -First 1
  if (-not $sec) { throw 'Nema sekundarnog displaya - je li Hyper-V monitor prikacen?' }
  $Secondary = $sec.DeviceName
}
Write-Host "Primarni  : $($primary.DeviceName)  $($primary.Bounds.Width)x$($primary.Bounds.Height)"
Write-Host "Sekundarni: $Secondary"

$dm = New-Object ARR+DEVMODE
$dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
if (-not [ARR]::EnumDisplaySettingsA($Secondary, -1, [ref]$dm)) { throw "Ne mogu procitati $Secondary" }

if ($Restore) {
  $nx = $primary.Bounds.Width; $ny = 0
  Write-Host "Vracam desno od primarnog -> ($nx,$ny)"
} else {
  # dijagonalno: dodir samo u donjem desnom kutu primarnog
  $nx = $primary.Bounds.Width
  $ny = $primary.Bounds.Height
  Write-Host "Dijagonalno, dodir samo u kutu -> ($nx,$ny)"
}

$DM_POSITION = 0x00000020
$dm.dmPositionX = $nx; $dm.dmPositionY = $ny
$dm.dmFields = $DM_POSITION

$CDS_UPDATEREGISTRY = 0x00000001
$CDS_NORESET        = 0x10000000
$r = [ARR]::ChangeDisplaySettingsExA($Secondary, [ref]$dm, [IntPtr]::Zero, ($CDS_UPDATEREGISTRY -bor $CDS_NORESET), [IntPtr]::Zero)
Write-Host "  upis rc=$r"

$rc = [ARR]::ChangeDisplaySettingsA([IntPtr]::Zero, 0)
Write-Host "  primjena rc=$rc  (0 = uspjeh)"

Start-Sleep -Seconds 3
[System.Windows.Forms.Screen]::AllScreens |
  Select-Object DeviceName, Primary, @{n='Pos';e={"$($_.Bounds.Width)x$($_.Bounds.Height) @ $($_.Bounds.X),$($_.Bounds.Y)"}} |
  Format-Table -AutoSize | Out-String -Width 100 | Write-Host
