<#
    set-dpi-100.ps1
    Postavlja DPI skaliranje na 100% bez odjave i bez GUI-ja.

    Windows na sirokim rezolucijama sam preporuci 200% skaliranje. Tada radna povrsina
    5120x1440 postane upotrebljivih 2560x720 razvucenih preko cijelog ekrana - tipican
    simptom "slika izgleda kao manja rezolucija razvucena preko vece".

    SPI_SETLOGICALDPIOVERRIDE prima RELATIVNI pomak od preporucenog, ne apsolutni postotak.
    Ljestvica: 100, 125, 150, 175, 200, 225, 250, 300 ...
    Ako je preporuceno 200%, onda je -4 jednako 100%.
#>
[CmdletBinding()]
param(
  [int]$RelativeSteps = -4   # 0 = preporuceno, -1 jedan korak nize, itd.
)

$sig = @'
using System;
using System.Runtime.InteropServices;
public class DpiOverride {
  [DllImport("user32.dll", SetLastError=true)]
  public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
}
'@
if (-not ('DpiOverride' -as [type])) { Add-Type -TypeDefinition $sig }

Add-Type -AssemblyName System.Windows.Forms
$before = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host "Before: $($before.Width)x$($before.Height)"

$SPI_SETLOGICALDPIOVERRIDE = 0x009F
$SPIF = 0x01 -bor 0x02        # SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
$param = [uint32]([BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$RelativeSteps), 0))

$ok = [DpiOverride]::SystemParametersInfo($SPI_SETLOGICALDPIOVERRIDE, $param, [IntPtr]::Zero, $SPIF)
Write-Host "SystemParametersInfo($RelativeSteps) -> $ok"
Start-Sleep -Seconds 3

$after = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
Write-Host "After: $($after.Width)x$($after.Height)"

if ($after.Width -gt $before.Width) {
  Write-Host 'DPI smanjen, radna povrsina je veca.' -ForegroundColor Green
} elseif ($after.Width -eq $before.Width) {
  Write-Host 'No change. It may already be at the requested value.' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Note: already-open applications may stay blurry until restarted.'
Write-Host 'If 100% is too small to work with, try -RelativeSteps -3 (125%) or -2 (150%).'
Write-Host 'Back to the Windows recommendation: -RelativeSteps 0'
