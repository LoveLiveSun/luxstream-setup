<#
    verify-after-boot.ps1

    Snimi stanje postave nakon ponovnog pokretanja u datoteku, da se nalaz moze
    procitati kasnije. Postoji zato sto Claude Code radi na ovom istom VM-u, pa
    restart prekida i njegovu sesiju - test se mora sam zabiljeziti.

    Registrira se da se izvrsi jednom pri prijavi, s odgodom da se sve slegne.
#>
[CmdletBinding()]
param([switch]$Install, [switch]$Uninstall, [int]$DelaySeconds = 100)

$taskName = 'VerifyAfterBoot'
$self     = $MyInvocation.MyCommand.Path
$out      = 'C:\Users\Public\boot-verify.txt'

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Zadatak '$taskName' uklonjen."; return
}

if ($Install) {
  $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`""
  $trigger   = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                 -LogonType Interactive -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings -Force | Out-Null
  Write-Host "Zadatak '$taskName' registriran - jednom pri prijavi."
  return
}

# --------------------------------------------------------------------- RADNJA
Start-Sleep -Seconds $DelaySeconds
Add-Type -AssemblyName System.Windows.Forms
$scripts = 'C:\Users\Public\sunshine-gpup-setup\scripts'
$L = 'C:\Program Files\Sunshine\config\sunshine.log'
$r = New-Object System.Collections.Generic.List[string]
function W($m) { $r.Add($m) }

W "===== NALAZ NAKON PONOVNOG POKRETANJA ====="
W "vrijeme    : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
W "uptime     : $([int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMinutes) min"
W ''

W '--- 1. SESIJA ---'
((query user) 2>&1) | ForEach-Object { W "  $_" }
W ''

W '--- 2. DISPLAYI ---'
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  W ("  {0,-14} primary={1,-5} {2}x{3} @ {4},{5}" -f $s.DeviceName, $s.Primary,
      $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y)
}
W "  ukupno: $([System.Windows.Forms.Screen]::AllScreens.Count)   (treba 2 - Hyper-V ostaje aktivan, inace Vulkan/OpenGL ne prezive)"
W ''

W '--- 3. VDD NA KOJI GPU ---'
try {
  $x = [xml](Get-Content 'C:\VirtualDisplayDriver\vdd_settings.xml')
  W "  vdd_settings.xml : $($x.vdd_settings.gpu.friendlyname)"
} catch { W "  greska citanja xml-a: $_" }
W ''

W '--- 3b. PRIMING ---'
W "  marker: $(if (Test-Path 'C:\Users\Public\streamready-primed.txt') { (Get-Content 'C:\Users\Public\streamready-primed.txt' -Raw).Trim() } else { 'NEMA - priming se nije izvrsio' })"
W "  Hyper-V adapter: $((Get-PnpDevice -FriendlyName 'Microsoft Hyper-V Video' -ErrorAction SilentlyContinue).Status)"
W ''
W '--- 4. ZADACI ---'
foreach ($n in 'SunshineUser','StreamReady','RestoreConsoleSession') {
  $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
  $i = Get-ScheduledTaskInfo -TaskName $n -ErrorAction SilentlyContinue
  if ($t) { W ("  {0,-22} {1,-9} zadnji rezultat 0x{2:X}" -f $n, $t.State, $i.LastTaskResult) }
  else    { W "  $n  NE POSTOJI" }
}
W "  SunshineService : $((Get-Service SunshineService -ErrorAction SilentlyContinue).StartType)"
W ''

W '--- 5. SUNSHINE ---'
$p = Get-Process sunshine -ErrorAction SilentlyContinue
if ($p) {
  W "  proces  : PID $($p.Id), sesija $($p.SessionId), RAM $([int]($p.WorkingSet64/1MB)) MB"
  $ports = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
             Where-Object { $_.LocalPort -in 47984,47989,47990,48010 }
  W "  portovi : $(($ports.LocalPort | Sort-Object) -join ', ')"
} else { W '  NE RADI' }
if (Test-Path $L) {
  W "  capture      : $((Select-String -Path $L -Pattern ""config: 'capture'"" | Select-Object -Last 1).Line)"
  W "  enkoder      : $((Select-String -Path $L -Pattern 'Found .* encoder' | Select-Object -Last 1).Line)"
  W "  DuplicateOutput: $((Select-String -Path $L -Pattern 'DuplicateOutput').Count)   Fatal: $((Select-String -Path $L -Pattern 'Fatal').Count)"
}
W ''

W '--- 6. GRAFIKA ---'
foreach ($t in @(@{n='VULKAN';f='vulkantest.ps1'}, @{n='OPENGL';f='gltest.ps1'})) {
  W "  [$($t.n)]"
  try { (& "$scripts\$($t.f)" 2>&1) | ForEach-Object { W "    $_" } }
  catch { W "    greska: $_" }
}
W ''

W '--- 7. PADOVI OD PODIZANJA ---'
$boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
$cr = Get-WinEvent -FilterHashtable @{LogName='Application'; ProviderName='Application Error'; StartTime=$boot} -ErrorAction SilentlyContinue |
        Where-Object { $_.Message -match 'Sunshine\.exe|Cemu\.exe' }
if ($cr) { W "  PADOVA: $($cr.Count)"; $cr | Select-Object -First 5 | ForEach-Object { W "    $($_.TimeCreated)" } }
else { W '  nema padova' }

[System.IO.File]::WriteAllLines($out, $r, (New-Object System.Text.UTF8Encoding($false)))
