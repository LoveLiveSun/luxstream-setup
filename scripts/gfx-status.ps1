<#
    gfx-status.ps1
    Jedna naredba koja ispise cijelu grafiku sliku GPU-P gosta:
      D3D11, D3D12, OpenGL preko d3d12, OpenGL preko llvmpipe, Vulkan preko Dozena.

    Za tocan rezultat treba High performance GPU za powershell.exe - skripta ga
    postavi privremeno i na kraju vrati kako je bilo.

      .\gfx-status.ps1
      .\gfx-status.ps1 -MesaDir C:\Mesa\x64
#>
[CmdletBinding()]
param([string]$MesaDir = 'C:\Mesa\x64')

$here = $PSScriptRoot
function Head($m){ Write-Host "`n===== $m" -ForegroundColor Cyan }

# --- privremeni High performance za powershell.exe ---------------------------
$prefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$psPath  = (Get-Process -Id $PID).Path
$hadPref = $null
if (Test-Path $prefKey) { $hadPref = (Get-ItemProperty $prefKey -ErrorAction SilentlyContinue).$psPath }
New-Item -Path $prefKey -Force | Out-Null
Set-ItemProperty -Path $prefKey -Name $psPath -Value 'GpuPreference=2;'

function RunChild([string]$cmd) {
  $out = [System.IO.Path]::GetTempFileName()
  $err = [System.IO.Path]::GetTempFileName()
  Start-Process -FilePath $psPath -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd `
    -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -Wait
  $t = (Get-Content $out -Raw -ErrorAction SilentlyContinue)
  $e = (Get-Content $err -Raw -ErrorAction SilentlyContinue)
  Remove-Item $out,$err -Force -ErrorAction SilentlyContinue
  [PSCustomObject]@{ Out = $t; Err = $e }
}

try {
  Head 'GPU uredaji (PnP)'
  Get-PnpDevice -Class Display -PresentOnly | Select-Object Status,FriendlyName |
    Format-Table -AutoSize | Out-String -Width 120 | Write-Host

  Head 'Kernel driver'
  $nv = Get-Service -Name 'nvlddmkm' -ErrorAction SilentlyContinue
  Write-Host ("  nvlddmkm : {0}" -f $(if($nv){'postoji'}else{'NE POSTOJI (ocekivano na GPU-P)'}))
  $svc = (Get-PnpDevice -Class Display -PresentOnly | Where-Object FriendlyName -match 'NVIDIA' |
          ForEach-Object { (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Service' -EA SilentlyContinue).Data })
  if ($svc) { Write-Host "  GPU vozi : $svc" }

  Head 'Desktop Duplication (za Sunshine)'
  if (Test-Path (Join-Path $here 'ddtest.ps1')) {
    (& (Join-Path $here 'ddtest.ps1')) | Select-String 'ADAPTER|DUPLICATE|nema outputa' | ForEach-Object { Write-Host "  $($_.Line.Trim())" }
  }

  Head 'D3D12 po adapteru'
  if (Test-Path (Join-Path $here 'd3d12features.ps1')) {
    (& (Join-Path $here 'd3d12features.ps1')) | ForEach-Object { Write-Host "  $_" }
  }

  Head 'OpenGL preko D3D12 (hardverski)'
  $r = RunChild "`$env:GALLIUM_DRIVER='d3d12'; & '$here\gltest.ps1' -MesaDir '$MesaDir'"
  if ($r.Out) { ($r.Out -split "`r?`n") | Where-Object { $_ -match 'GL_|Ucitan|FAILED' } | ForEach-Object { Write-Host "  $_" } }
  else { Write-Host '  (nema izlaza - je li Mesa u '"$MesaDir"'?)' -ForegroundColor Yellow }

  Head 'OpenGL preko llvmpipe (softverski)'
  $r = RunChild "`$env:GALLIUM_DRIVER='llvmpipe'; & '$here\gltest.ps1' -MesaDir '$MesaDir'"
  if ($r.Out) { ($r.Out -split "`r?`n") | Where-Object { $_ -match 'GL_|FAILED' } | ForEach-Object { Write-Host "  $_" } }

  Head 'Kljucne GL ekstenzije (d3d12)'
  $r = RunChild "`$env:GALLIUM_DRIVER='d3d12'; & '$here\glext.ps1' -MesaDir '$MesaDir'"
  if ($r.Out) { ($r.Out -split "`r?`n") | Where-Object { $_ -match 'ekstenzija|texture_view|compute_shader|storage_buffer|direct_state|GL_VERSION' } | ForEach-Object { Write-Host "  $_" } }

  Head 'Vulkan'
  $dm = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
  Write-Host ("  Developer Mode : {0}" -f $(if($dm -eq 1){'ukljucen'}else{'ISKLJUCEN - Dozen nece raditi'}))
  $icd = Get-Item 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers' -ErrorAction SilentlyContinue
  if ($icd) { $icd.GetValueNames() | ForEach-Object { Write-Host "  ICD            : $_" } }
  else { Write-Host '  ICD            : nijedan registriran' -ForegroundColor Yellow }
  Write-Host ("  dxil.dll       : {0}" -f $(if(Test-Path 'C:\Windows\System32\dxil.dll'){'u System32'}else{'nema u System32 - Dozen ga mozda nece naci'}))
  $r = RunChild "`$env:DZN_DEBUG='experimental'; & '$here\vulkantest.ps1'"
  if ($r.Out) { ($r.Out -split "`r?`n") | Where-Object { $_ -match '\S' } | ForEach-Object { Write-Host "  $_" } }
}
finally {
  if ($null -ne $hadPref) { Set-ItemProperty -Path $prefKey -Name $psPath -Value $hadPref }
  else { Remove-ItemProperty -Path $prefKey -Name $psPath -ErrorAction SilentlyContinue }
}

Write-Host "`n(High performance postavka za powershell.exe je vracena kako je bila.)" -ForegroundColor DarkGray
