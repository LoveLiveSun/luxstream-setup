<#
    gpu-p-setup.ps1
    POKRECE SE NA HYPER-V HOSTU, ne u gostu.

    Provjerava i po potrebi dodaje GPU-P particiju VM-u.
    Bez -Apply skripta samo cita i nista ne mijenja.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)] [string]$VMName,
  [int]$MemoryGB = 24,
  [switch]$Apply
)

function Head($m){ Write-Host "`n== $m" -ForegroundColor Cyan }
function Ok  ($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!]    $m" -ForegroundColor Yellow }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Pokreni kao administrator.'
}

Head "VM: $VMName"
$vm = Get-VM -Name $VMName -ErrorAction Stop
$vm | Format-List Name,State,Version,Generation,AutomaticStopAction,CheckpointType | Out-String | Write-Host

Head 'Memorija'
$mem = Get-VMMemory -VMName $VMName
$mem | Format-List DynamicMemoryEnabled,Startup,Minimum,Maximum | Out-String | Write-Host
if ($mem.DynamicMemoryEnabled) {
  Warn 'Dynamic Memory je UKLJUCENA. Hyper-V odbija startati VM s GPU particijom uz nju.'
}

Head 'GPU particija na VM-u'
$ad = Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue
if ($ad) { $ad | Format-List * | Out-String | Write-Host; Ok 'Particija postoji' }
else     { Warn 'Particija NE postoji. To je najcesci uzrok da gost radi na WARP-u s 0 MiB VRAM-a.' }

Head 'Particionabilni GPU na hostu'
$pg = Get-VMHostPartitionableGpu -ErrorAction SilentlyContinue
if (-not $pg) { $pg = Get-VMPartitionableGpu -ErrorAction SilentlyContinue }
if ($pg) { $pg | Format-List Name,ValidPartitionCounts,PartitionCount | Out-String | Write-Host }
else     { Warn 'Host ne prijavljuje nijedan particionabilan GPU. Dalje nema smisla.' }

Head 'NVIDIA driver na hostu'
Get-CimInstance Win32_VideoController | Where-Object Name -like '*NVIDIA*' |
  Select-Object Name,DriverVersion,DriverDate,InfFilename | Format-List | Out-String | Write-Host
Get-ChildItem 'C:\Windows\System32\DriverStore\FileRepository' -Filter 'nv_dispi.inf_amd64_*' -ErrorAction SilentlyContinue |
  Select-Object Name | Format-Table -AutoSize | Out-String | Write-Host
Write-Host '  Ova mapa i verzija moraju se POKLAPATI s onim u gostu pod'
Write-Host '  C:\Windows\System32\HostDriverStore\FileRepository\, inace gost daje Code 43.'

Head 'Ostali VM-ovi na GPU-u'
Get-VM | ForEach-Object {
  [PSCustomObject]@{
    VM = $_.Name; State = $_.State
    GpuAdapters = (Get-VMGpuPartitionAdapter -VMName $_.Name -ErrorAction SilentlyContinue | Measure-Object).Count
  }
} | Format-Table -AutoSize | Out-String | Write-Host

if (-not $Apply) {
  Write-Host "`nSamo citanje. Za izmjene pokreni ponovo s -Apply (VM ce se ugasiti)." -ForegroundColor Yellow
  return
}

Head 'PRIMJENA'
Write-Host 'Gasim VM...'
Stop-VM -Name $VMName -Force -ErrorAction SilentlyContinue
do { Start-Sleep -Seconds 2 } until ((Get-VM -Name $VMName).State -eq 'Off')

Set-VM       -Name   $VMName -AutomaticStopAction TurnOff -CheckpointType Disabled
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false -StartupBytes ($MemoryGB * 1GB)
Set-VM       -Name   $VMName -GuestControlledCacheTypes $true `
                             -LowMemoryMappedIoSpace 1GB `
                             -HighMemoryMappedIoSpace 32GB
Ok 'Preduvjeti postavljeni'

if (-not (Get-VMGpuPartitionAdapter -VMName $VMName -ErrorAction SilentlyContinue)) {
  Add-VMGpuPartitionAdapter -VMName $VMName
  Ok 'Particija dodana'
}

Get-VMGpuPartitionAdapter -VMName $VMName | Format-List * | Out-String | Write-Host

Start-VM -Name $VMName
Ok 'VM pokrenut'
Write-Host "`nU gostu provjeri s: .\scripts\00-preflight.ps1" -ForegroundColor Yellow
