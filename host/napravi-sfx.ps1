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
      - WinRAR (provjereno s 5.61), registriran
      - Luxstream.ico  ->  napravi ga host\napravi-ikonu.ps1

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
signal to switch to Enhanced Session or RDP and finish pairing with Moonlight.
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
    '-sfxDefault64.SFX',    # 64-BITNI modul. Zadani Default.SFX je 32-bitni, a
                            # tada se procesu System32 preusmjeri na SysWOW64 i
                            # pnputil/query " ne postoje ".
    '-xDISTRIBUCIJA.md',    # interna biljeska o objavi - ne ide u paket
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
  $test = & $unrar t $Izlaz 2>&1 | Out-String
  if ($test -match 'All OK') { Ok 'archive integrity: All OK' }
  else { Bad 'integrity test failed' }

  $popis = & $unrar lb $Izlaz 2>&1
  foreach ($n in 'INSTALL.cmd', 'INSTALL.ps1', 'installers\sunshine\Luxstream-Sunshine-patched.msi') {
    if ($popis -contains $n) { Ok "in archive: $n" } else { Bad "MISSING: $n" }
  }
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
