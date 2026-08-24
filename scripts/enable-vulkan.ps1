<#
    enable-vulkan.ps1
    Registrira NVIDIA Vulkan ICD u GPU-P gostu.

    PROBLEM
      U GPU-P gostu driver se KOPIRA, ne instalira. Kopija donese sve datoteke
      (nv-vk64.json, nvoglv64.dll), ali NE napravi registraciju u registryju.
      Vulkan loader (vulkan-1.dll) trazi drivere iskljucivo preko kljuca
      HKLM\SOFTWARE\Khronos\Vulkan\Drivers - a njega u gostu nema.
      Posljedica: vkCreateInstance uspije, ali vkEnumeratePhysicalDevices vrati 0.

    RJESENJE
      Upisati putanju do nv-vk64.json u taj kljuc. Loader dalje sam nade
      nvoglv64.dll jer ICD na njega pokazuje relativno (".\nvoglv64.dll").

    POVRATAK
      -Revert  ukloni registrirane unose.
#>
[CmdletBinding()]
param(
  [string]$HostDriverStore = 'C:\Windows\System32\HostDriverStore\FileRepository',
  [switch]$Revert
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Pokreni kao administrator - pise se u HKLM.'
}

$key64 = 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers'
$key32 = 'HKLM:\SOFTWARE\WOW6432Node\Khronos\Vulkan\Drivers'

if ($Revert) {
  foreach ($k in @($key64, $key32)) {
    if (Test-Path $k) { Remove-Item $k -Recurse -Force; Write-Host "  uklonjeno: $k" -ForegroundColor Green }
  }
  Write-Host 'Vulkan ICD registracija uklonjena.' -ForegroundColor Cyan
  return
}

# --- 1. Nadi ICD datoteke ----------------------------------------------------
# Uzimamo najplicu putanju - neke skripte za kopiranje drivera naprave ugnijezdenu
# kopiju (nv_dispi.../nv_dispi.../), a loader treba onu uz koju stoji nvoglv64.dll.
function Find-Icd([string]$fileName, [string]$dllName) {
  Get-ChildItem $HostDriverStore -Recurse -Filter $fileName -ErrorAction SilentlyContinue |
    Where-Object { Test-Path (Join-Path $_.DirectoryName $dllName) } |
    Sort-Object { $_.FullName.Split('\').Count } |
    Select-Object -First 1
}

$icd64 = Find-Icd 'nv-vk64.json' 'nvoglv64.dll'
$icd32 = Find-Icd 'nv-vk32.json' 'nvoglv32.dll'

if (-not $icd64) {
  throw "Nije pronaden nv-vk64.json uz koji stoji nvoglv64.dll pod $HostDriverStore. Kopija drivera je nepotpuna."
}

Write-Host 'Pronadeni ICD-ovi:' -ForegroundColor Cyan
Write-Host "  64-bit : $($icd64.FullName)"
if ($icd32) { Write-Host "  32-bit : $($icd32.FullName)" } else { Write-Host '  32-bit : nema (32-bitne Vulkan aplikacije nece raditi)' -ForegroundColor Yellow }

# --- 2. Registriraj ----------------------------------------------------------
New-Item -Path $key64 -Force | Out-Null
New-ItemProperty -Path $key64 -Name $icd64.FullName -Value 0 -PropertyType DWord -Force | Out-Null
Write-Host "  [OK]   registriran 64-bitni ICD" -ForegroundColor Green

if ($icd32) {
  New-Item -Path $key32 -Force | Out-Null
  New-ItemProperty -Path $key32 -Name $icd32.FullName -Value 0 -PropertyType DWord -Force | Out-Null
  Write-Host "  [OK]   registriran 32-bitni ICD" -ForegroundColor Green
}

# --- 3. Provjeri -------------------------------------------------------------
Write-Host "`nProvjera:" -ForegroundColor Cyan
$test = Join-Path $PSScriptRoot 'vulkantest.ps1'
if (Test-Path $test) {
  & $test | ForEach-Object { Write-Host "  $_" }
} else {
  Write-Host '  vulkantest.ps1 nije pored ove skripte; provjeri rucno.' -ForegroundColor Yellow
}

Write-Host @"

NAPOMENA
  Vulkan aplikacije treba pokrenuti IZNOVA da vide promjenu.
  Ako aplikacija i dalje ne vidi GPU, provjeri je li joj u
  Settings > Display > Graphics dodijeljen High performance GPU.
"@ -ForegroundColor Cyan
