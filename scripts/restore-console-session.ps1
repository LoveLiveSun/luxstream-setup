<#
    restore-console-session.ps1

    Vrati odspojenu korisnicku sesiju na konzolu.

    ZASTO
      Windows 10 je single-session. RDP preuzme konzolnu sesiju; kad se RDP
      odspoji, sesija ostane u stanju "Disc" i NIJE na konzoli. VDD tada nema
      zivu sesiju, pa Sunshine hvata prazan ekran - Moonlight pokaze crno.

      Ova skripta vrati sesiju na konzolu i time oporavi streaming.

    UPOTREBA
      .\restore-console-session.ps1              # jednokratno
      .\restore-console-session.ps1 -Install     # zakazani zadatak na dogadaj
      .\restore-console-session.ps1 -Uninstall

    Zadatak se okida na Event ID 24 (session disconnected) iz loga
    Microsoft-Windows-TerminalServices-LocalSessionManager/Operational.
#>
[CmdletBinding()]
param([switch]$Install, [switch]$Uninstall, [int]$DelaySeconds = 5)

$taskName = 'RestoreConsoleSession'
$self     = $MyInvocation.MyCommand.Path

function Test-Elevated {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ------------------------------------------------------------------ UNINSTALL
if ($Uninstall) {
  if (-not (Test-Elevated)) { throw 'Pokreni kao administrator.' }
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Zadatak '$taskName' uklonjen." -ForegroundColor Green
  return
}

# -------------------------------------------------------------------- INSTALL
if ($Install) {
  if (-not (Test-Elevated)) { throw 'Pokreni kao administrator.' }

  $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
               -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`""
  $class   = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
  $trigger = $class | New-CimInstance -ClientOnly
  $trigger.Enabled      = $true
  $trigger.Subscription = @'
<QueryList><Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">
<Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">*[System[(EventID=24 or EventID=40)]]</Select>
</Query></QueryList>
'@
  $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null

  Write-Host "Zadatak '$taskName' registriran." -ForegroundColor Green
  Write-Host 'Okida se kad se sesija odspoji (RDP disconnect) i vraca je na konzolu.'
  return
}

# --------------------------------------------------------------------- RADNJA
# Okidac (EventID 24) opali u DVA razlicita slucaja:
#   a) netko se spojio na RDP  -> konzolna sesija se odspoji
#   b) netko je prekinuo RDP   -> RDP sesija se odspoji
# Vracati sesiju na konzolu smijemo SAMO u slucaju b). U slucaju a) bismo
# ukrali sesiju korisniku koji se upravo spojio i odmah ga izbacili.
#
# Razlika se vidi po tome postoji li IJEDNA aktivna sesija. Ako postoji, netko
# radi - ne diramo nista. Tek kad su sve sesije odspojene, vracamo na konzolu.

Start-Sleep -Seconds $DelaySeconds

# "query user" izlistava SAMO korisnicke sesije - "query session" ukljucuje i
# servisnu sesiju 0, koja je uvijek "Disc" i ne smije se dirati.
$raw = (query user) 2>&1 | Where-Object { $_ -match '\S' }

$sessions = @()
foreach ($l in ($raw | Select-Object -Skip 1)) {
  $line = $l -replace '^>', ' '
  if ($line -notmatch '^\s*(\S+)\s') { continue }
  $user = $matches[1]
  if ($line -notmatch '\s(\d+)\s+(Active|Disc\w*)\b') { continue }
  $sid = [int]$matches[1]
  if ($sid -eq 0) { continue }
  $sessions += [PSCustomObject]@{
    User      = $user
    Id        = $sid
    State     = $matches[2]
    OnConsole = ($line -match '\bconsole\b')
  }
}

if (-not $sessions) {
  Write-Host 'Nema korisnickih sesija - nista za raditi.'
  return
}

Write-Host 'Zatecene sesije:'
$sessions | ForEach-Object { Write-Host "  $($_.Id)  $($_.User)  $($_.State)  konzola=$($_.OnConsole)" }

$active = $sessions | Where-Object { $_.State -eq 'Active' }

if ($active) {
  # Netko upravo radi - na konzoli ili preko RDP-a. Ne diramo nista.
  $a = $active | Select-Object -First 1
  if ($a.OnConsole) {
    Write-Host "Sesija $($a.Id) ($($a.User)) je aktivna na konzoli - nista za raditi."
  } else {
    Write-Host "Sesija $($a.Id) ($($a.User)) je aktivna preko RDP-a - NE preuzimam je."
    Write-Host 'Konzola ce se vratiti sama kad se ta sesija odspoji.'
  }
  return
}

# Ovdje smo samo ako je SVE odspojeno - dakle RDP je prekinut.
$target = $sessions | Select-Object -First 1
Write-Host "Sve sesije odspojene -> vracam sesiju $($target.Id) ($($target.User)) na konzolu"
& tscon.exe $target.Id /dest:console 2>&1 | ForEach-Object { Write-Host "  $_" }

Start-Sleep -Seconds 3
Write-Host "`nStanje nakon vracanja:"
(query user) 2>&1 | ForEach-Object { Write-Host "  $_" }
