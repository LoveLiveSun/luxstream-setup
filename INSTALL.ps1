<#
    INSTALL.ps1 - jedna instalacija za cijelu postavu

    Postavi Sunshine streaming s izvornim Vulkanom, OpenGL-om i DirectX-om na
    Hyper-V gostu s GPU-P particijom. Pokrece se JEDNOM na svjezem VM-u.

    POKRETANJE (iz POVISENOG PowerShella):
        powershell -ExecutionPolicy Bypass -File .\INSTALL.ps1

    Moze se pokretati vise puta - svaki korak provjerava zateceno stanje i
    preskace ono sto je vec napravljeno.

    OPCIJE
        -PreskociUac        ne dira UAC postavku (vidi faza 6)
        -PreskociAudio      ne instalira VB-Audio virtualni kabel
        -SamoProvjera       samo preflight, nista ne mijenja
        -PrisiliSunshine    reinstaliraj Sunshine i kad je verzija ista
        -NoviIdentitet      prisili nov certifikat i uniqueid (klon VM-a)
        -PreskociUiAccess   ne dira manifest ni potpis Sunshinea
        -PreskociAutoPrijavu ne postavlja automatsku prijavu
        -Gpu "ime"          ime GPU-a za VDD; inace se otkriva samo

    STO RADI, redom

      0. preflight        elevacija, sesija, GPU-P particija, driver u gostu
      1. driveri          VDD, ViGEmBus, VB-Audio
      2. VDD konfiguracija  vezanje na GPU + lista modova, restart drivera
      3. Sunshine         instalacija zakrpanog builda
      4. Sunshine config  otkrivanje GUID-a displaya iz loga, pisanje sunshine.conf
      5. zadaci           SunshineUser, StreamReady, RestoreConsoleSession
      6. prilagodbe       DPI, Game Bar, (opcionalno) UAC
      7. priming i provjera

    ZASTO JE OVAKO - sazetak izmjerenih pravila

      * Desktop Duplication na GPU-P gostu NE RADI (0x80070057). Zato zakrpani
        Sunshine s `capture = wgc`.
      * Sunshine NE MOZE raditi kao servis: kao SYSTEM ne moze aktivirati
        Windows.Graphics.Capture (`std::bad_alloc` iz RoGetActivationFactory).
        Zato zadatak SunshineUser koji ga pokrece kao korisnika.
      * Izvorni Vulkan/OpenGL traze da je NVIDIA-in display put bio AKTIVAN i
        ISKORISTEN barem jednom od podizanja sustava. Zato priming: aktiviraj
        Hyper-V display, pokreni test grafike, pa ga deaktiviraj. Nakon toga
        ostaje JEDAN display, a grafika radi.
      * `dd_configuration_option` mora biti `verify_only` - `ensure_active`
        ponovno aktivira Hyper-V display i ponisti postavu.
      * Konfiguracija se pise BEZ BOM-a, inace Sunshine tiho ignorira prvi kljuc.
#>
[CmdletBinding()]
param(
  [switch]$PreskociUac,
  [switch]$PreskociAudio,
  [switch]$SamoProvjera,
  [switch]$PrisiliSunshine,
  [switch]$NoviIdentitet,
  [switch]$PreskociUiAccess,
  [switch]$PreskociAutoPrijavu,
  [string]$Gpu
)

$ErrorActionPreference = 'Continue'

# 32-BITNI PROCES NE SMIJE DALJE.
# Na 64-bitnom Windowsu se 32-bitnom procesu C:\Windows\System32 tiho
# preusmjerava na SysWOW64 (WOW64 redirection). Ondje NEMA pnputil.exe ni
# query.exe - oni postoje samo u pravom, 64-bitnom System32. Posljedica je
# podmukla: putanja izgleda ispravno, a alat "ne postoji".
#
# Izmjereno 24.8.2026. na VM-u G10: SFX je pokrenuo 32-bitni proces, pnputil
# nije nadjen, VDD se nije instalirao, a provjera sesije je lazno javila RDP.
#
# Sysnative je vrata iz 32-bitnog procesa u pravi System32.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
  $ps64 = Join-Path $env:SystemRoot 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
  if (Test-Path $ps64) {
    Write-Host '  Switching to 64-bit PowerShell (the 32-bit one is missing pnputil and other tools)...' -ForegroundColor Yellow
    $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $MyInvocation.MyCommand.Path)
    foreach ($k in $PSBoundParameters.GetEnumerator()) {
      if ($k.Value -is [switch]) { if ($k.Value.IsPresent) { $a += "-$($k.Key)" } }
      else { $a += "-$($k.Key)"; $a += "$($k.Value)" }
    }
    $p = Start-Process $ps64 -ArgumentList $a -PassThru -Wait -NoNewWindow
    exit $p.ExitCode
  } else {
    Write-Host '  WARNING: 32-bit process and Sysnative is unavailable. Tools will be missing.' -ForegroundColor Red
  }
}
$korijen  = Split-Path $MyInvocation.MyCommand.Path -Parent
$skripte  = Join-Path $korijen 'scripts'
$instal   = Join-Path $korijen 'installers'
$dnevnik  = 'C:\Users\Public\luxstream-install.log'
$greske   = 0

# Proces kojeg pokrene SFX zna doci BEZ System32 u PATH-u. Tada `query`,
# `pnputil`, `takeown` i ostalo naprosto ne postoje, a posljedice su podmukle:
# 24.8.2026. na VM-u G10 je zbog toga provjera sesije pala, instalater je
# zakljucio "RDP" iako je korisnik bio na konzoli, preskocio faze 4 i 7, a VDD
# se nije instalirao jer pnputil nije nasao driver.
# Zato se PATH popravlja, a svi vanjski alati zovu punom putanjom.
$sys = Join-Path $env:SystemRoot 'System32'
foreach ($p in @($sys, (Join-Path $sys 'WindowsPowerShell\v1.0'), (Join-Path $env:SystemRoot 'SysWOW64'))) {
  if ((Test-Path $p) -and ($env:PATH -notlike "*$p*")) { $env:PATH = "$p;$env:PATH" }
}

# Na svakom prijelazu faze vrati konzolu na glavni zaslon. Instalacija vise puta
# mijenja topologiju i pali tudje procese koji dolaze u prvi plan, pa prozor zna
# zavrsiti na zaslonu kojeg vise nema - korisnik tada gleda prazan desktop.
function Head($m) {
  if (Get-Command Vrati-Prozor -ErrorAction SilentlyContinue) { Vrati-Prozor }
  Write-Host "`n=== $m" -ForegroundColor Cyan
  Add-Content $dnevnik "`n=== $m"
}
function Ok  ($m) { Write-Host "  [OK]   $m" -ForegroundColor Green;  Add-Content $dnevnik "  [OK]   $m" }
function Inf ($m) { Write-Host "  [..]   $m";                          Add-Content $dnevnik "  [..]   $m" }
function Warn($m) { Write-Host "  [!]    $m" -ForegroundColor Yellow;  Add-Content $dnevnik "  [!]    $m" }
function Bad ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;     Add-Content $dnevnik "  [FAIL] $m"; $script:greske++ }

# Vraca $true/$false umjesto da baci. Ranije je iznimka bila samo ispisana (jer
# je ErrorActionPreference = Continue), a odmah zatim se javio [OK] - lazno.
#
# Pisanje u C:\VirtualDisplayDriver\vdd_settings.xml zna pasti s "Access denied"
# iz VISE razloga, pa se probaju redom:
#   1. atribut samo-za-citanje - takeown i icacls ga NE diraju
#   2. ACL - rjesava takeown + icacls
#   3. tudji otvoreni handle - rjesava pisanje u novu datoteku pa zamjena
# Vidjeno 23.8.2026. na VM-u G10: prva dva pokusaja pala, VDD je ostao sa
# zadanim postavkama.
function Zapisi-BezBom([string]$put, [string[]]$redci) {
  $utf = New-Object System.Text.UTF8Encoding($false)

  function Probaj {
    try { [System.IO.File]::WriteAllLines($put, $redci, $utf); return $true }
    catch { return $false }
  }

  if (Probaj) { return $true }

  # 1. skini atribute - najcesci uzrok, a nitko ga ne ocekuje
  if (Test-Path $put) {
    try {
      $fi = Get-Item $put -Force
      if ($fi.Attributes -band [IO.FileAttributes]::ReadOnly -or
          $fi.Attributes -band [IO.FileAttributes]::Hidden -or
          $fi.Attributes -band [IO.FileAttributes]::System) {
        Inf "  $($fi.Name): clearing attributes $($fi.Attributes)"
        $fi.Attributes = [IO.FileAttributes]::Normal
      }
    } catch { }
    if (Probaj) { return $true }
  }

  # 2. vlasnistvo i dozvole
  $mapa = Split-Path $put -Parent
  Inf '  taking ownership and widening permissions'
  & "$sys\takeown.exe" /f $mapa /r /d y 2>&1 | Out-Null
  & "$sys\icacls.exe" $mapa /grant "*S-1-5-32-544:(OI)(CI)F" /t 2>&1 | Out-Null
  if (Test-Path $put) { & "$sys\attrib.exe" -r -h -s $put 2>&1 | Out-Null }
  if (Probaj) { return $true }

  # 3. netko drzi datoteku otvorenu - napisi novu pa zamijeni
  try {
    Inf '  writing to a new file, then replacing'
    $priv = "$put.novi"
    [System.IO.File]::WriteAllLines($priv, $redci, $utf)
    $staro = "$put.staro-$(Get-Date -Format 'HHmmss')"
    if (Test-Path $put) { Move-Item $put $staro -Force -ErrorAction Stop }
    Move-Item $priv $put -Force -ErrorAction Stop
    return $true
  } catch {
    Bad "cannot write $put : $($_.Exception.Message)"
    return $false
  }
}


# ---------------------------------------------------------------- PROZOR
# Kad se promijeni topologija displaya, konzolni prozor ostane na starom
# zaslonu - onom koji je nestao ili je postao sekundaran. Korisnik tada gleda
# PRAZAN DESKTOP i ne zna je li se instalacija zablokirala.
# Prijavljeno 24.8.2026.: "kad prebacuje i instalira VDD izgubi se cmd sucelje,
# ne vidi se nego prazan desktop".
#
# Zato se prozor nakon svake takve promjene vrati na trenutni GLAVNI zaslon i
# digne u prvi plan.
if (-not ('PROZOR' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PROZOR {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr a, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public const uint SWP_NOSIZE = 0x0001, SWP_NOZORDER = 0x0004, SWP_SHOWWINDOW = 0x0040;
  public const int SW_RESTORE = 9;
}
'@
}

function Vrati-Prozor {
  try {
    $h = [PROZOR]::GetConsoleWindow()
    if ($h -eq [IntPtr]::Zero) { return }

    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    # svjez podatak o zaslonima - AllScreens se kesira po procesu, pa se
    # osvjezava preko novog upita na tip
    $glavni = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Primary } | Select-Object -First 1
    if (-not $glavni) { return }

    $r = New-Object PROZOR+RECT
    [void][PROZOR]::GetWindowRect($h, [ref]$r)
    $sirina = $r.Right - $r.Left
    $visina = $r.Bottom - $r.Top

    $ga = $glavni.WorkingArea
    $naGlavnom = ($r.Left -ge $ga.Left -and $r.Top -ge $ga.Top -and
                  $r.Right -le $ga.Right -and $r.Bottom -le $ga.Bottom)

    # Premjestaj samo ako je odlutao. Ali U SVAKOM SLUCAJU ga digni u prvi plan -
    # ranije se izlazilo cim je prozor bio na pravom zaslonu, pa se prekriven
    # prozor (npr. Sunshineovim) nikad nije vracao naprijed.
    [void][PROZOR]::ShowWindow($h, [PROZOR]::SW_RESTORE)
    if (-not $naGlavnom) {
      $x = [Math]::Max($ga.Left, $ga.Left + [int](($ga.Width - $sirina) / 2))
      $y = [Math]::Max($ga.Top,  $ga.Top + 40)
      [void][PROZOR]::SetWindowPos($h, [IntPtr]::Zero, $x, $y, 0, 0,
                ([PROZOR]::SWP_NOSIZE -bor [PROZOR]::SWP_NOZORDER -bor [PROZOR]::SWP_SHOWWINDOW))
    }
    [void][PROZOR]::SetForegroundWindow($h)
  } catch { }
}
Set-Content $dnevnik "===== INSTALL $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') =====" -Encoding UTF8
Write-Host ''
Write-Host '  Luxstream - Sunshine on a Hyper-V GPU-P guest' -ForegroundColor White
Write-Host '  ============================================'

# ============================================================ 0. PREFLIGHT
Head '0. Preflight'

$id = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
  Bad 'Not running as administrator. Open PowerShell as administrator and run again.'
  return
}
Ok "Administrator: $($id.Name)"

# Ne pita postoji li konzolna sesija nego jesmo li MI na njoj. `query user`
# oznaci tekucu sesiju znakom > na pocetku retka. Ranije je provjera prolazila
# i kad se instalira preko RDP-a dok konzola stoji prijavljena, pa je faza 7
# poslije rekla "sesija nije na konzoli" i tiho preskocila priming. Vidjeno na G10.
# Pitaj WINDOWS, ne vanjski alat. `query user` je ovisio o System32 u PATH-u i
# o raspoznavanju teksta; kad ga nije bilo, izlaz je bio prazan i instalater je
# iz "ne mogu izmjeriti" zakljucio "sigurno RDP". To je 24.8.2026. na G10
# preskocilo faze 4 i 7 iako je korisnik bio na konzoli.
#
# GetSystemMetrics(SM_REMOTESESSION) vraca izravan odgovor: jesmo li u sesiji
# udaljene radne povrsine. Bez vanjskih alata i bez raspoznavanja teksta.
if (-not ('SESIJA' -as [type])) {
  Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class SESIJA {
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  public const int SM_REMOTESESSION = 0x1000;
  public static bool Udaljena() { return GetSystemMetrics(SM_REMOTESESSION) != 0; }
}
'@
}

if ([SESIJA]::Udaljena()) {
  # Hyper-V Enhanced Session is RDP under the hood, so SM_REMOTESESSION catches
  # it too - which is exactly what we want. Both give the VM their own temporary
  # display, and the installer then cannot see or configure the real ones.
  Write-Host ''
  Write-Host '  ############################################################' -ForegroundColor Red
  Write-Host '   WRONG KIND OF CONNECTION' -ForegroundColor Red
  Write-Host '  ############################################################' -ForegroundColor Red
  Write-Host ''
  Write-Host '  You are connected through Remote Desktop or Hyper-V Enhanced'
  Write-Host '  Session. The graphics cannot be set up this way.'
  Write-Host ''
  Write-Host '  Why: both give the VM their own temporary display. The real'
  Write-Host '  displays - the Hyper-V one and the virtual one - are not visible'
  Write-Host '  from here, so they cannot be configured.'
  Write-Host ''
  Write-Host '  HOW TO FIX IT' -ForegroundColor Cyan
  Write-Host ''
  Write-Host '    1. Close this window and disconnect from the VM.'
  Write-Host ''
  Write-Host '    2. On the HOST, open Hyper-V Manager.'
  Write-Host ''
  Write-Host '    3. Right-click this VM  ->  Connect'
  Write-Host ''
  Write-Host '    4. In the connection window open the View menu and'
  Write-Host '       TURN OFF "Enhanced Session".'
  Write-Host '       If it asks about display settings when connecting,'
  Write-Host '       choose the basic option, not the enhanced one.'
  Write-Host ''
  Write-Host '    5. Run this installer again from there.'
  Write-Host ''
  Write-Host '  ############################################################' -ForegroundColor Red
  Write-Host ''
  Write-Host '  If you continue anyway, drivers, Sunshine, tasks and tweaks will'
  Write-Host '  install, but the graphics will NOT be configured. You would have'
  Write-Host '  to run the installer once more from a Basic Session.'
  Write-Host ''

  if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
    $odg = Read-Host '  Continue anyway? Type YES to continue, anything else aborts'
    if ($odg -ne 'YES') {
      Write-Host ''
      Write-Host '  Aborted. Nothing was changed.' -ForegroundColor Yellow
      Write-Host '  Reconnect in Basic Session and run this again.' -ForegroundColor Yellow
      Write-Host ''
      return
    }
    Warn 'Continuing over RDP at your request - graphics will be skipped.'
  } else {
    Warn 'No interactive console - continuing, but graphics will be skipped.'
  }
  $prekoRdp = $true
} else {
  Ok 'Local session (console) - graphics can be set up'
  $prekoRdp = $false
}

$os = Get-CimInstance Win32_OperatingSystem
Ok "$($os.Caption), build $($os.BuildNumber)"

# GPU-P particija se u gostu vidi kao Microsoft Virtual Render Driver (VEN_1414&DEV_008E)
$gpup = Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -match 'VEN_1414&DEV_008E' -and $_.Status -eq 'OK' }
if ($gpup) {
  Ok "GPU-P partition: $($gpup[0].FriendlyName)"
  if (-not $Gpu) { $Gpu = $gpup[0].FriendlyName }
} else {
  Bad 'GPU-P partition not found. Check Add-VMGpuPartitionAdapter on the host.'
}

# driver se kod GPU-P-a KOPIRA u HostDriverStore, ne instalira
$hds = 'C:\Windows\System32\HostDriverStore\FileRepository'
$nv  = Get-ChildItem $hds -Directory -Filter 'nv_dispi.inf_*' -ErrorAction SilentlyContinue
if ($nv) { Ok "Driver in guest: $($nv[0].Name)" }
else     { Bad "No NVIDIA driver in $hds. Copy it from the host (must be the SAME version)." }

$hv = Get-PnpDevice -FriendlyName 'Microsoft Hyper-V Video' -ErrorAction SilentlyContinue
if ($hv -and $hv.Status -eq 'OK') { Ok 'Microsoft Hyper-V Video adapter is present' }
else { Bad 'No Hyper-V Video adapter. Without it there is no native Vulkan or OpenGL.' }

if ($greske -gt 0) { Write-Host "`n$greske prerequisite(s) not met. Stopping." -ForegroundColor Red; return }
if ($SamoProvjera) { Write-Host "`nAll preflight checks passed (-SamoProvjera)." -ForegroundColor Green; return }




# ============================================================ USER INSTRUCTIONS
# Without this the user loses control mid-install and cannot tell whether
# something crashed. Reported 24.8.2026. during the G10 install.
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Yellow
Write-Host '   READ THIS BEFORE WE START' -ForegroundColor Yellow
Write-Host '  ============================================================' -ForegroundColor Yellow
Write-Host ''
Write-Host '  HOW YOU MUST BE CONNECTED' -ForegroundColor Cyan
Write-Host ''
Write-Host '    Through the Hyper-V console, in BASIC SESSION.'
Write-Host '    In Hyper-V Manager: right-click the VM -> Connect.'
Write-Host '    If Enhanced Session is enabled under the View menu, TURN IT OFF.'
Write-Host ''
Write-Host '    Why: Enhanced Session and RDP give the VM their own temporary'
Write-Host '    display. The installer then cannot see the real displays and'
Write-Host '    cannot set up the graphics.'
Write-Host ''
Write-Host '  WHAT WILL HAPPEN' -ForegroundColor Cyan
Write-Host ''
Write-Host '    1) Mid-install THE SCREEN WILL GO BLANK for about half a minute.'
Write-Host '       Keyboard and mouse will not work either. This is expected -'
Write-Host '       the virtual display is being started. DO NOT close anything.'
Write-Host ''
Write-Host '    2) When the install finishes, in Basic Session you WILL SEE the'
Write-Host '       desktop but you WILL NOT BE ABLE TO CONTROL IT.'
Write-Host ''
Write-Host '       That is NOT a fault. From then on the primary display is the'
Write-Host '       virtual one, while Basic Session only shows the Hyper-V display,'
Write-Host '       which has become secondary. Mouse and keyboard work on the'
Write-Host '       primary display, which you cannot see there.'
Write-Host ''
Write-Host '       That is your signal that it is done: close Basic Session and'
Write-Host '       open Enhanced Session (or RDP). Steps follow at the end.' -ForegroundColor Cyan
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Yellow
Write-Host ''

if ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected) {
  Write-Host '  Press Enter to continue, or Ctrl+C to abort.' -ForegroundColor Cyan
  [void](Read-Host)
} else {
  Inf 'No interactive console - continuing without confirmation'
}
# ============================================================ 0b. UGRADNJA PAKETA
Head '0b. Installing the package'

# Zadaci (SunshineUser, StreamReady, RestoreConsoleSession, VerifyAfterBoot)
# pokazuju na skripte APSOLUTNOM putanjom. Ako se instalater pokrene iz ZIP-a
# raspakiranog na Desktopu, a ta se mapa poslije obrise, zadaci tiho prestanu
# raditi. Zato paket ide na stalno mjesto i zadaci se registriraju ODANDE.
$dom = 'C:\Program Files\Luxstream'

if ($korijen -eq $dom) {
  Ok "Already running from $dom"
} else {
  Inf "Copying the package to $dom"
  New-Item -ItemType Directory -Path $dom -Force | Out-Null
  # moonlight-client ide na KLIJENT, ne na VM; _stari je mrtav teret
  $izuzmi = @((Join-Path $korijen 'installers\moonlight-client'), (Join-Path $korijen 'installers\_stari'))
  & "$sys\robocopy.exe" $korijen $dom /E /R:2 /W:2 /NFL /NDL /NJH /NJS /NP /XD $izuzmi /XF '*.log' '*.bak-*' | Out-Null
  if ($LASTEXITCODE -lt 8) {
    Ok "Package installed - $((Get-ChildItem $dom -Recurse -File).Count) files"
  } else {
    Bad "Copying the package failed (robocopy $LASTEXITCODE)"
  }
}

# Od sada sve ide iz ugradene kopije, da zadaci ne ovise o tome odakle si pokrenuo.
$skripte = Join-Path $dom 'scripts'
if (Test-Path (Join-Path $dom 'installers')) { $instal = Join-Path $dom 'installers' }

# ============================================================ 1. DRIVERI
Head '1. Drivers'

# Driver paket koji nije WHQL-potpisan (VDD je potpisan SignPath Foundation
# certifikatom) PnP ce odbiti tiho instalirati - otvorio bi dijalog "zelite li
# instalirati ovaj softver", kojeg u /qn instalaciji nema tko potvrditi.
# Zato se potpisnik izvadi iz .cat datoteke i uveze u TrustedPublisher.
# Na ovom VM-u je vec bio uvezen (ostatak rucne instalacije), pa se propust
# nije vidio; na svjezem VM-u bi instalacija drivera stala.
function Uvezi-Potpisnika([string]$cat, [string]$naziv) {
  if (-not (Test-Path $cat)) { return }
  try {
    $c = [Security.Cryptography.X509Certificates.X509Certificate2]::CreateFromSignedFile($cat)
  } catch { Warn "$naziv - cannot read the signature from $cat"; return }

  foreach ($ime in 'TrustedPublisher','Root') {
    $st = New-Object Security.Cryptography.X509Certificates.X509Store($ime, 'LocalMachine')
    try {
      $st.Open('ReadWrite')
      if ($st.Certificates | Where-Object { $_.Thumbprint -eq $c.Thumbprint }) {
        Inf "$naziv - signer already in $ime"
      } else {
        $st.Add($c)
        Ok "$naziv - signer imported into $ime  ($($c.Subject -replace '^CN=([^,]+).*','$1'))"
      }
    } catch { Warn "$naziv - uvoz u ${ime}: $_" } finally { $st.Close() }
  }
}

# Hardverski ID se NE pise napamet nego cita iz INF-a. Pokusaj s izmisljenim
# ID-om (Root\ViGEmBus umjesto Nefarius\ViGEmBus\Gen1) je stvorio uredaj-sirote
# i UpdateDriverForPlugAndPlayDevices je vratio 259 (ERROR_NO_MORE_ITEMS).
# INF-ovi su cesto UTF-16LE, pa Get-Content -Raw (koji cita BOM) a ne bajtovi.
function Hwid-IzInf([string]$inf) {
  if (-not (Test-Path $inf)) { return $null }
  $redci = (Get-Content $inf -Raw) -split "`r?`n"
  $uSekciji = $false
  foreach ($r in $redci) {
    $bez = ($r -split ';')[0].Trim()          # odbaci komentar
    if ($bez -match '^\[(.+)\]$') { $uSekciji = $Matches[1] -match '^Standard(\.NT(amd64)?)?$'; continue }
    if ($uSekciji -and $bez -match '^\s*%[^%]+%\s*=\s*[^,]+,\s*(.+)$') {
      return ($Matches[1] -split ',')[0].Trim()
    }
  }
  return $null
}

function Instaliraj-Driver([string]$inf, [string]$naziv, [string]$hwid) {
  if (-not (Test-Path $inf)) { Warn "$naziv - INF does not exist: $inf"; return }
  $vec = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
         Where-Object { $_.InstanceId -like "*$hwid*" -and $_.Status -eq 'OK' }
  if ($vec) { Ok "$naziv is already installed"; return }
  Inf "$naziv - adding driver to the store"
  $r = & "$sys\pnputil.exe" /add-driver $inf /install 2>&1
  if ($r -match 'success|uspj') { Ok "$naziv - driver added" } else { Warn "$naziv - pnputil: $($r -join ' ')" }
}

# VDD i ViGEmBus su root-enumerirani: driver u trgovini nije dovoljan, treba
# stvoriti i sam uredaj. Radi se preko SetupAPI-ja, bez vanjskih alata.
$devSig = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class RootDev {
  [StructLayout(LayoutKind.Sequential)]
  public struct SP_DEVINFO_DATA { public int cbSize; public Guid ClassGuid; public int DevInst; public IntPtr Reserved; }

  [DllImport("setupapi.dll", SetLastError = true)]
  static extern IntPtr SetupDiCreateDeviceInfoList(ref Guid ClassGuid, IntPtr hwndParent);
  [DllImport("setupapi.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool SetupDiCreateDeviceInfoW(IntPtr DeviceInfoSet, string DeviceName, ref Guid ClassGuid,
    string DeviceDescription, IntPtr hwndParent, int CreationFlags, ref SP_DEVINFO_DATA DeviceInfoData);
  [DllImport("setupapi.dll", SetLastError = true)]
  static extern bool SetupDiSetDeviceRegistryPropertyW(IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData,
    int Property, byte[] PropertyBuffer, int PropertyBufferSize);
  [DllImport("setupapi.dll", SetLastError = true)]
  static extern bool SetupDiCallClassInstaller(int InstallFunction, IntPtr DeviceInfoSet, ref SP_DEVINFO_DATA DeviceInfoData);
  [DllImport("setupapi.dll", SetLastError = true)]
  static extern bool SetupDiDestroyDeviceInfoList(IntPtr DeviceInfoSet);
  [DllImport("newdev.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool UpdateDriverForPlugAndPlayDevicesW(IntPtr hwndParent, string HardwareId,
    string FullInfPath, int InstallFlags, out bool bRebootRequired);

  const int SPDRP_HARDWAREID = 0x00000001;
  const int DIF_REGISTERDEVICE = 0x00000019;
  const int DICD_GENERATE_ID = 0x00000001;
  const int INSTALLFLAG_FORCE = 0x00000001;

  public static string Create(string classGuidStr, string className, string hardwareId, string infPath) {
    Guid cls = new Guid(classGuidStr);
    IntPtr set = SetupDiCreateDeviceInfoList(ref cls, IntPtr.Zero);
    if (set == (IntPtr)(-1)) return "SetupDiCreateDeviceInfoList: " + Marshal.GetLastWin32Error();

    var dd = new SP_DEVINFO_DATA();
    dd.cbSize = Marshal.SizeOf(dd);
    if (!SetupDiCreateDeviceInfoW(set, className, ref cls, null, IntPtr.Zero, DICD_GENERATE_ID, ref dd)) {
      int e = Marshal.GetLastWin32Error(); SetupDiDestroyDeviceInfoList(set);
      return "SetupDiCreateDeviceInfo: " + e;
    }

    // REG_MULTI_SZ: hardwareId + dva zavrsna nul-znaka
    byte[] buf = Encoding.Unicode.GetBytes(hardwareId + "\0\0");
    if (!SetupDiSetDeviceRegistryPropertyW(set, ref dd, SPDRP_HARDWAREID, buf, buf.Length)) {
      int e = Marshal.GetLastWin32Error(); SetupDiDestroyDeviceInfoList(set);
      return "SetupDiSetDeviceRegistryProperty: " + e;
    }
    if (!SetupDiCallClassInstaller(DIF_REGISTERDEVICE, set, ref dd)) {
      int e = Marshal.GetLastWin32Error(); SetupDiDestroyDeviceInfoList(set);
      return "DIF_REGISTERDEVICE: " + e;
    }
    SetupDiDestroyDeviceInfoList(set);

    bool reboot;
    if (!UpdateDriverForPlugAndPlayDevicesW(IntPtr.Zero, hardwareId, infPath, INSTALLFLAG_FORCE, out reboot))
      return "UpdateDriverForPlugAndPlayDevices: " + Marshal.GetLastWin32Error();

    return "OK" + (reboot ? " (treba restart)" : "");
  }
}
'@
if (-not ('RootDev' -as [type])) { Add-Type -TypeDefinition $devSig }

# --- VDD ---
$vddInf = Join-Path $instal 'vdd-driver\mttvdd.inf'
Uvezi-Potpisnika (Join-Path $instal 'vdd-driver\MttVDD.cat') 'VDD'

# NE trazi ROOT\DISPLAY\0000 fiksno - ako je na VM-u ranije postojao drugi
# virtualni display (sudovda, Sunshine Virtual Display), MttVDD zavrsi na 0001.
function Nadi-VDD {
  Get-PnpDevice -ErrorAction SilentlyContinue |
    Where-Object { $_.InstanceId -like 'ROOT\DISPLAY\*' -and $_.FriendlyName -match 'Virtual Display Driver' } |
    Select-Object -First 1
}
$vddDev = Nadi-VDD
if ($vddDev -and $vddDev.Status -eq 'OK') {
  Ok 'Virtual Display Driver is already installed'
} elseif (Test-Path $vddInf) {
  Inf 'Installing Virtual Display Driver'
  & "$sys\pnputil.exe" /add-driver $vddInf /install 2>&1 | Out-Null
  # klasa Display: {4d36e968-e325-11ce-bfc1-08002be10318}
  $vddHwid = Hwid-IzInf $vddInf
  if (-not $vddHwid) { $vddHwid = 'Root\MttVDD' }
  Inf "  hardware ID from the INF: $vddHwid"
  # klasa Display: {4d36e968-e325-11ce-bfc1-08002be10318}
  $r = [RootDev]::Create('4d36e968-e325-11ce-bfc1-08002be10318', 'DISPLAY', $vddHwid, $vddInf)
  if ($r -like 'OK*') { Ok "Virtual Display Driver installed $r"; Start-Sleep -Seconds 5 }
  else { Bad "Virtual Display Driver: $r" }
  Vrati-Prozor   # topologija se promijenila - vrati konzolu na glavni zaslon
} else { Bad "No $vddInf" }

# --- ViGEmBus (gamepad) ---
$vgInf = Join-Path $instal 'vigembus\vigembus.inf'
Uvezi-Potpisnika (Join-Path $instal 'vigembus\ViGEmBus.cat') 'ViGEmBus'
# Prijateljsko ime je "Nefarius Virtual Gamepad Emulation Bus" - u njemu NEMA
# niza "ViGEm", pa provjera po imenu lazno javlja da uredaja nema. Ide po hwid-u.
$vgHwid = Hwid-IzInf $vgInf
if (-not $vgHwid) { $vgHwid = 'Nefarius\ViGEmBus\Gen1' }
$vgDev = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
  (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_HardwareIds' -ErrorAction SilentlyContinue).Data -contains $vgHwid
}
if ($vgDev) {
  Ok 'ViGEmBus is already installed'
} elseif (Test-Path $vgInf) {
  Inf 'Installing ViGEmBus'
  & "$sys\pnputil.exe" /add-driver $vgInf /install 2>&1 | Out-Null
  # klasa System: {4d36e97d-e325-11ce-bfc1-08002be10318}
  Inf "  hardware ID from the INF: $vgHwid"
  # klasa System: {4d36e97d-e325-11ce-bfc1-08002be10318}
  $r = [RootDev]::Create('4d36e97d-e325-11ce-bfc1-08002be10318', 'SYSTEM', $vgHwid, $vgInf)
  if ($r -like 'OK*') { Ok "ViGEmBus installed $r" } else { Warn "ViGEmBus: $r  (gamepad will not work)" }
} else { Warn "No $vgInf - gamepad will not work" }

# --- VB-Audio ---
if (-not $PreskociAudio) {
  if (Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'VB-Audio|CABLE' }) {
    Ok 'VB-Audio cable is already installed'
  } else {
    $vb = Join-Path $instal 'vb-audio-cable\VBCABLE_Setup_x64.exe'
    if (Test-Path $vb) {
      Inf 'Installing VB-Audio virtual cable (may open a window)'
      Start-Process $vb -ArgumentList '-i','-h' -Wait
      Ok 'VB-Audio done'
    } else { Warn 'No VB-Audio installer' }
  }
} else { Inf 'VB-Audio skipped' }

# ============================================================ 2. VDD KONFIGURACIJA
Head '2. Virtual Display Driver configuration'

$vddDir = 'C:\VirtualDisplayDriver'
$vddXml = Join-Path $vddDir 'vdd_settings.xml'
New-Item -ItemType Directory -Path $vddDir -Force | Out-Null

# Lista modova. OPREZ: driver ima granicu - pokusaj sa 17 modova ga je slomio
# (prestao je prijavljivati monitor). Ovih 11 je provjereno stabilno.
# Ako dodajes, dodaj JEDAN po jedan i provjeri da monitor i dalje radi.
$modovi = @(
  @(1280,720), @(1600,900), @(1920,1080), @(1920,1200),
  @(2560,1440), @(2560,1600), @(3440,1440),
  @(3840,1080), @(3840,2160), @(4096,1152), @(5120,1440)
)

$xml = New-Object System.Collections.Generic.List[string]
$xml.Add('<?xml version="1.0" encoding="utf-8"?>')
$xml.Add('<vdd_settings>')
$xml.Add('  <monitors>')
$xml.Add('    <count>1</count>')
$xml.Add('  </monitors>')
$xml.Add('  <gpu>')
$xml.Add("    <friendlyname>$Gpu</friendlyname>")
$xml.Add('  </gpu>')
$xml.Add('  <global>')
foreach ($hz in @(60,90,120,144,165,244)) { $xml.Add("    <g_refresh_rate>$hz</g_refresh_rate>") }
$xml.Add('  </global>')
$xml.Add('  <resolutions>')
foreach ($m in $modovi) {
  $xml.Add('    <resolution>')
  $xml.Add("      <width>$($m[0])</width>")
  $xml.Add("      <height>$($m[1])</height>")
  $xml.Add('      <refresh_rate>30</refresh_rate>')
  $xml.Add('    </resolution>')
}
$xml.Add('  </resolutions>')
# HardwareCursor mora ostati true - inace kursor odlazi kroz enkoder kao dio
# slike i vidi se s kasnjenjem. Ostalo je zateceno stanje radne postave.
$xml.Add('  <options>')
$xml.Add('    <CustomEdid>false</CustomEdid>')
$xml.Add('    <PreventSpoof>false</PreventSpoof>')
$xml.Add('    <EdidCeaOverride>false</EdidCeaOverride>')
$xml.Add('    <HardwareCursor>true</HardwareCursor>')
$xml.Add('    <SDR10bit>false</SDR10bit>')
$xml.Add('    <HDRPlus>false</HDRPlus>')
$xml.Add('    <logging>true</logging>')
$xml.Add('    <debuglogging>false</debuglogging>')
$xml.Add('  </options>')
$xml.Add('</vdd_settings>')

# PRIJE svega aktiviraj Hyper-V display. Restart VDD-a gasi zaslon koji gledas,
# a na svjezem VM-u je VDD cesto JEDINI zaslon - slika se zamrzne i instalacija
# ostane bez covjeka. Vidjeno 23.8.2026. na VM-u G10.
# Uz aktivan Hyper-V display sesija prezivi restart.
if (-not $prekoRdp) {
  Inf 'Activating the Hyper-V display so restarting the VDD does not kill the picture'
  $sdSig = 'using System;using System.Runtime.InteropServices;' +
           'public class SDINST { [DllImport("user32.dll")] public static extern int SetDisplayConfig(uint a,IntPtr b,uint c,IntPtr d,uint f); }'
  if (-not ('SDINST' -as [type])) { Add-Type -TypeDefinition $sdSig }
  # SDC_APPLY | SDC_TOPOLOGY_EXTEND
  $rcx = [SDINST]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, (0x80 -bor 0x04))
  Inf "  extend rc=$rcx"
   Vrati-Prozor   # topologija se promijenila - vrati konzolu na glavni zaslon
  Start-Sleep -Seconds 8
}

$d = Nadi-VDD

# Driver drzi vdd_settings.xml otvoren i pise ga pod SYSTEM-om, pa administrator
# dobije "Access denied". Zato se uredaj PRVO ugasi, pa se pise, pa se upali.
if ($d) {
Write-Host ''
Write-Host '  >>> THE SCREEN GOES BLANK NOW. About half a minute. Do not touch anything. <<<' -ForegroundColor Cyan
Write-Host ''
  Inf 'Stopping the VDD so it releases the configuration file'
  Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 6
}

if (Test-Path $vddXml) { Copy-Item $vddXml "$vddXml.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force -ErrorAction SilentlyContinue }

$zapisano = Zapisi-BezBom $vddXml $xml
if (-not $zapisano) {
  # Ako ni ugasen driver nije pomogao, ostala je jos ACL prepreka. Preuzmi
}

if ($zapisano) {
  # Ne vjeruj na rijec - procitaj natrag i provjeri da je NASA konfiguracija.
  $pro = Get-Content $vddXml -Raw -ErrorAction SilentlyContinue
  if ($pro -match [regex]::Escape($Gpu) -and ([regex]::Matches($pro, '<resolution>')).Count -eq $modovi.Count) {
    Ok "vdd_settings.xml written and verified (GPU: $Gpu, $($modovi.Count) modes)"
  } else {
    Bad 'vdd_settings.xml was written but the contents do not match - check manually'
  }
} else {
  Bad "$vddXml was NOT written - the VDD will run with DEFAULT settings"
  Inf 'Meaning: not bound to the NVIDIA GPU and without our resolution list.'
}

if ($d) {
  Inf 'Starting the VDD'
  Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
  # Ne cekaj fiksno nego dok monitor stvarno ne dodje. Ranije je ovdje stajalo
  # Start-Sleep 22, pa je zamracenje trajalo punih 22 s cak i kad je VDD bio
  # spreman za 5. Korisnik u Basic Session u tom trenutku nema sliku, ne cuje
  # nista (Basic Session ne prenosi zvuk) i ne zna je li se zablokiralo.
  # Zato: provjeravaj svake 2 s i nastavi cim monitor postoji.
  $stao = [Diagnostics.Stopwatch]::StartNew()
  $mon = $null
  while ($stao.Elapsed.TotalSeconds -lt 40) {
    Start-Sleep -Seconds 2
    $mon = Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue | Where-Object {
      ((Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue).Data -match [regex]::Escape($d.InstanceId)) -and $_.Status -eq 'OK'
    }
    if ($mon) { break }
  }
  $stao.Stop()
  if ($mon) { Ok ("VDD reports a monitor (after {0:N0} s)" -f $stao.Elapsed.TotalSeconds) }
  else { Bad 'VDD does NOT report a monitor - the configuration broke it. Restore the .bak and try fewer modes.' }
  Vrati-Prozor   # topologija se promijenila - vrati konzolu na glavni zaslon
}

# Citanje ProductVersion iz MSI baze preko msi.dll.
$msiSig = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public class MsiVer {
  [DllImport("msi.dll", CharSet = CharSet.Unicode)]
  static extern uint MsiOpenDatabaseW(string db, IntPtr persist, out IntPtr h);
  [DllImport("msi.dll", CharSet = CharSet.Unicode)]
  static extern uint MsiDatabaseOpenViewW(IntPtr db, string query, out IntPtr view);
  [DllImport("msi.dll")]
  static extern uint MsiViewExecute(IntPtr view, IntPtr record);
  [DllImport("msi.dll")]
  static extern uint MsiViewFetch(IntPtr view, out IntPtr record);
  [DllImport("msi.dll", CharSet = CharSet.Unicode)]
  static extern uint MsiRecordGetStringW(IntPtr rec, uint field, StringBuilder buf, ref uint cch);
  [DllImport("msi.dll")]
  static extern uint MsiCloseHandle(IntPtr h);

  public static string Procitaj(string putanja) {
    IntPtr db = IntPtr.Zero, view = IntPtr.Zero, rec = IntPtr.Zero;
    try {
      // MSIDBOPEN_READONLY je (LPCWSTR)0, ne string
      if (MsiOpenDatabaseW(putanja, IntPtr.Zero, out db) != 0) return null;
      if (MsiDatabaseOpenViewW(db,
            "SELECT `Value` FROM `Property` WHERE `Property`='ProductVersion'", out view) != 0) return null;
      if (MsiViewExecute(view, IntPtr.Zero) != 0) return null;
      if (MsiViewFetch(view, out rec) != 0 || rec == IntPtr.Zero) return null;
      uint cch = 256;
      var sb = new StringBuilder((int)cch);
      if (MsiRecordGetStringW(rec, 1, sb, ref cch) != 0) return null;
      return sb.ToString();
    } finally {
      if (rec  != IntPtr.Zero) MsiCloseHandle(rec);
      if (view != IntPtr.Zero) MsiCloseHandle(view);
      if (db   != IntPtr.Zero) MsiCloseHandle(db);
    }
  }
}
'@
if (-not ('MsiVer' -as [type])) { Add-Type -TypeDefinition $msiSig }

# ============================================================ 3. SUNSHINE
Head '3. Sunshine (patched build)'

$msi = Join-Path $instal 'sunshine\Luxstream-Sunshine-patched.msi'
$sxe = 'C:\Program Files\Sunshine\Sunshine.exe'
if (-not (Test-Path $msi)) {
  Bad "No $msi"
} else {
  # Verzija se cita iz MSI baze. Prazan catch je ovdje jednom vec sakrio kvar i
  # instalater je krenuo reinstalirati vec instaliranu verziju — msiexec je to
  # protumacio kao popravak (SECUREREPAIR) i vratio 1603.
  # COM (WindowsInstaller.Installer) je ovdje bio nepouzdan: isti kod je izvan
  # skripte radio, a unutar nje bacao DISP_E_TYPEMISMATCH na View.Execute.
  # Zato izravni pozivi msi.dll — bez kasnog vezivanja i bez iznenadenja.
  $verNova = [MsiVer]::Procitaj($msi)
  if (-not $verNova) { Warn 'MSI version unknown' }

  # @() jer bi se jednoclani rezultat odmotao u skalar i .DisplayVersion bi zakazao
  $verStara = @(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -eq 'Sunshine' } |
                Select-Object -ExpandProperty DisplayVersion -ErrorAction SilentlyContinue)[0]

  # Odluka o instalaciji. NEPOZNATA verzija NE SMIJE znaciti "instaliraj" —
  # inace svaki neuspjeh citanja srusi ispravnu instalaciju.
  $trebaInstalirati =
    if ($PrisiliSunshine)        { $true }
    elseif (-not (Test-Path $sxe)) { $true }               # nema ga - instaliraj
    elseif (-not $verNova)       { $false }                # ne znam sto nudim - ne diraj
    elseif (-not $verStara)      { $true }                 # ima datoteku, nema zapisa - instaliraj
    else                         { $verStara -ne $verNova }

  if (-not $trebaInstalirati) {
    if ($verStara) { Ok "Sunshine $verStara is already installed" }
    else { Ok 'Sunshine is already on disk - leaving it alone (use -PrisiliSunshine to reinstall)' }
  } else {
    # Zaustavi sve sto drzi datoteke, inace Restart Manager obori instalaciju
    Disable-ScheduledTask -TaskName 'StreamReady' -ErrorAction SilentlyContinue | Out-Null
    Stop-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 5

    if (Test-Path 'C:\Program Files\Sunshine\config') {
      $bk = "C:\Users\Public\sunshine-config-backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
      Copy-Item 'C:\Program Files\Sunshine\config' $bk -Recurse -Force -ErrorAction SilentlyContinue
      Inf "Config backup: $bk"
    }

    Inf "Installing Sunshine $verNova"
    $p = Start-Process "$sys\msiexec.exe" -ArgumentList @('/i',"`"$msi`"",'/qn','/norestart','/L*v','C:\Users\Public\luxstream-msi.log') -PassThru -Wait
    Vrati-Prozor   # msiexec zna dovesti svoj prozor u prvi plan
    if ($p.ExitCode -eq 0 -and (Test-Path $sxe)) { Ok "Sunshine $verNova installed" }
    else { Bad "msiexec exit $($p.ExitCode) - see C:\Users\Public\luxstream-msi.log" }
  }

  # provjera da je to doista zakrpani build
  if (Test-Path $sxe) {
    $bytes = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($sxe))
    if ($bytes.Contains('wgc: init start')) { Ok 'Build contains our patches (wgc instrumentation)' }
    else { Warn 'Build does NOT contain our patches - is this upstream Sunshine?' }
  }
}

# ============================================================ 4. SUNSHINE CONFIG
Head '4. Sunshine configuration'

$conf = 'C:\Program Files\Sunshine\config\sunshine.conf'
$log  = 'C:\Program Files\Sunshine\config\sunshine.log'
New-Item -ItemType Directory -Path (Split-Path $conf -Parent) -Force | Out-Null

# ---------------------------------------------------------------- IDENTITET
# Sunshineov identitet prema Moonlightu su DVIJE stvari:
#   credentials\cacert.pem + cakey.pem   <- Moonlight pinga bas ovaj certifikat
#   sunshine_state.json -> root.uniqueid <- ID koji host oglasava
#
# Kad se VM kopira, klon nosi ISTI certifikat i ISTI uniqueid kao original.
# Moonlight tada vidi dva hosta koji tvrde da su isti stroj i klijent se
# odbija spojiti. To se vec dogodilo u praksi.
#
# Klon se prepoznaje po BIOS/SMBIOS UUID-u (Win32_ComputerSystemProduct.UUID),
# kojeg Hyper-V dodjeljuje PO VM-u. Kopiranje VM-a ga mijenja, obicno
# ponovno pokretanje ne.
#
# Izmjereno 22.8.2026.: ako se cacert.pem i cakey.pem sklone, Sunshine pri
# pokretanju izgenerira NOVE (potvrdeno drugim otiskom certifikata).
# sunshine_state.json se ne stvara odmah nego pri prvoj promjeni, sto je
# isti put kao kod svjeze instalacije.

$pecatDat = 'C:\Users\Public\luxstream-identity.txt'
$biosUuid = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
$pecatSad = "$biosUuid|$env:COMPUTERNAME"
$pecatPrije = if (Test-Path $pecatDat) { (Get-Content $pecatDat -Raw).Trim() } else { $null }

$sufiksImena = ''
$resetIdentiteta =
  if ($NoviIdentitet)      { Inf 'New identity requested (-NoviIdentitet)'; $true }
  elseif (-not $biosUuid)  {
    # Bez BIOS UUID-a pecat se ne bi poklopio i klon bi se LAZNO prijavio,
    # a to bi obrisalo sva sparivanja. Radije ne radi nista.
    Warn 'Cannot read the BIOS UUID - skipping the identity check'
    $false
  }
  elseif (-not $pecatPrije) { Inf 'First install - identity left alone'; $false }
  elseif ($pecatPrije -ne $pecatSad) {
    Warn 'This is not the machine it was installed on - this is a CLONE'
    Inf  "  before: $pecatPrije"
    Inf  "  now   : $pecatSad"
    $true
  }
  else { Ok 'Identity belongs to this machine'; $false }

if ($resetIdentiteta) {
  $cfgDir = Split-Path $conf -Parent
  $spremi = "C:\Users\Public\sunshine-identitet-stari-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
  New-Item -ItemType Directory -Path $spremi -Force | Out-Null

  Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 4

  # premjestanje, ne brisanje - stari identitet ostaje povratan
  foreach ($dat in "$cfgDir\credentials\cacert.pem", "$cfgDir\credentials\cakey.pem", "$cfgDir\sunshine_state.json") {
    if (Test-Path $dat) { Move-Item $dat $spremi -Force -ErrorAction SilentlyContinue }
  }
  Ok "Old identity moved aside to $spremi"
  Inf 'Sunshine will generate a new certificate and uniqueid on start'
  Warn 'ALL clients must be paired again (PIN via the web UI)'

  # Ako klon nosi i isto ime racunala, u Moonlightu bi se pojavila dva
  # jednaka imena. Kratki sufiks iz BIOS UUID-a ih razlikuje.
  $imePrije = if ($pecatPrije) { ($pecatPrije -split '\|')[1] } else { '' }
  if ($imePrije -eq $env:COMPUTERNAME -and $biosUuid) {
    $sufiksImena = '-' + $biosUuid.Substring(0,4)
    Warn "Computer name matches the original - in Moonlight it will show as $env:COMPUTERNAME$sufiksImena"
    Inf  'For a nicer name, rename the Windows computer and run the installer again'
  }
}

if ($biosUuid) { Set-Content $pecatDat $pecatSad -Encoding ASCII }

# GUID VDD displaya je specifican za svaki VM. Sunshine ga zapise u log pri
# nabrajanju, pa ga odatle procitamo.
if ($prekoRdp) {
  Warn 'Over RDP the display GUID is not looked up - Sunshine would enumerate the RDP screen'
  Inf  'sunshine.conf goes without output_name; Sunshine will capture the primary display.'
  $guid = $null
} else {
  Inf 'Looking up the VDD display GUID'
$guid = $null
for ($pokusaj = 1; $pokusaj -le 3 -and -not $guid; $pokusaj++) {
  Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
  Remove-Item $log -ErrorAction SilentlyContinue
  # Skriveno - inace Sunshineov konzolni prozor dodje u prvi plan i prekrije nas,
  # pa korisnik vidi da se Sunshine dize ali ne vidi instalaciju.
  Start-Process $sxe -WorkingDirectory (Split-Path $sxe -Parent) -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
  Start-Sleep -Milliseconds 500
  Vrati-Prozor
  Start-Sleep -Seconds 25
  if (Test-Path $log) {
    $tekst = Get-Content $log -Raw
    # trazi blok s friendly_name 'VDD by MTT' i uzmi njegov device_id
    # Izmedu "device_id" i "friendly_name" stoji ugnijezdeni "edid" blok, pa se ne
    # smije koristiti [^}]*. Uvjet (?!"device_id") osigurava da se ne preskoci u
    # sljedeci uredaj i uhvati krivi GUID.
    $uzorak = '"device_id"\s*:\s*"(\{[0-9a-fA-F-]+\})"(?:(?!"device_id")[\s\S])*?"friendly_name"\s*:\s*"VDD by MTT"'
    $m = [regex]::Match($tekst, $uzorak)
    if ($m.Success) { $guid = $m.Groups[1].Value }
  }
  if (-not $guid) { Inf "  attempt $pokusaj did not find the GUID" }
}
}

$redci = @(
  'capture = wgc'
  'dd_configuration_option = verify_only'
  'dd_resolution_option = auto'
  'min_log_level = info'
  "sunshine_name = $env:COMPUTERNAME$sufiksImena"
)
if ($guid) {
  $redci = @("output_name = $guid") + $redci
  Ok "VDD display GUID: $guid"
} else {
  Warn 'GUID not found - output_name stays empty, Sunshine will pick the display itself'
}

if (Test-Path $conf) { Copy-Item $conf "$conf.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')" -Force }
# Rezultat se MORA uhvatiti - inace $true padne u izlaz i u dnevniku se pojavi
# goli "True" bez ikakva konteksta.
if (Zapisi-BezBom $conf $redci) {
  Ok 'sunshine.conf written (no BOM)'
} else {
  Bad "sunshine.conf nije zapisan"
}

# zapamceno stanje displaya zna sadrzavati staru topologiju
Remove-Item 'C:\Program Files\Sunshine\config\display_device.state' -ErrorAction SilentlyContinue

# ============================================================ 5. ZADACI
Head '5. Scheduled tasks'

Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# Sunshine NE SMIJE ici kao servis - kao SYSTEM ne moze aktivirati WGC.
$svc = Get-Service SunshineService -ErrorAction SilentlyContinue
if ($svc) {
  Stop-Service SunshineService -Force -ErrorAction SilentlyContinue
  Set-Service SunshineService -StartupType Disabled -ErrorAction SilentlyContinue
  Ok 'SunshineService disabled (it must run as the user)'
}

$korisnik = "$env:USERDOMAIN\$env:USERNAME"

# --- SunshineUser ---
# Sunshine.exe je gradjen kao KONZOLNA aplikacija (PE Subsystem = 3), pa mu
# Windows sam stvara konzolni prozor. Ne da se iskljuciti prekidacem -
# `Sunshine.exe --help` nudi samo --creds, --version i zastavice -0 -1 -2 -p.
#
# Dok je Sunshine isao kao servis prozora nije bilo, jer servisi nemaju radnu
# povrsinu. Otkad mora ici kao korisnik (SYSTEM ne moze aktivirati WGC),
# prozor se vidi i smeta.
#
# Zato ga pali wscript preko VBS omotaca, koji ga stvori sa SW_HIDE. Provjereno:
# isti proces pokrenut normalno ima MainWindowHandle != 0, kroz omotac 0.
# Nema ni bljeska, jer je wscript.exe GUI program.
#
# I watchdog i faza 7 pale Sunshine kroz OVAJ zadatak, pa je ovo jedino mjesto
# koje to odreduje.
$vbs = Join-Path $skripte 'start-sunshine-hidden.vbs'
if (Test-Path $vbs) {
  $akcija = New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`"" `
              -WorkingDirectory (Split-Path $sxe -Parent)
} else {
  Warn 'No start-sunshine-hidden.vbs - Sunshine will show a console window'
  $akcija = New-ScheduledTaskAction -Execute $sxe -WorkingDirectory (Split-Path $sxe -Parent)
}
$okidac = New-ScheduledTaskTrigger -AtLogOn -User $korisnik
$princ  = New-ScheduledTaskPrincipal -UserId $korisnik -LogonType Interactive -RunLevel Highest
$post   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName 'SunshineUser' -Action $akcija -Trigger $okidac `
  -Principal $princ -Settings $post -Force | Out-Null
Ok 'Task SunshineUser registered'

# --- StreamReady ---
& (Join-Path $skripte 'ensure-streaming-ready.ps1') -Install
Ok 'Task StreamReady registered'

# --- RestoreConsoleSession ---
& (Join-Path $skripte 'restore-console-session.ps1') -Install
Ok 'Task RestoreConsoleSession registered'

# --- VerifyAfterBoot --- dijagnostika: 100 s nakon prijave zapise stanje u
# C:\Users\Public\boot-verify.txt, da se vidi je li postava prezivjela restart
& (Join-Path $skripte 'verify-after-boot.ps1') -Install
Ok 'Task VerifyAfterBoot registered'

# ============================================================ 6. PRILAGODBE
Head '6. Tweaks'

$dpi = Join-Path $skripte 'set-dpi-100.ps1'
if (Test-Path $dpi) { & $dpi | Out-Null; Ok 'DPI set to 100%' }

# --- UIAccess za Sunshine ---
# Bez ovoga se UAC potvrda preko Moonlighta VIDI ali se ne moze kliknuti:
# consent.exe radi na razini integriteta System, Sunshine kao korisnik na High,
# a UIPI ne da nizoj razini slati unos visoj. Podizanje Sunshinea na SYSTEM nije
# opcija jer tada ne moze aktivirati WGC.
#
# UIAccess je Windowsov namjenski mehanizam za tu potrebu - isti koji koristi
# osk.exe (zaslonska tipkovnica). Trazi tri stvari: sigurnu lokaciju (imamo),
# uiAccess="true" u manifestu i Authenticode potpis.
#
# Potpis se MORA raditi ovdje, na stroju - privatni kljuc se ne isporucuje u
# paketu. Zato se i manifest mijenja ovdje, da sve bude na jednom mjestu.
# Izmjereno 23.8.2026.: token procesa dobije UIAccess = 1 i potvrda se moze
# kliknuti preko Moonlighta.
if ($PreskociUiAccess) {
  Inf 'UIAccess skipped (-PreskociUiAccess)'
} else {
  $ua = Join-Path $skripte 'uiaccess-sunshine.ps1'
  if (Test-Path $ua) {
    & $ua | ForEach-Object { Write-Host "  $_" }
  } else {
    Warn 'No uiaccess-sunshine.ps1 - the UAC prompt will not be clickable over Moonlight'
  }
}

$gb = Join-Path $skripte 'disable-gamebar-prompt.ps1'
if (Test-Path $gb) { & $gb | Out-Null; Ok 'Game Bar / Store dialog disabled' }

# --- Automatska prijava ---
# OBAVEZNA, ne kozmetika. Cijeli lanac visi o prijavljenoj interaktivnoj sesiji:
# WGC ne radi kao SYSTEM, promjene displaya iz sesije 0 ne diraju korisnikov
# desktop, a zadaci SunshineUser i StreamReady okidaju "pri prijavi". Bez nje se
# VM digne do zaslona za prijavu i Moonlight vidi host ali se ne moze spojiti.
#
# Lozinku upisuje korisnik, ovdje, i ide u LSA tajne - ne u registry kao tekst.
if ($PreskociAutoPrijavu) {
  Inf 'Automatic logon skipped (-PreskociAutoPrijavu)'
} else {
  $ap = Join-Path $skripte 'postavi-auto-prijavu.ps1'
  $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
  if ($wl.AutoAdminLogon -eq '1' -and $wl.DefaultUserName) {
    Ok "Automatic logon already set for $($wl.DefaultDomainName)\$($wl.DefaultUserName)"
  } elseif (Test-Path $ap) {
    Inf 'Setting up automatic logon - it will ask for a password'
    & $ap | ForEach-Object { Write-Host "  $_" }
  } else {
    Warn 'No postavi-auto-prijavu.ps1 - the VM will not log on by itself and Sunshine will not start'
  }
}

if ($PreskociUac) {
  Inf 'UAC left alone (-PreskociUac)'
} else {
  # ISPRAVAK 23.8.2026. Ranije se ovdje postavljalo ConsentPromptBehaviorAdmin = 0,
  # dakle elevacija BEZ pitanja. To vise nije potrebno i bilo je nepotrebno slabo.
  #
  # Problem su bile DVIJE odvojene prepreke, i obje su rijesene drukcije:
  #   1. PromptOnSecureDesktop = 1 prebaci ulazni desktop na Winlogon, kojeg WGC
  #      ne vidi - slika se zamrzne i unos ode u prazno. Zato ide na 0.
  #   2. consent.exe radi na razini integriteta System, a Sunshine na High, pa
  #      UIPI blokira SendInput. To rjesava UIAccess (vidi uiaccess-sunshine.ps1).
  #
  # Uz oboje potvrda POSTOJI i moze se kliknuti preko Moonlighta.
  $polKljuc = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
  $pol = Get-ItemProperty $polKljuc -ErrorAction SilentlyContinue

  if ($pol.ConsentPromptBehaviorAdmin -eq 5 -and $pol.PromptOnSecureDesktop -eq 0) {
    Ok 'UAC is already set correctly (prompt yes, secure desktop no)'
  } else {
    Set-ItemProperty $polKljuc -Name ConsentPromptBehaviorAdmin -Value 5 -Type DWord
    Set-ItemProperty $polKljuc -Name PromptOnSecureDesktop      -Value 0 -Type DWord
    Ok 'UAC: prompt required (5), dialog on the normal desktop (0)'
    Inf 'Trade-off: a dialog on the normal desktop is slightly weaker protection than'
    Inf 'one on the secure desktop, but it is the only way to see and click it over the stream.'
  }
}

# ============================================================ 7. PRIMING I PROVJERA
Head '7. Priming and verification'

Enable-ScheduledTask -TaskName 'StreamReady' -ErrorAction SilentlyContinue | Out-Null
# Faza 4 je pokrenula Sunshine izravno da otkrije GUID. Ako ga ne ugasimo,
# zadatak pokrene DRUGI i dva se procesa tuku oko portova. Vidjeno na G10:
# "Sunshine radi (PID 12040 27772)".
Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 4
Start-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 20

if ($prekoRdp) {
  Warn 'Over RDP, priming and graphics measurement are skipped - the displays are different.'
  Inf  'INSTALL IS NOT COMPLETE. Restart the VM; automatic logon brings you to the'
  Inf  'console, then run INSTALL.cmd ONCE MORE. It is idempotent - it will skip'
  Inf  'everything already done and finish only the graphics.'
  Set-Content 'C:\Users\Public\luxstream-nedovrseno.txt' -Value "Instalirano preko RDP-a. Faze 4 i 7 nisu odradene - pokreni INSTALL.cmd s konzole." -Encoding UTF8
} else {
Inf 'Running priming (activate Hyper-V display, initialise the driver)'
& (Join-Path $skripte 'ensure-streaming-ready.ps1') -Reprime
Vrati-Prozor   # priming mijenja topologiju - vrati konzolu na glavni zaslon
Start-Sleep -Seconds 5

Write-Host ''
$displayi = & (Join-Path $skripte 'list-displays.ps1')
if (@($displayi).Count -eq 2) { Ok "Two displays (as it should be - Hyper-V stays active):`n$($displayi -join "`n")" }
else { Warn "Displaya: $(@($displayi).Count) - ocekivao sam 2. Hyper-V display mora ostati aktivan, inace Vulkan i OpenGL ne prezive.`n$($displayi -join "`n")" }

$vk = (& (Join-Path $skripte 'vulkantest.ps1') 2>&1 | Select-String 'GeForce|Radeon|uredaja:') -join ' '
if ($vk -match 'GeForce|Radeon') { Ok "Vulkan: native" } else { Bad "Vulkan: $vk" }

$gl = (& (Join-Path $skripte 'gltest.ps1') 2>&1 | Select-String 'GL_VERSION') -join ''
if ($gl -match 'NVIDIA|AMD') { Ok "OpenGL: $($gl.Trim())" } else { Bad "OpenGL: $($gl.Trim())" }

$proc = Get-Process sunshine -ErrorAction SilentlyContinue
if ($proc) { Ok "Sunshine is running (PID $($proc.Id))" } else { Bad 'Sunshine is NOT running' }

if (Test-Path $log) {
  $dd = (Select-String -Path $log -Pattern 'DuplicateOutput' -ErrorAction SilentlyContinue).Count
  $ft = (Select-String -Path $log -Pattern 'Fatal' -ErrorAction SilentlyContinue).Count
  if ($dd -eq 0 -and $ft -eq 0) { Ok 'Log has no DuplicateOutput or Fatal errors' }
  else { Warn "U logu: DuplicateOutput $dd, Fatal $ft" }
  $enk = (Select-String -Path $log -Pattern 'Found .* encoder' -ErrorAction SilentlyContinue | Select-Object -Last 1).Line
  if ($enk) { Inf $enk.Trim() }
}

}

# ============================================================ ZAVRSETAK
Write-Host ''
Write-Host '  ============================================' -ForegroundColor White
if ($greske -eq 0) {
  Write-Host '  INSTALL COMPLETE' -ForegroundColor Green
} else {
  Write-Host "  INSTALL COMPLETE UZ $greske GRESAKA" -ForegroundColor Yellow
}
Write-Host ''
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Yellow
Write-Host '   WHAT NOW - step by step' -ForegroundColor Yellow
Write-Host '  ============================================================' -ForegroundColor Yellow
Write-Host ''
Write-Host '  If in Basic Session you can see the desktop but cannot move the'
Write-Host '  mouse, the install succeeded. The primary display is now virtual.'
Write-Host ''
Write-Host '  1) SWITCH TO ENHANCED SESSION' -ForegroundColor Cyan
Write-Host '     Close the Basic Session window.'
Write-Host '     Hyper-V Manager -> right-click the VM -> Connect'
Write-Host '     -> View menu -> enable Enhanced Session.'
Write-Host '     Plain RDP to this machine works too.'
Write-Host '     Only then do you get keyboard and mouse back.'
Write-Host ''
Write-Host '  2) OPEN THE SUNSHINE WEB UI (on this VM)' -ForegroundColor Cyan
Write-Host '       https://localhost:47990'
Write-Host '     The browser will warn about the certificate. That is expected -'
Write-Host '     Sunshine signs it itself. Choose Advanced, then Continue.'
Write-Host '     If it asks for a username and password, set them now.'
Write-Host '     That is NOT your Windows password - it is separate, for this UI.'
Write-Host ''
Write-Host '  3) START MOONLIGHT (on the machine you connect from)' -ForegroundColor Cyan
Write-Host '     If the VM is not listed, add it manually by IP address.'
Write-Host '     Click it - Moonlight shows a four-digit PIN.'
Write-Host ''
Write-Host '  4) ENTER THE PIN IN SUNSHINE' -ForegroundColor Cyan
Write-Host '     In the web UI open the PIN tab, type the number and confirm.'
Write-Host '     Sunshine confirms success and the client shows up as paired.'
Write-Host ''
Write-Host '  5) CONNECT' -ForegroundColor Cyan
Write-Host '     In Moonlight click the VM. Pairing is permanent - next time you'
Write-Host '     just connect.'
Write-Host ''
Write-Host '  Check status at any time:'
Write-Host '    powershell -ExecutionPolicy Bypass -File "C:\Program Files\Luxstream\scripts\brza-provjera.ps1"'
Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Yellow
Write-Host '  Check these on the CLIENT (Moonlight). Not changes - a checklist:' -ForegroundColor Cyan
Write-Host '    Video decoder : must be Automatic, i.e. hardware decoding.'
Write-Host '                    With Force software decoding, decode jumps from ~1.5 ms to ~190 ms.'
Write-Host '    Video codec   : HEVC. With Automatic the client would pick AV1.'
Write-Host '    Resolution    : any from the VDD list; a mode not in the list is silently ignored.'
Write-Host ''
Write-Host "  Install log: $dnevnik"
Write-Host '  Documentation: README.md, RADNA-POSTAVA.md, GRAFIKA.md, TODO.md'
Write-Host ''
