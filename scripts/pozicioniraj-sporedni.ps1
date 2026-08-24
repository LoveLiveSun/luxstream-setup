<#
    pozicioniraj-sporedni.ps1

    Postavi sporedni (Hyper-V) zaslon DOLJE-DESNO od glavnog.

    ZASTO
      Hyper-V display mora ostati aktivan - bez njega izvorni Vulkan i OpenGL ne
      prezive (izmjereno 23.8.2026.). Ali gdje stoji, to je bitno:

      Windows slaze ikone radne povrsine od gornjeg LIJEVOG kuta VIRTUALNOG
      desktopa. Dok je sporedni stajao na (-640,720), ishodiste virtualnog
      desktopa bilo je (-640,0) - dakle NA NJEMU - pa je svaka nova mapa
      zavrsavala ondje.

      Uz to su zasloni dijelili rub x=0 na visini 720-1200, pa je mis mogao
      prijeci kroz taj uski pojas.

    RJESENJE
      Sporedni ide na (glavni.desno, glavni.dolje), dakle dijagonalno dolje-desno.
      Tada:
        - ishodiste virtualnog desktopa postaje (0,0), gornji lijevi kut glavnog
          zaslona, pa nove ikone ostaju na glavnom
        - zasloni se dodiruju SAMO U TOCKI, bez zajednickog ruba, pa mis ne moze
          prijeci
        - prozor ondje moze zavrsiti samo ako ga netko namjerno posalje

    IDEMPOTENTNO - ako je vec na mjestu, ne dira nista.

    UPOTREBA
      .\pozicioniraj-sporedni.ps1
      .\pozicioniraj-sporedni.ps1 -Quiet    # za zakazani zadatak
#>
[CmdletBinding()]
param([switch]$Quiet)

Add-Type -AssemblyName System.Windows.Forms
function Reci($m) { if (-not $Quiet) { Write-Host $m } }

$sig = @'
using System;using System.Runtime.InteropServices;
public class POZ {
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
 [DllImport("user32.dll")] public static extern int ChangeDisplaySettingsW(IntPtr dm,uint f);
}
'@
if (-not ('POZ' -as [type])) { Add-Type -TypeDefinition $sig }

$svi      = [System.Windows.Forms.Screen]::AllScreens
$glavni   = $svi | Where-Object { $_.Primary } | Select-Object -First 1
$sporedni = @($svi | Where-Object { -not $_.Primary })

if (-not $sporedni.Count) { Reci '  Nema sporednog zaslona.'; return }
if (-not $glavni)         { Reci '  Nema glavnog zaslona?!'; return }

# dijagonalno dolje-desno od glavnog: dodir samo u tocki
$ciljX = $glavni.Bounds.Right
$ciljY = $glavni.Bounds.Bottom

# NE trazi tocnu poziciju nego PRIHVATLJIVU. Ciljna tocka ovisi o rezoluciji
# glavnog zaslona, a nju Sunshine mijenja po klijentu - pa bi inace skripta
# premjestala zaslon pri SVAKOJ promjeni rezolucije. Svaka takva promjena
# topologije je rizik za ICD, i to bez ikakve koristi.
#
# Prihvatljivo je sve sto zadovoljava oboje:
#   X >= desni rub glavnog   I   Y >= donji rub glavnog
# Time je sporedni desno-dolje, ishodiste virtualnog desktopa ostaje (0,0),
# a zasloni se u najgorem slucaju dodiruju u jednoj tocki - mis ne prelazi.
function Prihvatljivo($b) { return ($b.X -ge $ciljX -and $b.Y -ge $ciljY) }

foreach ($s in $sporedni) {
  if (Prihvatljivo $s.Bounds) {
    Reci "  $($s.DeviceName) je na ($($s.Bounds.X),$($s.Bounds.Y)) - desno i ispod glavnog, u redu."
    continue
  }

  $dm = New-Object POZ+DEVMODE
  $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'POZ+DEVMODE')
  if (-not [POZ]::EnumDisplaySettingsW($s.DeviceName, -1, [ref]$dm)) {
    Reci "  ne mogu procitati postavke za $($s.DeviceName)"
    continue
  }

  $dm.dmPositionX = $ciljX
  $dm.dmPositionY = $ciljY
  $dm.dmFields = 0x00000020   # DM_POSITION

  # CDS_UPDATEREGISTRY | CDS_NORESET, pa jedna primjena na kraju
  $rc = [POZ]::ChangeDisplaySettingsExW($s.DeviceName, [ref]$dm, [IntPtr]::Zero, (0x00000001 -bor 0x10000000), [IntPtr]::Zero)
  Reci "  $($s.DeviceName): ($($s.Bounds.X),$($s.Bounds.Y)) -> ($ciljX,$ciljY)   rc=$rc"
}

$rc2 = [POZ]::ChangeDisplaySettingsW([IntPtr]::Zero, 0)
Reci "  primjena rc=$rc2"
Start-Sleep -Seconds 3

$v = [System.Windows.Forms.SystemInformation]::VirtualScreen
Reci ''
Reci "  virtualni desktop: ishodiste ($($v.X),$($v.Y))   $($v.Width)x$($v.Height)"
if ($v.X -eq 0 -and $v.Y -eq 0) { Reci '  ishodiste je na glavnom zaslonu - nove ikone ostaju kod tebe.' }
else { Reci '  UPOZORENJE: ishodiste jos nije (0,0) - ikone i dalje mogu odlutati.' }
