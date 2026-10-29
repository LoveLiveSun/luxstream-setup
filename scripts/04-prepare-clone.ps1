<#
    04-prepare-clone.ps1
    Pokrece se NA KLONU, odmah nakon sto je VM kopiran i prvi put pokrenut.

    Sunshine ima identitet vezan uz stroj. Klonaranjem ga dupliciras, pa Moonlight
    dva klona vidi kao JEDAN host i ne moze drzati dvije istovremene sesije.

    Ova skripta:
      1. brise Sunshineov uniqueid i TLS certifikate  -> generiraju se novi pri startu
      2. brise zapamceno stanje displayja
      3. po potrebi preimenuje racunalo (mDNS ime prati hostname)

    NAPOMENA: nakon ovoga se svaki klon mora PONOVO UPARITI iz Moonlighta.
#>
[CmdletBinding()]
param(
  [string]$NewComputerName,          # npr. GPU-2 ; izostavi ako ne zelis preimenovati
  [string]$SunshineName,             # ime pod kojim se Sunshine objavljuje; default = hostname
  [string]$SunshineDir = 'C:\Program Files\Sunshine',
  [switch]$Restart                   # rebootaj na kraju ako je ime promijenjeno
)

$ErrorActionPreference = 'Stop'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  throw 'Pokreni kao administrator.'
}

$cfg   = Join-Path $SunshineDir 'config'
$state = Join-Path $cfg 'sunshine_state.json'
$creds = Join-Path $cfg 'credentials'
$dd    = Join-Path $cfg 'display_device.state'
$conf  = Join-Path $cfg 'sunshine.conf'

Write-Host "== Trenutni identitet" -ForegroundColor Cyan
Write-Host "  hostname : $env:COMPUTERNAME"
if (Test-Path $state) {
  $j = Get-Content $state -Raw | ConvertFrom-Json
  Write-Host "  uniqueid : $($j.root.uniqueid)"
}

Write-Host "`n== Zaustavljam Sunshine" -ForegroundColor Cyan
Stop-Service SunshineService -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$bak   = Join-Path $cfg "clone-backup-$stamp"
New-Item -ItemType Directory -Path $bak -Force | Out-Null

Write-Host "`n== Brisem identitet (backup u $bak)" -ForegroundColor Cyan
foreach ($p in @($state, $dd)) {
  if (Test-Path $p) {
    Copy-Item $p $bak -Force
    Remove-Item $p -Force
    Write-Host "  obrisano: $(Split-Path $p -Leaf)"
  }
}
if (Test-Path $creds) {
  Copy-Item $creds $bak -Recurse -Force
  Remove-Item $creds -Recurse -Force
  Write-Host '  obrisano: credentials\ (cacert.pem, cakey.pem)'
}

# Ime pod kojim se Sunshine objavljuje. Bez ovoga se oba klona zovu isto.
if ($SunshineName) {
  $lines = @()
  if (Test-Path $conf) { $lines = Get-Content $conf | Where-Object { $_ -notmatch '^\s*sunshine_name\s*=' } }
  $lines += "sunshine_name = $SunshineName"
  [System.IO.File]::WriteAllLines($conf, $lines, (New-Object System.Text.UTF8Encoding($false)))
  Write-Host "  sunshine_name = $SunshineName"
}

if ($NewComputerName) {
  Write-Host "`n== Preimenujem racunalo u $NewComputerName" -ForegroundColor Cyan
  Rename-Computer -NewName $NewComputerName -Force
  Write-Host '  Promjena imena zahtijeva reboot.' -ForegroundColor Yellow
}

Write-Host "`n== Pokrecem Sunshine" -ForegroundColor Cyan
Start-Service SunshineService -ErrorAction SilentlyContinue
Start-Sleep -Seconds 12

if (Test-Path $state) {
  $j = Get-Content $state -Raw | ConvertFrom-Json
  Write-Host "  novi uniqueid : $($j.root.uniqueid)" -ForegroundColor Green
} else {
  Write-Host '  sunshine_state.json jos nije stvoren; nastat ce pri prvom uparivanju.' -ForegroundColor Yellow
}

Write-Host @"

== SLJEDECI KORACI

1. Provjeri da klon ima svoju IP adresu i svoj MAC (Hyper-V: novi MAC ako je dinamican).
2. U Moonlightu DODAJ KLON KAO NOVI HOST i klikni ga. Sparivanje ide samo od sebe,
   bez PIN-a i bez icega u web sucelju (web sucelje nema prijavu).
   Stari zapis obrisi ako pokazuje na isti uniqueid.
3. Pokreni .\03-verify.ps1

== VAZNO ZA DVIJE ISTOVREMENE SESIJE

NVENC vise nije usko grlo - enkodiranje je na CPU-u (libx264). Zato provjeri CPU, ne GPU:
svaki VM koji streama trosi znatan dio svojih vCPU jezgri na enkodiranje. Dva VM-a
istovremeno znace dvostruko opterecenje na hostu. Ako slika trza, smanji rezoluciju
ili fps prije nego bilo sto drugo.
"@ -ForegroundColor Cyan

if ($NewComputerName -and $Restart) { Restart-Computer -Force }
