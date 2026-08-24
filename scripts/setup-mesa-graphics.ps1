<#
    setup-mesa-graphics.ps1
    Postavlja Mesine grafike putove u GPU-P gostu:
      - OpenGL preko D3D12  (hardverski, GL 4.2)
      - OpenGL preko llvmpipe (softverski, GL 4.6)
      - Vulkan preko Dozena (hardverski, Vulkan 1.2)

    U GPU-P gostu nema NVIDIA kernel drivera, pa ni izvorni OpenGL ni izvorni
    Vulkan ne postoje. Mesa ih gradi povrh Direct3D 12, koji GPU-P paravirtualizira.

    UPOTREBA
      .\setup-mesa-graphics.ps1 -MesaArchive C:\put\do\mesa3d-XX-release-msvc.7z
      .\setup-mesa-graphics.ps1 -MesaDir C:\Users\Public\mesa\x     (vec raspakirano)
      .\setup-mesa-graphics.ps1 -Revert

    Mesa za Windows: https://github.com/pal1000/mesa-dist-win  (release-msvc)
#>
[CmdletBinding()]
param(
  [string]$MesaArchive,
  [string]$MesaDir,
  [string]$Target = 'C:\Mesa\x64',
  [string]$SevenZip,
  [switch]$Revert
)

$ErrorActionPreference = 'Stop'
function Ok  ($m){ Write-Host "  [OK]   $m" -ForegroundColor Green }
function Warn($m){ Write-Host "  [!]    $m" -ForegroundColor Yellow }
function Bad ($m){ Write-Host "  [FAIL] $m" -ForegroundColor Red }
function Head($m){ Write-Host "`n== $m" -ForegroundColor Cyan }

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $elevated) { throw 'Pokreni kao administrator - pise se u HKLM.' }

$icdKey = 'HKLM:\SOFTWARE\Khronos\Vulkan\Drivers'

# --------------------------------------------------------------------- REVERT
if ($Revert) {
  Head 'Vracanje'
  if (Test-Path $icdKey) { Remove-Item $icdKey -Recurse -Force; Ok 'Dozen ICD odregistriran' }
  if (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Khronos\Vulkan\Drivers') {
    Remove-Item 'HKLM:\SOFTWARE\WOW6432Node\Khronos\Vulkan\Drivers' -Recurse -Force
  }
  try { if ([System.IO.File]::Exists('C:\Windows\System32\dxil.dll')) { [System.IO.File]::Delete('C:\Windows\System32\dxil.dll'); Ok 'dxil.dll uklonjen iz System32' } } catch { Warn $_.Exception.Message }
  Write-Host "`nMapa $Target nije obrisana - obrisi je rucno ako je vise ne trebas." -ForegroundColor Cyan
  Write-Host 'Developer Mode nije diran.' -ForegroundColor Cyan
  return
}

# ---------------------------------------------------------------- RASPAKIRAJ
if (-not $MesaDir) {
  if (-not $MesaArchive) { throw 'Zadaj -MesaArchive (.7z) ili -MesaDir (raspakirano).' }
  if (-not (Test-Path $MesaArchive)) { throw "Arhiva ne postoji: $MesaArchive" }
  if (-not $SevenZip) {
    $SevenZip = @('C:\Program Files\7-Zip\7z.exe', (Join-Path (Split-Path $MesaArchive -Parent) '7zr.exe')) |
                Where-Object { Test-Path $_ } | Select-Object -First 1
  }
  if (-not $SevenZip) {
    throw @'
Za .7z treba ekstraktor. Ugradeni tar.exe ne zna LZMA.
Uzmi 7zr.exe s https://www.7-zip.org/a/7zr.exe i predaj ga preko -SevenZip,
ili sam raspakiraj i koristi -MesaDir.
'@
  }
  $MesaDir = Join-Path (Split-Path $MesaArchive -Parent) 'mesa_x'
  Head 'Raspakiravam Mesu'
  & $SevenZip x $MesaArchive "-o$MesaDir" -y | Out-Null
  Ok $MesaDir
}

$src = Join-Path $MesaDir 'x64'
if (-not (Test-Path $src)) { $src = $MesaDir }
if (-not (Test-Path (Join-Path $src 'opengl32.dll'))) { throw "U $src nema opengl32.dll - kriva mapa?" }

# -------------------------------------------------------------------- KOPIRAJ
Head "Kopiram u $Target"
New-Item -ItemType Directory -Path $Target -Force | Out-Null
$files = @(
  'opengl32.dll','libgallium_wgl.dll',    # OpenGL (d3d12 i llvmpipe)
  'dxil.dll','spirv_to_dxil.dll',         # prevodenje shadera u DXIL
  'vulkan_dzn.dll','dzn_icd.x86_64.json', # Vulkan preko D3D12
  'vulkan_lvp.dll','lvp_icd.x86_64.json'  # Vulkan softverski (rezerva)
)
foreach ($f in $files) {
  $p = Join-Path $src $f
  if (Test-Path $p) { Copy-Item $p $Target -Force; Ok $f } else { Warn "$f nema u paketu" }
}

# ------------------------------------------------------- dxil.dll u System32
# Dozen ga ucitava DINAMICKI, pa ga Windows trazi u mapi aplikacije, System32
# i PATH - nikad u mapi ICD-a. Kopija u System32 rjesava to za sve aplikacije.
Head 'dxil.dll za Dozen'
Copy-Item (Join-Path $Target 'dxil.dll') 'C:\Windows\System32\dxil.dll' -Force
Ok 'dxil.dll u System32'

# ------------------------------------------------------------ REGISTRIRAJ ICD
Head 'Vulkan ICD (Dozen)'
$icd = Join-Path $Target 'dzn_icd.x86_64.json'
New-Item -Path $icdKey -Force | Out-Null
New-ItemProperty -Path $icdKey -Name $icd -Value 0 -PropertyType DWord -Force | Out-Null
Ok $icd

# --------------------------------------------------------- DEVELOPER MODE
Head 'Windows Developer Mode'
$dm = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue).AllowDevelopmentWithoutDevLicense
if ($dm -eq 1) {
  Ok 'ukljucen'
} else {
  Bad 'ISKLJUCEN - Dozen bez njega NE RADI'
  Write-Host @'
         Dozen zove D3D12EnableExperimentalFeatures(D3D12ExperimentalShaderModels),
         a ta funkcija bez Developer Modea tiho ne uspije.

         Ukljuci ga sam (sigurnosna postavka sustava):
           Settings > Update & Security > For developers > Developer mode
         ili:
           New-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" `
             -Name AllowDevelopmentWithoutDevLicense -Value 1 -PropertyType DWord -Force
'@ -ForegroundColor Yellow
}

Write-Host @"

== GOTOVO

Provjeri stanje:
  .\gfx-status.ps1

Aplikaciju pokreni preko odgovarajuceg predloska iz mape templates\:
  OpenGL hardverski   GALLIUM_DRIVER=d3d12
  OpenGL softverski   GALLIUM_DRIVER=llvmpipe
  Vulkan  hardverski  DZN_DEBUG=experimental

I NE ZABORAVI: aplikaciji dodijeli High performance GPU
(Settings > Display > Graphics), inace Mesa dobije WARP s 0 MiB.
"@ -ForegroundColor Cyan
