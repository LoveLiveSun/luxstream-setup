<#
    03-verify.ps1
    Zavrsna provjera: hvatanje radi, Sunshine je nasao enkoder, GPU je dostupan aplikacijama.
#>
[CmdletBinding()]
param([string]$SunshineDir = 'C:\Program Files\Sunshine')

$script:fail = 0
function Ok  ($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Bad ($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:fail++ }
function Head($m){ Write-Host "`n== $m" -ForegroundColor Cyan }

$log = Join-Path $SunshineDir 'config\sunshine.log'
$conf= Join-Path $SunshineDir 'config\sunshine.conf'

Head 'Displayi'
Add-Type -AssemblyName System.Windows.Forms
$screens = [System.Windows.Forms.Screen]::AllScreens
foreach ($s in $screens) {
  Ok "$($s.DeviceName)  $($s.Bounds.Width)x$($s.Bounds.Height)  primary=$($s.Primary)"
}
if (-not $screens) { Bad 'Nema prikacenih displayja' }

Head 'Konfiguracija bez BOM-a'
if (Test-Path $conf) {
  $b = [System.IO.File]::ReadAllBytes($conf)
  if ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) {
    Bad 'sunshine.conf ima UTF-8 BOM. Sunshine ce ignorirati prvi kljuc.'
  } else { Ok 'sunshine.conf je bez BOM-a' }
  Get-Content $conf | ForEach-Object { Write-Host "         $_" }
} else { Bad 'sunshine.conf ne postoji' }

Head 'Desktop Duplication'
$dd = Join-Path $PSScriptRoot 'ddtest.ps1'
if (Test-Path $dd) {
  $out = & $dd | Out-String
  Write-Host $out
  if ($out -match 'DUPLICATE OK') { Ok 'DuplicateOutput prolazi' }
  else { Bad 'DuplicateOutput pada na svim outputima. VDD je vjerojatno vezan na GPU umjesto na WARP.' }
} else { Warn "ddtest.ps1 nije pronaden pored ove skripte" }

Head 'Sunshine'
$svc = Get-Service SunshineService -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') { Ok 'Servis radi' } else { Bad 'Servis ne radi' }

if (Test-Path $log) {
  $L = Get-Content $log
  $dup   = ($L | Select-String 'DuplicateOutput').Count
  $fatal = ($L | Select-String 'Fatal').Count
  if ($dup   -eq 0) { Ok 'Nema DuplicateOutput gresaka u logu' } else { Bad "$dup DuplicateOutput gresaka u logu" }
  if ($fatal -eq 0) { Ok 'Nema Fatal gresaka u logu' }        else { Bad "$fatal Fatal gresaka u logu" }

  $enc = $L | Select-String 'Trying encoder' | Select-Object -Last 1
  if ($enc) { Ok "Zadnji enkoder: $($enc.Line -replace '.*Trying encoder ','')" }

  $sops = $L | Select-String 'Optimize game settings' | Select-Object -Last 1
  if ($sops) { Warn 'Klijent nema ukljucen "Optimize game settings" - Sunshine nece mijenjati rezoluciju.' }
} else { Bad 'sunshine.log ne postoji' }

Head 'GPU za aplikacije'
$wg = Join-Path $PSScriptRoot 'whichgpu.ps1'
if (Test-Path $wg) { & $wg | Out-String | Write-Host }
$prefs = Get-ItemProperty 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences' -ErrorAction SilentlyContinue
if ($prefs) {
  $n = ($prefs.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' }).Count
  Ok "$n aplikacija ima rucno postavljen GPU (GpuPreference=2 znaci High performance)"
} else {
  Warn 'Nijedna aplikacija nema postavljen High performance GPU. Dodaj ih u Settings > Display > Graphics.'
}

Head 'DPI'
$dpi = Get-ChildItem 'HKCU:\Control Panel\Desktop\PerMonitorSettings' -ErrorAction SilentlyContinue |
         ForEach-Object { (Get-ItemProperty $_.PSPath).DpiValue }
if ($null -ne $dpi) { Ok "DpiValue (relativno od preporucenog): $($dpi -join ', ')" }

Write-Host ''
if ($script:fail -eq 0) {
  Write-Host '== SVE PROVJERE PROSLE. Spoji se Moonlightom.' -ForegroundColor Green
  Write-Host '   Ne zaboravi u klijentu: Optimize game settings = ukljuceno.'
  Write-Host '   Bitrate: ukljuci "Unlock bitrate" pa postavi 500 Mbps (500000 kbps).'
  exit 0
} else {
  Write-Host "== $($script:fail) PROVJERA NIJE PROSLA. Vidi tablicu simptoma u README.md" -ForegroundColor Red
  exit 1
}
