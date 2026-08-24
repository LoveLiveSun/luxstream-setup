<#
    launch-with-native-gpu.ps1

    Pokrece aplikaciju tako da joj budu dostupni IZVORNI NVIDIA OpenGL i Vulkan
    u Hyper-V GPU-PV gostu.

    OTKRICE
      Izvorni NVIDIA Vulkan/OpenGL u GPU-PV gostu rade, ali samo ako je
      Hyper-V synthetic monitor PRIKACEN NA DESKTOP u trenutku pokretanja
      aplikacije. Nakon sto se aplikacija pokrene, monitor se moze odspojiti
      i aplikacija nastavlja raditi na preostalom virtualnom displayu.

      Bez prikacenog Hyper-V monitora NVIDIA-in Vulkan ICD prijavi 0 uredaja,
      a wglCreateContext ne uspije - sto izgleda kao da driver ne postoji.

    Zasluge za ideju: github.com/Loyola-London/HyperVideoLauncher

    UPOTREBA
      .\launch-with-native-gpu.ps1 -Exe "C:\put\App.exe"
      .\launch-with-native-gpu.ps1 -Exe "C:\put\App.exe" -DetachAfter 25
      .\launch-with-native-gpu.ps1 -Exe "C:\put\App.exe" -KeepAttached

    NAPOMENA UZ SUNSHINE
      dd_configuration_option = ensure_only_display ISKLJUCI Hyper-V monitor
      pri pocetku streama. Zato ova skripta postoji: vrati ga na trenutak,
      pokrene aplikaciju, pa ga opet makne da ne smeta hvatanju slike.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Exe,
  [string[]]$Arguments,
  [int]$DetachAfter = 30,      # sekundi nakon pokretanja
  [switch]$KeepAttached,       # ostavi Hyper-V monitor prikacen
  [switch]$HighPerformance,    # dodijeli aplikaciji High performance GPU
  [switch]$OpenGL              # i primarni display privremeno na Hyper-V (za izvorni OpenGL)
)

$ErrorActionPreference = 'Stop'
function Head($m){ Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!]    $m" -ForegroundColor Yellow }

if (-not (Test-Path $Exe)) { throw "Ne postoji: $Exe" }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw 'Pokreni kao administrator - mijenja se stanje PnP uredaja.' }

Add-Type -AssemblyName System.Windows.Forms

function Get-MonitorNames {
  Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue |
    ForEach-Object { -join ($_.UserFriendlyName | Where-Object {$_ -ne 0} | ForEach-Object {[char]$_}) }
}
# --- prebacivanje primarnog displaya (potrebno za IZVORNI OpenGL) -----------
# OpenGL bira driver prema PRIMARNOM displayu. VDD je na WARP-u i nema GL ICD,
# pa wglCreateContext pada. Hyper-V display je na NVIDIA adapteru i ima ga.
# Kontekst jednom stvoren PREZIVLJAVA vracanje primarnog - provjereno.
$primSig = @"
using System;using System.Runtime.InteropServices;
public class LPRIM{
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Ansi)]
 public struct DEVMODE{[MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string n;public short a,b,c,d;
 public int f,px,py,o,fo;public short col,dup,yres,tt,coll;
 [MarshalAs(UnmanagedType.ByValTStr,SizeConst=32)]public string fn;public short lp;
 public int bpp,w,h,fl,freq,icm,ici,mt,dt,r1,r2,pw,ph;}
 [DllImport("user32.dll",CharSet=CharSet.Ansi)]public static extern bool EnumDisplaySettingsA(string dev,int m,ref DEVMODE dm);
 [DllImport("user32.dll",CharSet=CharSet.Ansi)]public static extern int ChangeDisplaySettingsExA(string dev,ref DEVMODE dm,IntPtr h,int fl,IntPtr p);
 [DllImport("user32.dll")]public static extern int ChangeDisplaySettingsA(IntPtr dm,int fl);}
"@
if (-not ('LPRIM' -as [type])) { Add-Type -TypeDefinition $primSig }

function Set-PrimaryDisplay([string]$target) {
  for ($i = 1; $i -le 3; $i++) {
    $all = [System.Windows.Forms.Screen]::AllScreens
    $t = $all | Where-Object { $_.DeviceName -eq $target } | Select-Object -First 1
    if (-not $t) { return $false }
    if ($t.Primary) { return $true }
    $ox = $t.Bounds.X; $oy = $t.Bounds.Y
    foreach ($s in $all) {
      $dm = New-Object LPRIM+DEVMODE; $dm.c = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
      [LPRIM]::EnumDisplaySettingsA($s.DeviceName, -1, [ref]$dm) | Out-Null
      $dm.px = $s.Bounds.X - $ox; $dm.py = $s.Bounds.Y - $oy; $dm.f = 0x00000020
      $fl = 0x00000001 -bor 0x10000000
      if ($s.DeviceName -eq $target) { $fl = $fl -bor 0x00000010 }
      [LPRIM]::ChangeDisplaySettingsExA($s.DeviceName, [ref]$dm, [IntPtr]::Zero, $fl, [IntPtr]::Zero) | Out-Null
    }
    [LPRIM]::ChangeDisplaySettingsA([IntPtr]::Zero, 0) | Out-Null
    Start-Sleep -Seconds 7
  }
  return ([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $target }).Primary
}

function Get-DisplayBySize([switch]$Largest) {
  $s = [System.Windows.Forms.Screen]::AllScreens | Sort-Object { $_.Bounds.Width * $_.Bounds.Height } -Descending
  if ($Largest) { $s[0] } elseif ($s.Count -gt 1) { $s[-1] } else { $null }
}

# ---------------------------------------------------- High performance GPU
if ($HighPerformance) {
  $prefKey = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
  New-Item -Path $prefKey -Force | Out-Null
  Set-ItemProperty -Path $prefKey -Name $Exe -Value 'GpuPreference=2;'
  Ok "High performance GPU dodijeljen: $(Split-Path $Exe -Leaf)"
}

# ---------------------------------------------------- prikaci Hyper-V monitor
Head 'Prikacujem Hyper-V monitor'
$hv = Get-PnpDevice -FriendlyName 'Microsoft Hyper-V Video' -ErrorAction SilentlyContinue
if (-not $hv) { throw 'Microsoft Hyper-V Video adapter ne postoji u ovom VM-u.' }

$wasDisabled = ($hv.Status -ne 'OK')
if ($wasDisabled) { Enable-PnpDevice -InstanceId $hv.InstanceId -Confirm:$false; Start-Sleep -Seconds 6 }

if ((Get-MonitorNames) -notcontains 'HyperVMonitor') {
  # adapter je tu ali monitor nije u topologiji - restart uredaja ga vrati
  Disable-PnpDevice -InstanceId $hv.InstanceId -Confirm:$false
  Start-Sleep -Seconds 5
  Enable-PnpDevice  -InstanceId $hv.InstanceId -Confirm:$false
  Start-Sleep -Seconds 12
  Start-Process -FilePath "$env:WINDIR\System32\DisplaySwitch.exe" -ArgumentList '/extend' -Wait
  Start-Sleep -Seconds 8
}

if ((Get-MonitorNames) -contains 'HyperVMonitor') { Ok 'HyperVMonitor je prikacen' }
else { Warn 'HyperVMonitor se nije prikacio - izvorni Vulkan/OpenGL vjerojatno nece raditi' }

[System.Windows.Forms.Screen]::AllScreens |
  Select-Object DeviceName,Primary,@{n='Res';e={"$($_.Bounds.Width)x$($_.Bounds.Height)"}} |
  Format-Table -AutoSize | Out-String -Width 100 | Write-Host

# ---------------------------------------------------- primarni na Hyper-V (za OpenGL)
$origPrimary = $null
if ($OpenGL) {
  Head 'Privremeno prebacujem primarni display na Hyper-V (za izvorni OpenGL)'
  $big   = Get-DisplayBySize -Largest
  $small = Get-DisplayBySize
  $origPrimary = ($big).DeviceName
  if ($small -and $small.DeviceName -ne $origPrimary) {
    if (Set-PrimaryDisplay $small.DeviceName) { Ok "primarni je sada $($small.DeviceName)" }
    else { Warn 'nisam uspio prebaciti primarni - izvorni OpenGL vjerojatno nece raditi' }
  } else { Warn 'nema drugog displaya za primarni' }
}

# ---------------------------------------------------- pokreni aplikaciju
Head "Pokrecem $(Split-Path $Exe -Leaf)"
$p = if ($Arguments) { Start-Process -FilePath $Exe -ArgumentList $Arguments -PassThru -WorkingDirectory (Split-Path $Exe -Parent) }
     else            { Start-Process -FilePath $Exe -PassThru -WorkingDirectory (Split-Path $Exe -Parent) }
Ok "PID $($p.Id)"

# ---------------------------------------------------- odspoji monitor
if ($OpenGL -and $origPrimary) {
  Head 'Cekam 12 s da aplikacija stvori GL kontekst, pa vracam primarni'
  Start-Sleep -Seconds 12
  if (Set-PrimaryDisplay $origPrimary) { Ok "primarni vracen na $origPrimary" }
  else { Warn "nisam uspio vratiti primarni na $origPrimary - napravi to rucno" }
}

if ($KeepAttached) {
  Write-Host "`nHyper-V monitor ostaje prikacen (-KeepAttached)." -ForegroundColor Cyan
  return
}

Head "Cekam $DetachAfter s pa odspajam Hyper-V monitor"
for ($i = $DetachAfter; $i -gt 0; $i--) {
  if ($p.HasExited) { Warn "Aplikacija je izasla nakon $($DetachAfter - $i) s"; break }
  Start-Sleep -Seconds 1
}

if (-not $p.HasExited) {
  Disable-PnpDevice -InstanceId $hv.InstanceId -Confirm:$false
  Start-Sleep -Seconds 4
  Ok 'Hyper-V monitor odspojen - aplikacija nastavlja raditi'
  [System.Windows.Forms.Screen]::AllScreens |
    Select-Object DeviceName,Primary,@{n='Res';e={"$($_.Bounds.Width)x$($_.Bounds.Height)"}} |
    Format-Table -AutoSize | Out-String -Width 100 | Write-Host
} else {
  Warn 'Aplikacija vise ne radi; Hyper-V monitor ostavljam kako jest.'
}
