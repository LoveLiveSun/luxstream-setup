<#
    set-resolution-from-client.ps1

    Postavi rezoluciju primarnog displaya prema onome sto klijent trazi.

    ZASTO
      `dd_configuration_option` mora ostati `verify_only`, jer `ensure_active`
      ponovno aktivira Hyper-V display i time ponisti postavu s jednim zaslonom.
      Ali `verify_only` znaci da Sunshine ne dira ni rezoluciju.

      Sunshine prep naredbama predaje podatke o klijentu kroz varijable okoline,
      pa se rezolucija moze postaviti ovdje, bez diranja topologije.

    VARIJABLE koje Sunshine postavlja (src/process.cpp)
      SUNSHINE_CLIENT_WIDTH
      SUNSHINE_CLIENT_HEIGHT
      SUNSHINE_CLIENT_FPS

    UPOTREBA
      Upisuje se u sunshine.conf kao global_prep_cmd. Rucno:
        .\set-resolution-from-client.ps1 -Sirina 5120 -Visina 1440 -Fps 60
#>
[CmdletBinding()]
param(
  [int]$Sirina = 0,
  [int]$Visina = 0,
  [int]$Fps    = 0,
  [string]$LogPath = 'C:\Users\Public\set-resolution.log'
)

function Zapis($m) {
  $r = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m"
  Add-Content -Path $LogPath -Value $r -Encoding UTF8
  Write-Host $r
}

# varijable okoline imaju prednost pred parametrima
if ($env:SUNSHINE_CLIENT_WIDTH)  { $Sirina = [int]$env:SUNSHINE_CLIENT_WIDTH }
if ($env:SUNSHINE_CLIENT_HEIGHT) { $Visina = [int]$env:SUNSHINE_CLIENT_HEIGHT }
if ($env:SUNSHINE_CLIENT_FPS)    { $Fps    = [int]$env:SUNSHINE_CLIENT_FPS }

if ($Sirina -le 0 -or $Visina -le 0) {
  Zapis "preskacem - nema valjane rezolucije (sirina=$Sirina visina=$Visina)"
  return
}
if ($Fps -le 0) { $Fps = 60 }

$src = @'
using System;using System.Runtime.InteropServices;
public class SRC2 {
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
 [DllImport("user32.dll",CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettingsExW(string d,ref DEVMODE dm,IntPtr h,uint f,IntPtr p);
}
'@
if (-not ('SRC2' -as [type])) { Add-Type -TypeDefinition $src }
Add-Type -AssemblyName System.Windows.Forms

$cilj = ([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Primary }).DeviceName
$dm = New-Object SRC2+DEVMODE
$dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'SRC2+DEVMODE')
[SRC2]::EnumDisplaySettingsW($cilj, -1, [ref]$dm) | Out-Null

if ($dm.dmPelsWidth -eq $Sirina -and $dm.dmPelsHeight -eq $Visina -and $dm.dmDisplayFrequency -eq $Fps) {
  Zapis "vec je ${Sirina}x${Visina} @ ${Fps} Hz - nista za mijenjati"
  return
}

Zapis "trazim ${Sirina}x${Visina} @ ${Fps} Hz  (sada $($dm.dmPelsWidth)x$($dm.dmPelsHeight) @ $($dm.dmDisplayFrequency))"

$dm.dmPelsWidth = $Sirina
$dm.dmPelsHeight = $Visina
$dm.dmDisplayFrequency = $Fps
# DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY
$dm.dmFields = 0x00080000 -bor 0x00100000 -bor 0x00400000

# CDS_TEST prvo, da se ne rusi slika ako mod ne postoji
$test = [SRC2]::ChangeDisplaySettingsExW($cilj, [ref]$dm, [IntPtr]::Zero, 0x00000002, [IntPtr]::Zero)
if ($test -ne 0) {
  Zapis "  mod nije podrzan (test rc=$test) - probavam bez zadanog osvjezavanja"
  $dm.dmFields = 0x00080000 -bor 0x00100000
  $test = [SRC2]::ChangeDisplaySettingsExW($cilj, [ref]$dm, [IntPtr]::Zero, 0x00000002, [IntPtr]::Zero)
  if ($test -ne 0) {
    Zapis "  ni bez osvjezavanja (rc=$test) - ostavljam kako jest"
    return
  }
}

$rc = [SRC2]::ChangeDisplaySettingsExW($cilj, [ref]$dm, [IntPtr]::Zero, 0x00000001, [IntPtr]::Zero)
Start-Sleep -Seconds 2
$ck = New-Object SRC2+DEVMODE
$ck.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'SRC2+DEVMODE')
[SRC2]::EnumDisplaySettingsW($cilj, -1, [ref]$ck) | Out-Null
Zapis "  rc=$rc  ->  $($ck.dmPelsWidth)x$($ck.dmPelsHeight) @ $($ck.dmDisplayFrequency) Hz"
