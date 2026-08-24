<#
    02-sunshine-configure.ps1
    Otkriva GUID VDD monitora iz Sunshineovog loga i upisuje provjerenu konfiguraciju.

    GUID se racuna iz EDID-a i instance ID-a pa je RAZLICIT na svakom stroju.
    Zato se otkriva, a ne prepisuje iz dokumentacije.
#>
[CmdletBinding()]
param(
  [string]$SunshineDir = 'C:\Program Files\Sunshine',
  [string]$MonitorName = 'VDD by MTT',
  [ValidateSet('auto','manual','disabled')] [string]$ResolutionOption = 'auto',
  [string]$ManualResolution = '',
  [ValidateSet('ultrafast','superfast','veryfast','faster','fast','medium')] [string]$Preset = 'superfast'
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Pokreni kao administrator.'
}

$conf = Join-Path $SunshineDir 'config\sunshine.conf'
$log  = Join-Path $SunshineDir 'config\sunshine.log'
$state= Join-Path $SunshineDir 'config\display_device.state'

if (-not (Test-Path $SunshineDir)) { throw "Sunshine nije pronaden na $SunshineDir" }

# --- 1. Restart da Sunshine svjeze nabroji displaye u log -------------------
Write-Host 'Restartam Sunshine da nabroji displaye...'
Restart-Service SunshineService -Force
$deadline = (Get-Date).AddSeconds(90)
do {
  Start-Sleep -Seconds 3
  $ready = (Test-Path $log) -and (Select-String -Path $log -Pattern 'Currently available display devices' -Quiet -ErrorAction SilentlyContinue)
} until ($ready -or (Get-Date) -gt $deadline)
if (-not $ready) { throw 'Sunshine nije ispisao popis displayja. Provjeri servis.' }

# --- 2. Pronadi GUID monitora ----------------------------------------------
$lines = Get-Content $log
$guid  = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '"friendly_name"\s*:\s*"' + [regex]::Escape($MonitorName) + '"') {
    # device_id stoji nekoliko redaka iznad friendly_name
    for ($j = $i; $j -ge [math]::Max(0, $i - 12); $j--) {
      if ($lines[$j] -match '"device_id"\s*:\s*"(\{[0-9a-fA-F-]+\})"') { $guid = $Matches[1]; break }
    }
  }
  if ($guid) { break }
}

if (-not $guid) {
  Write-Host 'Nadeni displayi u logu:' -ForegroundColor Yellow
  Select-String -Path $log -Pattern '"friendly_name"|"device_id"' | Select-Object -Last 20 | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
  throw "Monitor '$MonitorName' nije pronaden. Provjeri je li VDD prikacen (01-vdd-configure.ps1)."
}
Write-Host "Pronaden monitor '$MonitorName' -> $guid" -ForegroundColor Green

# --- 3. Ocisti zapamceno stanje --------------------------------------------
# display_device.state pamti 'polaznu' rezoluciju i vraca se na nju nakon streama.
if (Test-Path $state) {
  Stop-Service SunshineService -Force
  Remove-Item $state -Force
  Write-Host 'Obrisan display_device.state (pamtio je staru polaznu rezoluciju).'
}

# --- 4. Upisi konfiguraciju -------------------------------------------------
if (Test-Path $conf) {
  $bak = "$conf.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
  Copy-Item $conf $bak -Force
  Write-Host "Backup: $bak"
}

$lines = @(
  'dd_configuration_option = ensure_only_display'
  "dd_resolution_option = $ResolutionOption"
)
if ($ResolutionOption -eq 'manual') {
  if (-not $ManualResolution) { throw 'Uz -ResolutionOption manual treba i -ManualResolution, npr. 3840x1080' }
  $lines += "dd_manual_resolution = $ManualResolution"
}
$lines += @(
  "output_name = $guid"
  'encoder = software'          # NVENC nad WARP uredajem rusi sunshine.exe (0xc0000409)
  "sw_preset = $Preset"
  'sw_tune = zerolatency'
)

# BEZ BOM-a. S BOM-om Sunshine prvi kljuc procita kao 'i>?dd_configuration_option' i ignorira ga.
[System.IO.File]::WriteAllLines($conf, $lines, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "`nUpisano: $conf" -ForegroundColor Green
Get-Content $conf | ForEach-Object { Write-Host "  $_" }

Start-Service SunshineService -ErrorAction SilentlyContinue
Write-Host "`nSada pokreni: .\03-verify.ps1" -ForegroundColor Yellow
