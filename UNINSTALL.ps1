<#
    UNINSTALL.ps1 - uklanja sve sto Luxstream postavi na ovaj Windows

    POKRETANJE
        Dvoklik na Luxstream-ODINSTALIRAJ.cmd
        ili iz povisenog PowerShella:
        powershell -ExecutionPolicy Bypass -File .\UNINSTALL.ps1

    Skript je idempotentan - na sustavu bez Luxstreama samo ispise "nema".

    OPCIJE
        -Samoprovjera       samo popis, nista se ne mijenja
        -Obrisi             podatke obrisi trajno (zadano: premjesti u karantenu)
        -ZadrziDrivere      ne dira VDD, ViGEmBus ni VB-Audio kabel
        -ZadrziSunshine     ne uklanja Sunshine (MSI ni mapu)
        -ObrisiCertifikate  uklanja i uvezene potpisnike drivera iz spremista
                            certifikata. POZOR: SignPath je javni CA
        -Prisili            bez potvrde
        -Tiho               manje ispisa

    STO UKLANJA - sve sto postavi INSTALL.ps1
        zadaci    SunshineUser, StreamReady, RestoreConsoleSession,
                  VerifyAfterBoot, LuxstreamBridge
        most      C:\ProgramData\Luxstream  (bridge.json)
        audio     VB-Audio virtualni kabel
        sunshine  MSI proizvod + C:\Program Files\Sunshine
        VDD       driver mttvdd.inf + C:\VirtualDisplayDriver
        gamepad   ViGEmBus (vigembus.inf)
        registar  UAC, automatska prijava, GameDVR/Game Bar, DPI
        vatrozid  pravila "Luxstream *", ako postoje
        precac    Start izbornik -> "Uninstall Luxstream"
        datoteke  C:\Program Files\Luxstream, C:\Luxstream-setup,
                  C:\Users\Public\sunshine-gpup-setup, C:\Users\Public\Luxstream.exe,
                  %USERPROFILE%\Luxstream, C:\Users\Public\luxstream-*

    ZASTO KARANTENA, A NE BRISANJE
        Sadrzaj mosta (Primljeno / Poslano / Drop) i sunshine.conf su korisnicki
        sadrzaj i ne smiju se izgubiti slucajno. Zadano se PREMJESTE u
        C:\Luxstream-uklonjeno-<vrijeme> pa se mogu vratiti. -Obrisi brise
        trajno. Registry i driveri se ne mogu vratiti, zato se svaka njihova
        izmjena ispise prije izvrsavanja.

    REDOSLIJED JE BITAN
        Zadaci se odjavljuju PRIJE drivera i datoteka. Inace StreamReady ili
        SunshineUser u meduvremenu ponovno pokrenu Sunshine i "vrate" ono sto
        smo upravo uklonili - vidjeno na G10 kao "Sunshine radi (PID 12040 27772)".

    NAPOMENA
        Skript na kraju obrise i sam sebe (zivi u C:\Program Files\Luxstream).
        To je u redu - PowerShell procita cijelu skriptu prije izvrsavanja.
#>
[CmdletBinding()]
param(
  [switch]$Samoprovjera,
  [switch]$Obrisi,
  [switch]$ZadrziDrivere,
  [switch]$ZadrziSunshine,
  [switch]$ObrisiCertifikate,
  [switch]$Prisili,
  [switch]$Tiho
)

$ErrorActionPreference = 'Continue'

# --- 32-bitni proces ne smije dalje ------------------------------------------
# Isti razlog kao u INSTALL.ps1: 32-bitnom procesu se System32 preusmjeri na
# SysWOW64, gdje nema pnputil.exe. Tada uklanjanje drivera tiho ne radi.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
  $ps64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path $ps64) {
    Write-Host '  Switching to 64-bit PowerShell (pnputil lives there)...' -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path))
    foreach ($k in $PSBoundParameters.GetEnumerator()) {
      if ($k.Value -is [switch]) { if ($k.Value.IsPresent) { $a += "-$($k.Key)" } }
      else { $a += "-$($k.Key)"; $a += "$($k.Value)" }
    }
    $p = Start-Process $ps64 -ArgumentList $a -PassThru -Wait -NoNewWindow
    exit $p.ExitCode
  }
  Write-Host 'WARNING: 32-bit process and Sysnative is unavailable. Driver removal will fail.' -ForegroundColor Red
}

$sys = Join-Path $env:SystemRoot 'System32'
foreach ($p in @($sys, (Join-Path $sys 'WindowsPowerShell\v1.0'), (Join-Path $env:SystemRoot 'SysWOW64'))) {
  if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) { $env:PATH = "$p;$env:PATH" }
}

# Radi se iz C:\ ili odande odakle je pozvan (Luxstream-ODINSTALIRAJ.cmd radi
# pushd na mapu paketa). Faza 11 brise upravo tu mapu - Windows ne da obrisati
# direktorij koji je trenutni radni direktorij procesa, pa bi "C:\Program Files\
# Luxstream" ostao. Prebacivanje u C:\ to rjesava.
Set-Location ('{0}\' -f $env:SystemDrive)

# ============================================================ KONSTANTE =====
$dnevnik   = 'C:\Users\Public\luxstream-uninstall.log'
$karantena = "C:\Luxstream-uklonjeno-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$greske    = 0

$zadaci = @('SunshineUser', 'StreamReady', 'RestoreConsoleSession', 'VerifyAfterBoot', 'LuxstreamBridge')

# Programski direktoriji: mogu se obrisati, sve se da ponovno instalirati.
$programMape = @(
  'C:\Program Files\Luxstream',
  'C:\Luxstream-setup',
  'C:\Users\Public\sunshine-gpup-setup',
  'C:\VirtualDisplayDriver'
)

$kljuceviUninstall = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

# ============================================================ ISPIS =========
function Dnevnik($m) {
  try { Add-Content -Path $dnevnik -Value $m -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
}
function Head($m) {
  if (-not $Tiho) { Write-Host "`n=== $m" -ForegroundColor Cyan }
  Dnevnik "`n=== $m"
}
function Ok  ($m) { if (-not $Tiho) { Write-Host "  [OK]   $m" -ForegroundColor Green };  Dnevnik "  [OK]   $m" }
function Inf ($m) { if (-not $Tiho) { Write-Host "  [..]   $m" };                          Dnevnik "  [..]   $m" }
function Warn($m) { if (-not $Tiho) { Write-Host "  [!]    $m" -ForegroundColor Yellow };  Dnevnik "  [!]    $m" }
function Bad ($m) { if (-not $Tiho) { Write-Host "  [FAIL] $m" -ForegroundColor Red };     Dnevnik "  [FAIL] $m"; $script:greske++ }
function Nema($m) { if (-not $Tiho) { Write-Host "  [--]   $m" -ForegroundColor DarkGray }; Dnevnik "  [--]   $m" }

# ============================================================ POMOCNE =======
function Test-Poviseno {
  try {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# Vraca izdano ime (oemNN.inf) za zadano izvorno ime driver paketa.
#
# Naslovi u izlazu pnputila se NE citaju: pnputil je lokaliziran
# ("Published Name" / "已发布的名称"), pa bi engleski uzorak na kineskom
# Windowsu promasio. `oemNN.inf` je latinica i ne mijenja se - trazi se po njemu.
function Nadji-IzdaniInf([string]$izvornoIme) {
  $tekst = (& "$sys\pnputil.exe" /enum-drivers 2>&1 | Out-String)
  if (-not $tekst) { return $null }
  foreach ($blok in ($tekst -split "`r?`n`r?`n")) {
    if ($blok -notlike "*$izvornoIme*") { continue }
    $m = [regex]::Matches($blok, '\boem\d+\.inf\b', 'IgnoreCase')
    if ($m.Count -gt 0) { return $m[0].Value }
  }
  return $null
}

# Vraca uredjaje ciji hardverski ID sadrzi zadani uzorak.
function Nadji-Uredjaje([string]$uzorak) {
  return @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
           Where-Object { $_.HardwareID -and ((@($_.HardwareID) -join ';') -like "*$uzorak*") })
}

# Uklanja uredjaje ciji hardverski ID sadrzi zadani uzorak.
function Ukloni-Uredjaje([string]$uzorak, [string]$naziv) {
  $dev = Nadji-Uredjaje $uzorak
  if ($dev.Count -eq 0) { Nema "$naziv - nema uredjaja ($uzorak)"; return }
  foreach ($d in $dev) {
    if ($Samoprovjera) { Inf "obrisao bi uredjaj: $($d.PNPDeviceID)"; continue }
    $r = (& "$sys\pnputil.exe" /remove-device "$($d.PNPDeviceID)" 2>&1 | Out-String)
    if ($LASTEXITCODE -eq 0) { Ok "uredjaj uklonjen: $($d.PNPDeviceID)" }
    else { Warn "uredjaj nije uklonjen: $($d.PNPDeviceID)"; Dnevnik $r }
  }
}

# Uklanja driver: prvo uredjaje, pa sam paket iz spremista.
function Ukloni-DriverPaket([string]$izvornoIme, [string]$hwidUzorak, [string]$naslov) {
  Head $naslov
  Ukloni-Uredjaje $hwidUzorak $naslov
  $izdano = Nadji-IzdaniInf $izvornoIme
  if (-not $izdano) { Nema "$naslov - paket $izvornoIme nije u spremistu drivera"; return }
  if ($Samoprovjera) { Inf "obrisao bi driver paket: $izdano ($izvornoIme)"; return }
  $r = (& "$sys\pnputil.exe" /delete-driver $izdano /uninstall /force 2>&1 | Out-String)
  if ($LASTEXITCODE -eq 0) { Ok "driver paket uklonjen: $izdano ($izvornoIme)" }
  else { Warn "driver paket nije uklonjen: $izdano"; Dnevnik $r }
}

# Vraca unos iz "Programi i znacajke" po uzorku naziva ili putanje.
function Nadji-Instalirani([string]$nazivUzorak, [string]$putanjaUzorak) {
  foreach ($k in $kljuceviUninstall) {
    $p = @(Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object {
      ($nazivUzorak   -and $_.DisplayName     -like $nazivUzorak) -or
      ($putanjaUzorak -and $_.InstallLocation -and ($_.InstallLocation -like $putanjaUzorak))
    })
    if ($p.Count -gt 0) { return $p[0] }
  }
  return $null
}

function Obrisi-Vrijednost([string]$put, [string]$ime, [string]$zasto) {
  if (-not (Test-Path $put)) { Nema "$zasto - nema kljuca $put"; return }
  $ima = $null -ne (Get-ItemProperty -Path $put -Name $ime -ErrorAction SilentlyContinue)
  if (-not $ima) { Nema "$zasto - $ime nije postavljen"; return }
  if ($Samoprovjera) { Inf "obrisao bi vrijednost: $put -> $ime   [$zasto]"; return }
  Remove-ItemProperty -Path $put -Name $ime -Force -ErrorAction SilentlyContinue
  Ok "uklonjeno: $put -> $ime   [$zasto]"
}

function Postavi-Vrijednost([string]$put, [string]$ime, $vrijednost, [string]$tip, [string]$zasto) {
  if ($Samoprovjera) { Inf "postavio bi: $put -> $ime = $vrijednost ($tip)   [$zasto]"; return }
  if (-not (Test-Path $put)) { New-Item -Path $put -Force | Out-Null }
  Set-ItemProperty -Path $put -Name $ime -Value $vrijednost -Type $tip -ErrorAction SilentlyContinue
  Ok "vraceno: $put -> $ime = $vrijednost   [$zasto]"
}

# Brise cijelu mapu. Koristi se samo za programske mape i za poziv s popisom
# tocno odredjenih putanja - nikad s dzokerima nad korisnickim mapama.
function Obrisi-Mapu([string]$put) {
  if (-not (Test-Path $put)) { Nema "nema: $put"; return }
  $koliko = @(Get-ChildItem $put -Recurse -File -ErrorAction SilentlyContinue).Count
  if ($Samoprovjera) { Inf "obrisao bi mapu: $put  ($koliko datoteka)"; return }
  Remove-Item $put -Recurse -Force -ErrorAction SilentlyContinue
  if (Test-Path $put) { Warn "nije obrisano (zauzeto?): $put" } else { Ok "obrisano: $put  ($koliko datoteka)" }
}

# Kratki popis sadrzaja mape, za ispis prije premjestanja. Pokazalo se da
# C:\ProgramData\Luxstream zna sadrzavati i tudje datoteke (npr.
# rustdesk-install.log), pa korisnik mora vidjeti sto tocno ide u karantenu.
function Opis-Mape([string]$put) {
  $sve = @(Get-ChildItem $put -Force -ErrorAction SilentlyContinue)
  if ($sve.Count -eq 0) { return '(prazno)' }
  $s = (@($sve | Select-Object -First 6 | ForEach-Object { $_.Name }) -join ', ')
  if ($sve.Count -gt 6) { $s += " ... ($($sve.Count) ukupno)" }
  return $s
}

# Korisnicki sadrzaj: zadano u karantenu, uz -Obrisi trajno.
#
# $oznaka je ime pod kojim se mapa sprema u karantenu. NE izvodim ga iz
# Split-Path -Leaf: i C:\ProgramData\Luxstream i %USERPROFILE%\Luxstream se
# zovu isto, pa bi drugi Move-Item sletio u prvi (ili ga preskocio).
function Premjesti-Mapu([string]$put, [string]$oznaka) {
  if (-not (Test-Path $put)) { Nema "nema: $put"; return }
  $koliko = @(Get-ChildItem $put -Recurse -File -ErrorAction SilentlyContinue).Count
  $opis   = Opis-Mape $put
  if ($Obrisi) {
    if ($Samoprovjera) { Inf "obrisao bi trajno: $put  ($koliko datoteka) [$opis]"; return }
    Remove-Item $put -Recurse -Force -ErrorAction SilentlyContinue
    Ok "obrisano trajno: $put  ($koliko datoteka) [$opis]"
    return
  }
  if ($Samoprovjera) { Inf "premjestio bi u karantenu: $put -> $oznaka  ($koliko datoteka) [$opis]"; return }
  New-Item -ItemType Directory -Path $karantena -Force | Out-Null
  $cilj = Join-Path $karantena $oznaka
  if (Test-Path $cilj) { $cilj = Join-Path $karantena "$oznaka-$(Get-Date -Format 'HHmmss')" }
  Move-Item -Path $put -Destination $cilj -Force -ErrorAction SilentlyContinue
  if (Test-Path $put) { Warn "nije premjesteno: $put" }
  else { Ok "premjesteno u karantenu: $cilj  ($koliko datoteka) [$opis]" }
}

function Obrisi-Datoteku([string]$put) {
  if (-not (Test-Path $put)) { Nema "nema: $put"; return }
  if ($Samoprovjera) { Inf "obrisao bi: $put"; return }
  Remove-Item $put -Force -ErrorAction SilentlyContinue
  if (Test-Path $put) { Warn "nije obrisano: $put" } else { Ok "obrisano: $put" }
}

# ============================================================ ELEVACIJA =====
if (-not (Test-Poviseno)) {
  Write-Host 'Requesting administrator rights...' -ForegroundColor Yellow
  $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $MyInvocation.MyCommand.Path))
  foreach ($k in $PSBoundParameters.GetEnumerator()) {
    if ($k.Value -is [switch]) { if ($k.Value.IsPresent) { $a += "-$($k.Key)" } }
    else { $a += "-$($k.Key)"; $a += ('"{0}"' -f $k.Value) }
  }
  Start-Process (Join-Path $sys 'WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $a -Verb RunAs
  exit
}

Write-Host ''
Write-Host '  Luxstream - uninstall' -ForegroundColor White
Write-Host '  ===================='
if ($Samoprovjera) { Write-Host '  DRY RUN - nothing will be changed' -ForegroundColor Yellow }
Dnevnik "=== UNINSTALL started $(Get-Date -Format o)  Samoprovjera=$Samoprovjera Obrisi=$Obrisi ZadrziDrivere=$ZadrziDrivere"

if (-not $Prisili -and -not $Samoprovjera) {
  Write-Host ''
  Write-Host '  This removes:' -ForegroundColor Yellow
  Write-Host '    - 5 scheduled tasks (SunshineUser, StreamReady, RestoreConsoleSession,' -ForegroundColor Yellow
  Write-Host '      VerifyAfterBoot, LuxstreamBridge)' -ForegroundColor Yellow
  if (-not $ZadrziSunshine) { Write-Host '    - Sunshine (MSI + C:\Program Files\Sunshine)' -ForegroundColor Yellow }
  if (-not $ZadrziDrivere)  { Write-Host '    - VDD, ViGEmBus and the VB-Audio virtual cable' -ForegroundColor Yellow }
  Write-Host '    - registry changes: UAC, automatic logon, GameDVR/Game Bar, DPI' -ForegroundColor Yellow
  Write-Host '    - the Luxstream package itself' -ForegroundColor Yellow
  Write-Host ''
  if ($Obrisi) { Write-Host '  Bridge data WILL BE DELETED (' -ForegroundColor Red -NoNewline; Write-Host '-Obrisi' -ForegroundColor Red -NoNewline; Write-Host ').' -ForegroundColor Red }
  else         { Write-Host '  Bridge data will be MOVED to a quarantine folder, not deleted.' -ForegroundColor Green }
  Write-Host ''
  $o = Read-Host '  Type U and press Enter to continue'
  if ($o -ne 'U') { Write-Host '  Cancelled - nothing changed.'; exit 0 }
}

# ======================================================= 1. ZADACI ==========
Head '1. Scheduled tasks'
foreach ($t in $zadaci) {
  $ima = $null -ne (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)
  if (-not $ima) { Nema "nema zadatka: $t"; continue }
  if ($Samoprovjera) { Inf "odjavio bi zadatak: $t"; continue }
  Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
  if ($null -ne (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue)) { Warn "zadatak nije odjavljen: $t" }
  else { Ok "zadatak odjavljen: $t" }
}

# ======================================================= 2. PROCESI =========
Head '2. Processes'
$nProcesa = 0
foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue)) {
  if ($p.ProcessId -eq $PID) { continue }
  $ime = [string]$p.Name
  $cl  = [string]$p.CommandLine
  $pogodak = $false
  if ($ime -like 'sunshine*')      { $pogodak = $true }
  if ($ime -like 'Luxstream-new*')  { $pogodak = $true }
  if ($ime -like 'luxstream*')      { $pogodak = $true }
  # Most je powershell.exe s putanjom skripte u naredbenoj liniji. Jednokratne
  # nacine rada preskacem da ne ubijem sam sebe (i sam sam s tom putanjom).
  if ($cl -like '*luxstream-bridge*' -and $cl -notmatch '-(Status|SelfTest|Install|Uninstall)\b') { $pogodak = $true }
  if (-not $pogodak) { continue }
  if ($Samoprovjera) { Inf "ubio bi proces: $ime (PID $($p.ProcessId))"; $nProcesa++; continue }
  Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  Ok "zaustavljen: $ime (PID $($p.ProcessId))"
  $nProcesa++
}
if ($nProcesa -eq 0) { Nema 'nema pokrenutih Luxstream procesa' }

# ======================================================= 3. MOST ============
Head '3. Bridge (clipboard / files)'
if (-not (Test-Path 'C:\ProgramData\Luxstream\bridge.json')) {
  Inf 'bridge.json nema - most nikad nije bio konfiguriran na ovom sustavu'
}
Obrisi-Datoteku 'C:\ProgramData\Luxstream\bridge.json'
Premjesti-Mapu 'C:\ProgramData\Luxstream' 'ProgramData-Luxstream'
Premjesti-Mapu (Join-Path $env:USERPROFILE 'Luxstream') 'Profil-Luxstream'
# Zajednicka tajna zivi samo u bridge.json, koji je gore obrisan.

# ======================================================= 4. VB-AUDIO ========
Head '4. VB-Audio virtual cable'
if ($ZadrziDrivere) {
  Inf 'preskacem (-ZadrziDrivere)'
} else {
  # Prvo provjeri je li kabel uopce prisutan. VB-CABLE se cesto ne instalira
  # (nije obavezan), a pokretanje setupa s `-u` na sustavu bez njega je samo
  # bespotrebno dizanje necijeg instalacijskog exe-a.
  $vb    = Nadji-Instalirani 'VB-?Audio*' '*VB\CABLE*'
  $vbInf = Nadji-IzdaniInf 'vbmmecable64_win10.inf'
  $vbDev = Nadji-Uredjaje 'vbmmecable'

  if (-not $vb -and -not $vbInf -and $vbDev.Count -eq 0) {
    Nema 'VB-Audio kabel nije instaliran - preskacem'
  } else {
    $objavljeno = $false

    if ($vbDev.Count -gt 0) { Inf "uredjaja kabela: $($vbDev.Count)" }
    if ($vbInf)             { Inf "driver paket u spremistu: $vbInf" }

    # 1) vlastiti deinstalater proizvodjaca, ako je prijavljen
    if ($vb -and $vb.UninstallString) {
      if ($Samoprovjera) { Inf "pokrenuo bi: $($vb.UninstallString)" }
      else {
        Inf "vlastiti deinstalater: $($vb.DisplayName)"
        $exe = ($vb.UninstallString -replace '^"([^"]+)".*$', '$1') -replace '^([^\s"]+)\s.*$', '$1'
        & $exe '-u' 2>&1 | Out-Null
        Start-Sleep -Seconds 3
        $objavljeno = $true
      }
    }

    # 2) ako nije, uzmi setup iz paketa (radi i nakon sto je paket obrisan,
    #    jer se ova faza izvrsava prije faze 11)
    if (-not $objavljeno) {
      $kand = @(
        'C:\Program Files\Luxstream\installers\vb-audio-cable\VBCABLE_Setup_x64.exe',
        'C:\Luxstream-setup\installers\vb-audio-cable\VBCABLE_Setup_x64.exe',
        'C:\Users\Public\sunshine-gpup-setup\installers\vb-audio-cable\VBCABLE_Setup_x64.exe'
      ) | Where-Object { Test-Path $_ } | Select-Object -First 1
      if ($kand) {
        if ($Samoprovjera) { Inf "pokrenuo bi: $kand -u" }
        else {
          Inf "deinstalater iz paketa: $kand"
          & $kand '-u' 2>&1 | Out-Null
          Start-Sleep -Seconds 3
          $objavljeno = $true
        }
      } else {
        Nema 'nema deinstalatera VB-Audio kabela'
      }
    }

    # 3) sigurnosna mreza: driver paket iz spremista, bez obzira na ishod gore.
    #    `-u` zna tisi, ali ne i siguran put; pnputil je dokaz da je paket otisao.
    Ukloni-Uredjaje 'vbmmecable' 'VB-Audio'
    if ($vbInf) {
      if ($Samoprovjera) { Inf "obrisao bi driver paket: $vbInf (vbmmecable64_win10.inf)" }
      else {
        $r = (& "$sys\pnputil.exe" /delete-driver $vbInf /uninstall /force 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) { Ok "driver paket uklonjen: $vbInf (VB-Audio)" } else { Warn "VB-Audio paket nije uklonjen: $vbInf"; Dnevnik $r }
      }
    } else { Nema 'VB-Audio driver paket nije u spremistu' }

    if (Test-Path 'C:\Program Files\VB\CABLE') {
      Inf 'ostala je mapa C:\Program Files\VB\CABLE - deinstalater je ne brise uvijek'
      Inf 'Ako je VB-CABLE dosao s Luxstreamom, obrisi je rucno.'
    }
  }
}

# ======================================================= 5. SUNSHINE ========
Head '5. Sunshine'
if ($ZadrziSunshine) {
  Inf 'preskacem (-ZadrziSunshine)'
} else {
  $msi = Nadji-Instalirani 'Sunshine*' '*Sunshine*'
  if ($msi) {
    $kod = $msi.PSChildName
    if ($Samoprovjera) { Inf "msiexec /x $kod   ($($msi.DisplayName))" }
    else {
      Inf "msiexec /x $kod   ($($msi.DisplayName))"
      $pr = Start-Process "$sys\msiexec.exe" -ArgumentList @('/x', $kod, '/qn', '/norestart') -PassThru -Wait
      if ($pr.ExitCode -in 0, 1641, 3010) { Ok "Sunshine MSI uklonjen ($($msi.DisplayName))" }
      else { Warn "msiexec vratio $($pr.ExitCode) - proizvod je mozda ostao" }
    }
  } else {
    Nema 'Sunshine nije u popisu instaliranih programa'
  }

  # sunshine.conf nosi pairing certifikate i uniqueid. Kopira se u karantenu
  # prije brisanja mape, da se postava moze vratiti bez ponovnog uparivanja.
  if (Test-Path 'C:\Program Files\Sunshine\config') {
    if ($Samoprovjera) { Inf "kopirao bi u karantenu: C:\Program Files\Sunshine\config" }
    else {
      New-Item -ItemType Directory -Path $karantena -Force | Out-Null
      Copy-Item 'C:\Program Files\Sunshine\config' (Join-Path $karantena 'sunshine-config') -Recurse -Force -ErrorAction SilentlyContinue
      Ok "Sunshine config kopiran u: $karantena\sunshine-config"
    }
  }
  Obrisi-Mapu 'C:\Program Files\Sunshine'
}

# ======================================================= 6. VDD =============
if ($ZadrziDrivere) {
  Head '6. Virtual display (VDD)'
  Inf 'preskacem (-ZadrziDrivere)'
} else {
  Ukloni-DriverPaket 'mttvdd.inf' 'MttVDD' '6. Virtual display (VDD)'
}

# ======================================================= 7. VIGEMBUS ========
if ($ZadrziDrivere) {
  Head '7. ViGEmBus (gamepad)'
  Inf 'preskacem (-ZadrziDrivere)'
} else {
  Ukloni-DriverPaket 'vigembus.inf' 'ViGEmBus' '7. ViGEmBus (gamepad)'
}

# ======================================================= 8. CERTIFIKATI =====
Head '8. Signing certificates'
if (-not $ObrisiCertifikate) {
  Inf 'preskacem - za uklanjanje pokreni s -ObrisiCertifikate'
  Inf 'Uvezani su potpisnici VDD-a (SignPath Foundation) i ViGEmBusa (Nefarius)'
  Inf 'u LocalMachine\TrustedPublisher i LocalMachine\Root.'
} else {
  Warn 'SignPath Foundation je javni CA. Njegovo uklanjanje iz Root moze'
  Warn 'utjecati i na DRUGI softver potpisan tim certifikatom.'
  $uzorci = @('SignPath', 'Nefarius', 'ViGEm')
  foreach ($spremiste in 'TrustedPublisher', 'Root') {
    $st = New-Object Security.Cryptography.X509Certificates.X509Store($spremiste, 'LocalMachine')
    try {
      $st.Open('ReadWrite')
      foreach ($c in @($st.Certificates)) {
        $hit = $false
        foreach ($u in $uzorci) { if ($c.Subject -like "*$u*") { $hit = $true } }
        if (-not $hit) { continue }
        if ($Samoprovjera) { Inf "obrisao bi cert iz ${spremiste}: $($c.Subject)"; continue }
        $st.Remove($c)
        Ok "cert uklonjen iz ${spremiste}: $($c.Subject)"
      }
    } catch { Warn "certifikati u ${spremiste}: $($_.Exception.Message)" } finally { $st.Close() }
  }
}

# ======================================================= 9. REGISTAR ========
Head '9. Registry'

# --- UAC ---
# INSTALL je postavio PromptOnSecureDesktop = 0 da bi se UAC dijalog vidio i
# mogao kliknuti preko Moonlighta. Windows zadana vrijednost je 1.
# ConsentPromptBehaviorAdmin ostaje 5 - to je ionako Windows zadano.
Postavi-Vrijednost 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' `
  'PromptOnSecureDesktop' 1 'DWord' 'UAC dijalog natrag na sigurni desktop'

# --- automatska prijava ---
# Samo AutoAdminLogon = 0 je dovoljno; LSA tajna DefaultPassword ostaje, ali se
# bez AutoAdminLogon = 1 ne koristi (vidi postavi-auto-prijavu.ps1).
$wl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Postavi-Vrijednost $wl 'AutoAdminLogon'   '0'    'String' 'iskljuci automatsku prijavu'
Obrisi-Vrijednost   $wl 'DefaultUserName'        'pocisti korisnika automatske prijave'
Obrisi-Vrijednost   $wl 'DefaultDomainName'      'pocisti domenu automatske prijave'
Postavi-Vrijednost 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' `
  'LimitBlankPasswordUse' 1 'DWord' 'vrati ogranicenje praznih lozinki'
Inf 'LSA tajna DefaultPassword se ne moze ukloniti skriptom; bez AutoAdminLogon=1 je mrtva.'

# --- GameDVR / Game Bar ---
$gdvr = @(
  @{ P = 'HKCU:\System\GameConfigStore';                            N = 'GameDVR_Enabled' },
  @{ P = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; N = 'AppCaptureEnabled' },
  @{ P = 'HKCU:\SOFTWARE\Microsoft\GameBar';                        N = 'ShowStartupPanel' },
  @{ P = 'HKCU:\SOFTWARE\Microsoft\GameBar';                        N = 'UseNexusForGameBarEnabled' }
)
foreach ($k in $gdvr) { Postavi-Vrijednost $k.P $k.N 1 'DWord' 'GameDVR / Game Bar natrag na ukljuceno' }

$polG = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'
if (Test-Path $polG) {
  if ($Samoprovjera) { Inf "obrisao bi politiku: $polG" }
  else { Remove-Item $polG -Recurse -Force -ErrorAction SilentlyContinue; Ok "politika uklonjena: $polG (AllowGameDVR)" }
} else { Nema "nema politike: $polG" }

# --- DPI ---
# SPI_SETLOGICALDPIOVERRIDE prima RELATIVNI pomak; INSTALL je isao na -4 (100 %).
# 0 vraca Windowsovu preporuku. Nije zapis u registryju nego poziv u user32.
if ($Samoprovjera) {
  Inf 'vratio bi DPI na Windowsovu preporuku (SPI_SETLOGICALDPIOVERRIDE = 0)'
} else {
  try {
    $sig = 'using System;using System.Runtime.InteropServices;public class DpiVrati {[DllImport("user32.dll", SetLastError=true)]public static extern bool SystemParametersInfo(uint a,uint u,IntPtr p,uint f);}'
    if (-not ('DpiVrati' -as [type])) { Add-Type -TypeDefinition $sig }
    $r = [DpiVrati]::SystemParametersInfo(0x009F, [uint32]0, [IntPtr]::Zero, 3)
    if ($r) { Ok 'DPI vracen na Windowsovu preporuku (100 % -> preporuceno)' } else { Warn 'DPI nije vracen' }
  } catch { Warn "DPI: $($_.Exception.Message)" }
}
Inf 'Napomena: ovaj dio vazi za KORISNIKA koji je pokrenuo skript (HKCU).'

# ======================================================= 10. VATROZID =======
Head '10. Firewall'
$pravila = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like 'Luxstream*' })
if ($pravila.Count -eq 0) { Nema 'nema Luxstream pravila u vatrozidu' }
foreach ($r in $pravila) {
  if ($Samoprovjera) { Inf "obrisao bi pravilo: $($r.DisplayName)"; continue }
  Remove-NetFirewallRule -Name $r.Name -ErrorAction SilentlyContinue
  Ok "pravilo uklonjeno: $($r.DisplayName)"
}

# ======================================================= 11. DATOTEKE =======
Head '11. Files and leftovers'
foreach ($p in $programMape) { Obrisi-Mapu $p }

# Precac u Start izborniku koji INSTALL napravi (za sve korisnike)
$precacMapa = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Luxstream'
Obrisi-Datoteku (Join-Path $precacMapa 'Uninstall Luxstream.lnk')
if (Test-Path $precacMapa) {
  $ostalo = @(Get-ChildItem $precacMapa -Force -ErrorAction SilentlyContinue)
  if ($ostalo.Count -eq 0) { Obrisi-Mapu $precacMapa }
  else { Inf "ostavljam $precacMapa - sadrzi i: $((@($ostalo | ForEach-Object { $_.Name }) -join ', '))" }
}

Obrisi-Datoteku 'C:\Users\Public\Luxstream.exe'

$public = 'C:\Users\Public'
foreach ($f in 'luxstream-install.log', 'boot-verify.txt', 'streamready-primed.txt') {
  Obrisi-Datoteku (Join-Path $public $f)
}

# backup mape i .reg koje su INSTALL i njegove faze napravile
foreach ($uzorak in 'sunshine-config-backup-*', 'sunshine-identitet-stari-*') {
  $m = @(Get-ChildItem $public -Directory -Filter $uzorak -ErrorAction SilentlyContinue)
  if ($m.Count -eq 0) { Nema "nema backup mape: $uzorak" }
  foreach ($d in $m) {
    if ($Samoprovjera) { Inf "obrisao bi backup: $($d.FullName)" }
    else { Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue; Ok "backup obrisan: $($d.FullName)" }
  }
}
$reg = @(Get-ChildItem $public -File -Filter 'gamedvr-backup-*.reg' -ErrorAction SilentlyContinue)
foreach ($d in $reg) { Obrisi-Datoteku $d.FullName }

Obrisi-Datoteku (Join-Path $env:TEMP 'luxstream-sfx.txt')

# ======================================================= SAZETAK ============
Write-Host ''
Write-Host '  -------------------------------'
if ($Samoprovjera) {
  Write-Host '  DRY RUN finished - nothing was changed.' -ForegroundColor Yellow
} elseif ($greske -gt 0) {
  Warn "$greske koraka nije proslo - pogledaj $dnevnik"
} else {
  Ok 'All steps passed.'
}

if (-not $Obrisi) {
  if (Test-Path $karantena) { Ok "Podaci su u karanteni: $karantena" }
  else { Inf 'Nije bilo korisnickih podataka za karantenu.' }
}
Inf "Dnevnik: $dnevnik"

if (-not $Samoprovjera) {
  Write-Host ''
  Write-Host '  RESTART IS REQUIRED' -ForegroundColor Yellow
  Write-Host '  Uklonjeni su driveri i vracena je topologija displaya. Bez ponovnog' -ForegroundColor Yellow
  Write-Host '  pokretanja mogu ostati neaktivni uredjaji i pogresna rezolucija.' -ForegroundColor Yellow
}
Dnevnik "=== UNINSTALL finished $(Get-Date -Format o)  greske=$greske"
Write-Host ''
