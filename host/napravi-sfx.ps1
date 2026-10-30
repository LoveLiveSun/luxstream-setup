<#
    napravi-sfx.ps1

    Sklapa cijeli paket u JEDNU izvrsnu datoteku - Luxstream.exe.

    STO DOBIVAS
      Jedna ikona. Dvoklik -> raspakira se u C:\Luxstream-setup i pokrene
      INSTALL.cmd. Nema mape, nema .zip, nema rucnog raspakiravanja.

    ZASTO SFX, A NE MSI
      MSI-jeve akcije izvrsava msiexec, a odgodjene idu kao SYSTEM u sesiji 0.
      Nasa instalacija trazi upravo suprotno: WGC ne radi kao SYSTEM, promjene
      topologije displaya iz sesije 0 ne diraju korisnikov desktop, priming mora
      ici s konzole, a lozinka za automatsku prijavu se upisuje interaktivno.
      MSI bi se s time tukao na svakom koraku.

    ZASTO WinRAR.exe A NE Rar.exe
      Konzolni Rar.exe NE podrzava -iicon (vlastitu ikonu) - vrati kod 6.
      GUI WinRAR.exe je podrzava, a s -ibck radi u pozadini bez prozora.

    PREDUVJETI
      - WinRAR (provjereno s 5.61 i 7.23), registriran
      - Luxstream.ico  ->  napravi ga host\napravi-ikonu.ps1

    PAZI NA IME SFX MODULA
      64-bitni modul se zove drugacije ovisno o verziji: 5.x ima
      Default64.SFX, a 6.x/7.x drzi 64-bitni modul u Default.SFX (uz
      Default32.SFX kao 32-bitni). Skript zato modul trazi po PE
      arhitekturi, a ne po imenu - s fiksnim imenom `-sfxDefault64.SFX`
      noviji WinRAR vrati kod 6 i nista se ne izgradi.

    UPOTREBA
      .\napravi-sfx.ps1
      .\napravi-sfx.ps1 -Izlaz 'C:\Users\Public\Luxstream.exe'
#>
[CmdletBinding()]
param(
  [string]$Paket  = 'C:\Users\Public\sunshine-gpup-setup',
  [string]$Izlaz  = 'C:\Users\Public\Luxstream.exe',
  [string]$Ikona  = 'C:\Users\Public\sunshine-gpup-setup\host\Luxstream.ico',
  [string]$WinRar = 'C:\Program Files\WinRAR\WinRAR.exe'
)

$ErrorActionPreference = 'Stop'
function Ok ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Inf($m) { Write-Host "  [..]   $m" }
function Bad($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red }

Write-Host ''
Write-Host '  Luxstream - building the single executable' -ForegroundColor White
Write-Host '  ============================================='

foreach ($p in @($Paket, $Ikona, $WinRar)) {
  if (-not (Test-Path $p)) { Bad "missing $p"; return }
}
if (-not (Test-Path (Join-Path $Paket 'INSTALL.cmd'))) { Bad "the package has no INSTALL.cmd"; return }

# --- 64-BITNI SFX MODUL ---
# Ime modula se mijenjalo izmedju verzija WinRAR-a: 5.x drzi 64-bitni modul u
# Default64.SFX, a 6.x/7.x ga drzi u Default.SFX (32-bitni je tada Default32.SFX).
# Zato se modul NE bira po imenu nego po stvarnoj arhitekturi iz PE zaglavlja -
# ime se moze promijeniti, arhitektura ne moze.
#
# 32-bitni modul ne dolazi u obzir ni kao rezerva: tada se procesu System32
# preusmjeri na SysWOW64 i pnputil/query "ne postoje" (vidi napomenu na vrhu
# INSTALL.ps1). Bolje pasti odmah nego isporuciti instalater koji to ne vidi.
function Get-PeArh([string]$put) {
  $fs = [System.IO.File]::OpenRead($put)
  try {
    $br = New-Object System.IO.BinaryReader($fs)
    $fs.Position = 0x3C
    $pe = $br.ReadInt32()
    if ($pe -le 0 -or $pe -gt ($fs.Length - 6)) { return $null }
    $fs.Position = $pe + 4
    switch ($br.ReadUInt16()) { 0x8664 { 'x64' } 0x014C { 'x86' } default { 'drugo' } }
  } catch { $null } finally { $fs.Close() }
}

$sfxModul = $null
foreach ($k in 'Default64.SFX', 'Default.SFX') {
  $p = Join-Path (Split-Path $WinRar -Parent) $k
  if ((Test-Path $p) -and ((Get-PeArh $p) -eq 'x64')) { $sfxModul = $k; break }
}
if (-not $sfxModul) {
  Bad 'no 64-bit SFX module next to WinRAR.exe - refusing to build a 32-bit installer'
  Inf 'WinRAR 5.x: Default64.SFX   WinRAR 6.x/7.x: Default.SFX'
  return
}
Inf "SFX module: $sfxModul (x64)"

# --- SFX konfiguracija ---
# Path      kamo se raspakira
# Setup     sto se pokrene nakon raspakiravanja
# Overwrite prepisi bez pitanja, da ponovna instalacija ne zapinje
$konf = Join-Path $env:TEMP 'luxstream-sfx.txt'
@'
;Luxstream SFX
Path=C:\Luxstream-setup
Setup=INSTALL.cmd
Overwrite=1
Silent=0
Title=Luxstream installer
Text
{
Luxstream sets up Sunshine game streaming on a Hyper-V guest with a GPU-P
partition.

The package will be extracted to C:\Luxstream-setup and the installer will
start. It will ask for administrator rights and for a password used for
automatic logon.

IMPORTANT - run this from the Hyper-V console in BASIC SESSION, not through
Enhanced Session or RDP. Those give the VM their own temporary display, so the
graphics cannot be configured.

Mid-install THE SCREEN WILL GO BLANK for about half a minute, together with
keyboard and mouse. That is expected - the virtual display is starting.
Do not close anything.

When it finishes, the Hyper-V display becomes secondary, so in Basic Session
you will see the desktop but will not be able to control it. That is your
signal to switch to Enhanced Session or RDP so you can operate the VM and click
the host in Moonlight - pairing completes on its own, with no PIN.

To remove everything again later: Start Menu -> "Uninstall Luxstream", or
C:\Program Files\Luxstream\Luxstream-ODINSTALIRAJ.cmd (-Samoprovjera to preview).
}
'@ | Set-Content $konf -Encoding Default
Inf 'SFX configuration prepared'

if (Test-Path $Izlaz) { [System.IO.File]::Delete($Izlaz) }

Push-Location $Paket
try {
  $argumenti = @(
    'a',                    # dodaj u arhivu
    '-r',                   # rekurzivno
    '-ep1',                 # bez pocetne mape u putanjama
    '-m5',                  # najjaca kompresija
    "-sfx$sfxModul",        # modul odabran gore, po PE arhitekturi (mora biti x64)
    '-xDISTRIBUCIJA.md',    # interna biljeska o objavi - ne ide u paket
    '-x.git',               # povijest repozitorija ne smije u instalater: paket
                            # se gradi izravno iz radnog stabla, pa bi .git
                            # (desetke MB, i sve sto je ikad commitano) zavrsio
                            # u tudjem VM-u
    '-x.gitattributes',     # nije dio isporuke (vidi .gitignore u paketu)
    '-ibck',                # u pozadini, bez prozora
    "-iicon$Ikona",         # vlastita ikona (samo WinRAR.exe, ne Rar.exe)
    "-z$konf",              # SFX konfiguracija
    '-y',                   # na sve odgovori da
    $Izlaz,
    '*'
  )
  $p = Start-Process $WinRar -ArgumentList $argumenti -PassThru -Wait
  if ($p.ExitCode -ne 0) { Bad "WinRAR exit code $($p.ExitCode)"; return }
} finally { Pop-Location }

if (-not (Test-Path $Izlaz)) { Bad 'the executable was not created'; return }
Ok ('{0}  {1:N1} MB' -f (Split-Path $Izlaz -Leaf), ((Get-Item $Izlaz).Length/1MB))

# --- provjere, da se ne salje nesto neprovjereno ---
$unrar = Join-Path (Split-Path $WinRar -Parent) 'UnRAR.exe'
if (Test-Path $unrar) {
  # UnRAR je lokaliziran: na hrvatskom Windowsu pise "Sve je OK", na kineskom
  # "全部正常" itd. Uspjeh se zato NE cita iz teksta poruke (engleski "All OK"
  # nikad se ne pojavi) nego iz izlaznog koda - 0 znaci da je arhiva ispravna.
  $test = & $unrar t $Izlaz 2>&1 | Out-String
  $rc = $LASTEXITCODE
  if ($rc -eq 0) { Ok 'archive integrity: OK' }
  else {
    Bad "integrity test failed (UnRAR exit $rc)"
    Inf ($test -split "`r?`n" | Where-Object { $_ -ne '' } | Select-Object -Last 3)
  }

  $popis = & $unrar lb $Izlaz 2>&1
  # Zakrpani sunshine.exe se dostavlja kao zasebna datoteka koju INSTALL.ps1
  # preslika preko MSI-jevog, pa su oba dijela obavezna. MSI se prihvaca pod
  # bilo kojim imenom (vidi fazu 3 u INSTALL.ps1), zato ga trazim po uzorku.
  #
  # Deinstalater je OBAVEZAN dio isporuke: INSTALL.ps1 ga preslika u
  # C:\Program Files\Luxstream i prema njemu napravi precac u Start izborniku.
  # Bez njega u paketu korisnik ostane bez nacina da ovo sve ukloni, pa se
  # build ovdje prekida umjesto da se tiho isporuci nepotpun instalater.
  foreach ($n in 'INSTALL.cmd', 'INSTALL.ps1', 'UNINSTALL.ps1', 'Luxstream-ODINSTALIRAJ.cmd',
                 'UNINSTALL.cmd', 'installers\sunshine\Sunshine.exe') {
    if ($popis -contains $n) { Ok "in archive: $n" } else { Bad "MISSING: $n" }
  }
  $msiU = @($popis | Where-Object { $_ -like 'installers\sunshine\*.msi' })
  if ($msiU.Count -gt 0) { Ok "in archive: $($msiU[0])" } else { Bad 'MISSING: installers\sunshine\*.msi' }
  # `.git` na pocetku bi znacilo da je paket slucajno graden izravno iz klona
  $gitU = @($popis | Where-Object { $_ -like '.git\*' })
  if ($gitU.Count -eq 0) { Ok 'no repository history in the archive' }
  else { Bad "the archive carries .git ($($gitU.Count) entries)" }
}

Add-Type -AssemblyName System.Drawing
try {
  $i = [System.Drawing.Icon]::ExtractAssociatedIcon($Izlaz)
  Ok "icon embedded ($($i.Width)x$($i.Height))"
  $i.Dispose()
} catch { Bad "icon could not be read: $($_.Exception.Message)" }

Write-Host ''
Write-Host '  Put Luxstream.exe on \\server\share - that is all the user needs.' -ForegroundColor Cyan
Write-Host ''
