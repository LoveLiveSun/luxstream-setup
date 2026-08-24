<#
    disable-gamebar-prompt.ps1

    Uklanja dijalog "You'll need a new app to open this ms-gamingoverlay link"
    koji nudi Microsoft Store pri pokretanju igara i DirectX aplikacija.

    UZROK
      Igre i DirectX aplikacije pozivaju Xbox Game Bar preko protokola ms-gamingoverlay.
      Windows 10 LTSC nema Store aplikacije, pa taj protokol nema registriranog rukovatelja
      i Windows ponudi Store. Nije kvar - LTSC jednostavno nema Game Bar.

    RJESENJE
      Ugasiti GameDVR da ga aplikacije uopce ne pozivaju.

    POVRATAK
      Sve vrijednosti natrag na 1, ili uvezi backup .reg koji skripta napravi.
#>
[CmdletBinding()]
param(
  [string]$BackupDir = 'C:\Users\Public',
  [switch]$Revert
)

$val = if ($Revert) { 1 } else { 0 }
$what = if ($Revert) { 'VRACAM' } else { 'GASIM' }
Write-Host "$what GameDVR / Game Bar prompt`n" -ForegroundColor Cyan

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $Revert) {
  $bak = Join-Path $BackupDir "gamedvr-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss').reg"
  reg export 'HKCU\System\GameConfigStore' $bak /y 2>&1 | Out-Null
  Write-Host "Backup: $bak"
}

# --- korisnicka razina -------------------------------------------------------
$userKeys = @(
  @{ Path='HKCU:\System\GameConfigStore';                                  Name='GameDVR_Enabled' }
  @{ Path='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR';       Name='AppCaptureEnabled' }
  @{ Path='HKCU:\SOFTWARE\Microsoft\GameBar';                              Name='ShowStartupPanel' }
  @{ Path='HKCU:\SOFTWARE\Microsoft\GameBar';                              Name='UseNexusForGameBarEnabled' }
)
foreach ($k in $userKeys) {
  New-Item -Path $k.Path -Force | Out-Null
  Set-ItemProperty -Path $k.Path -Name $k.Name -Value $val -Type DWord
  Write-Host "  [OK]   $($k.Name) = $val" -ForegroundColor Green
}

# --- strojna politika (treba elevaciju) --------------------------------------
$pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
if ($elevated) {
  try {
    if ($Revert) {
      if (Test-Path $pol) { Remove-Item $pol -Recurse -Force; Write-Host '  [OK]   politika AllowGameDVR uklonjena' -ForegroundColor Green }
    } else {
      New-Item -Path $pol -Force | Out-Null
      Set-ItemProperty -Path $pol -Name 'AllowGameDVR' -Value 0 -Type DWord
      Write-Host '  [OK]   AllowGameDVR = 0 (machine policy)' -ForegroundColor Green
    }
  } catch {
    Write-Host "  [!]    politika nije postavljena: $($_.Exception.Message)" -ForegroundColor Yellow
  }
} else {
  Write-Host '  [!]    Preskacem strojnu politiku - treba elevated PowerShell.' -ForegroundColor Yellow
  Write-Host '         Korisnicke postavke su obicno dovoljne. Za potpuno gasenje pokreni kao admin.'
}

Write-Host "`nThe change applies to NEWLY started applications." -ForegroundColor Cyan
Write-Host 'Close and reopen anything already running.'
