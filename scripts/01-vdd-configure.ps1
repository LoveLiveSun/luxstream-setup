<#
    01-vdd-configure.ps1
    Upisuje provjerenu VDD konfiguraciju i restarta driver.

    SRZ RJESENJA: <friendlyname>Microsoft Basic Render Driver</friendlyname>
    Na GPU-P adapteru Desktop Duplication pada s E_INVALIDARG. Na WARP-u radi.
#>
[CmdletBinding()]
param(
  [string]$VddPath = 'C:\VirtualDisplayDriver',
  [string]$Gpu     = 'Microsoft Basic Render Driver',
  [int]$MonitorCount = 1,
  [switch]$EnableLogging
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Pokreni kao administrator.'
}

$xmlPath = Join-Path $VddPath 'vdd_settings.xml'
if (-not (Test-Path $VddPath)) { throw "VDD nije pronaden na $VddPath" }

# Rezolucije. NAMJERNO bez 800x600 i 1366x768 - Windows pada na najnizi ponudeni mod.
# Napomena: ovo NIJE tvrda granica. Sunshine uz dd_resolution_option = auto zna postaviti
# i mod koji nije na popisu (npr. 4096x1152). Popis odreduje sto Windows nudi u Settings UI-ju
# i na sto pada kad nema boljeg.
$resolutions = @(
  @(1280, 720), @(1600, 900), @(1920,1080), @(1920,1200), @(2560,1440),
  @(2560,1600), @(3440,1440), @(3840,1080), @(4096,1152), @(3840,2160), @(5120,1440)
)
$refreshRates = @(60, 90, 120, 144, 165, 244)

if (Test-Path $xmlPath) {
  $bak = "$xmlPath.$(Get-Date -Format 'yyyyMMdd-HHmmss').bak"
  Copy-Item $xmlPath $bak -Force
  Write-Host "Backup: $bak"
}

$resBlocks = ($resolutions | ForEach-Object {
@"
    <resolution>
      <width>$($_[0])</width>
      <height>$($_[1])</height>
      <refresh_rate>30</refresh_rate>
    </resolution>
"@
}) -join "`r`n"

$rrBlocks = ($refreshRates | ForEach-Object { "    <g_refresh_rate>$_</g_refresh_rate>" }) -join "`r`n"
$logFlag  = if ($EnableLogging) { 'true' } else { 'false' }

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<vdd_settings>
  <monitors>
    <count>$MonitorCount</count>
  </monitors>
  <gpu>
    <friendlyname>$Gpu</friendlyname>
  </gpu>
  <global>
$rrBlocks
  </global>
  <resolutions>
$resBlocks
  </resolutions>
  <options>
    <CustomEdid>false</CustomEdid>
    <PreventSpoof>false</PreventSpoof>
    <EdidCeaOverride>false</EdidCeaOverride>
    <HardwareCursor>true</HardwareCursor>
    <SDR10bit>false</SDR10bit>
    <HDRPlus>false</HDRPlus>
    <logging>$logFlag</logging>
    <debuglogging>false</debuglogging>
  </options>
</vdd_settings>
"@

# BEZ BOM-a. VDD i Sunshine krivo citaju datoteke s BOM-om.
[System.IO.File]::WriteAllText($xmlPath, $xml, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Upisano: $xmlPath" -ForegroundColor Green
Write-Host "  GPU     : $Gpu"
Write-Host "  Monitora: $MonitorCount"
Write-Host "  Najniza : $($resolutions[0][0])x$($resolutions[0][1])"

Write-Host "`nRestartam VDD driver..."
$dev = Get-PnpDevice -InstanceId 'ROOT\DISPLAY\0000'
Disable-PnpDevice -InstanceId $dev.InstanceId -Confirm:$false
Start-Sleep -Seconds 5
Enable-PnpDevice  -InstanceId $dev.InstanceId -Confirm:$false
Start-Sleep -Seconds 16

Add-Type -AssemblyName System.Windows.Forms
Write-Host "`nPrikaceni displayi:" -ForegroundColor Cyan
[System.Windows.Forms.Screen]::AllScreens |
  Select-Object DeviceName, Primary, @{n='Res';e={"$($_.Bounds.Width)x$($_.Bounds.Height)"}} |
  Format-Table -AutoSize | Out-String -Width 120 | Write-Host

Write-Host 'Sada pokreni: .\ddtest.ps1  (mora javiti *** DUPLICATE OK *** za VDD)' -ForegroundColor Yellow
