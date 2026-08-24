<#
    probe-session.ps1
    Snimi grafiku sliku ONE sesije u kojoj je pokrenuta, u datoteku.
    Namijenjeno pokretanju unutar RDP sesije, gdje se ponasanje razlikuje
    od konzolne sesije.

      .\probe-session.ps1
      .\probe-session.ps1 -Out C:\Users\Public\rdp_probe.txt
#>
[CmdletBinding()]
param([string]$Out = 'C:\Users\Public\session_probe.txt')

$here = $PSScriptRoot
$L = New-Object System.Collections.Generic.List[string]
function W($t){ $L.Add($t) }

W "===== SNIMKA SESIJE  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====="
W ""
W "--- sesija ---"
W "PID $PID  SessionId $((Get-Process -Id $PID).SessionId)"
((query user) 2>&1) | ForEach-Object { W "  $_" }

W ""
W "--- prikaceni displayi ---"
Add-Type -AssemblyName System.Windows.Forms
foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
  W ("  {0,-14} {1}x{2} @ {3},{4}  primary={5}" -f $s.DeviceName, $s.Bounds.Width, $s.Bounds.Height, $s.Bounds.X, $s.Bounds.Y, $s.Primary)
}

W ""
W "--- monitori ---"
Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -EA SilentlyContinue | ForEach-Object {
  W ("  " + (-join ($_.UserFriendlyName | Where-Object {$_ -ne 0} | ForEach-Object {[char]$_})))
}

W ""
W "--- PnP display ---"
Get-PnpDevice -Class Display -PresentOnly | ForEach-Object { W ("  {0,-8} {1}" -f $_.Status, $_.FriendlyName) }

W ""
W "--- IZVORNI OpenGL (sistemski opengl32.dll) ---"
try { (& "$here\glext.ps1") -split "`r?`n" | ForEach-Object { W "  $_" } }
catch { W "  GRESKA: $($_.Exception.Message)" }

W ""
W "--- VULKAN ---"
try { (& "$here\vulkantest.ps1") -split "`r?`n" | ForEach-Object { W "  $_" } }
catch { W "  GRESKA: $($_.Exception.Message)" }

W ""
W "--- Mesa OpenGL preko D3D12 (kontrola) ---"
try {
  $env:GALLIUM_DRIVER = 'd3d12'
  (& "$here\gltest.ps1" -MesaDir 'C:\Mesa\x64') -split "`r?`n" | ForEach-Object { W "  $_" }
} catch { W "  GRESKA: $($_.Exception.Message)" }

[System.IO.File]::WriteAllLines($Out, $L, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Snimljeno u: $Out" -ForegroundColor Green
Write-Host "Redaka: $($L.Count)"
