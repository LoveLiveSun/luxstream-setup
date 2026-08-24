<#
    ensure-streaming-ready.ps1

    Drzi postavu u stanju u kojem streaming radi. Vrti se kao zakazani zadatak
    'StreamReady' u KORISNICKOJ sesiji, pri prijavi i svake minute.

    ===================== PRAVILO, izmjereno 22.8.2026. =====================

    NVIDIA-in ICD u GPU-P gostu nabraja uredaje tek nakon sto je NVIDIA-in
    display put bio AKTIVAN i **iskoristen** barem jednom od zadnjeg resetiranja
    display stoga. Nakon toga se smije odspojiti i sve nastavlja raditi.

      svjez boot, Hyper-V nikad aktiviran      -> Vulkan 0, OpenGL GDI Generic
      aktiviran, cekanje, odspojen             -> Vulkan 0   (nije dovoljno!)
      aktiviran, POKRENUT vulkantest, odspojen -> Vulkan 1, OpenGL 4.6, JEDAN display
      promjena rezolucije nakon toga           -> Vulkan 1   (ne rusi)
      restart VDD uredaja nakon toga           -> Vulkan 0   (treba ponoviti)

    Zato priming ima tri koraka: aktiviraj put, inicijaliziraj driver dok je
    aktivan, pa ga deaktiviraj.

    Ranije verzije su tvrdile dvije krive stvari:
      - da izvorni Vulkan trazi TRAJNO prikacen Hyper-V display
      - da je dovoljno da put bude `available` bez da je ikad bio aktivan

    OPREZ
      Deaktivira se Hyper-V display, prepoznat po najmanjoj povrsini, a NE bilo
      koji ne-primarni. Nakon restarta VDD uredaja zna se dogoditi da Hyper-V
      postane primaran; ranija verzija je tada obrisala VDD i ostavila sustav
      bez streaminga.

      [System.Windows.Forms.Screen]::AllScreens se u .NET Frameworku KESIRA po
      procesu, pa nakon promjene topologije vraca staro stanje. Zato se ovdje
      koristi EnumDisplayDevices, koji je uvijek svjez.
    ==========================================================================

    UPOTREBA
      .\ensure-streaming-ready.ps1              # jednokratno
      .\ensure-streaming-ready.ps1 -Install     # registrira zadatak
      .\ensure-streaming-ready.ps1 -Uninstall
      .\ensure-streaming-ready.ps1 -Reprime     # prisili priming
#>
[CmdletBinding()]
param([switch]$Install, [switch]$Uninstall, [switch]$Quiet, [switch]$Reprime, [switch]$JedanDisplay)

$taskName = 'StreamReady'
$self     = $MyInvocation.MyCommand.Path
$marker   = 'C:\Users\Public\streamready-primed.txt'
$skripte  = Split-Path $self -Parent
function Say($m) { if (-not $Quiet) { Write-Host $m } }

# ------------------------------------------------------------------ UNINSTALL
if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Say "Zadatak '$taskName' uklonjen."
  return
}

# -------------------------------------------------------------------- INSTALL
if ($Install) {
  # Task Scheduler pokretanjem powershell.exe nakratko PRIKAZE konzolu, i to
  # unatoc -WindowStyle Hidden - prozor nastane prije nego se stil primijeni.
  # Na svakoj minuti to je vidljiv bljesak. Zato ide preko wscript omotaca,
  # isti trik kao za Sunshine.
  $vbs = Join-Path (Split-Path $self -Parent) 'streamready-hidden.vbs'
  $action = if (Test-Path $vbs) {
    New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
  } else {
    New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -Quiet"
  }

  # Trajanje ponavljanja MORA biti konacno uz StopAtDurationEnd = false.
  # Prazno trajanje uz true zaustavi ponavljanje nakon prvog izvrsavanja.
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
  $rep = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 1) `
            -RepetitionDuration (New-TimeSpan -Days 365)).Repetition
  $rep.StopAtDurationEnd = $false
  # Ponavljanje NAMJERNO ide samo na vremenski okidac. Kad je stajalo na oba,
  # oba su okidala svake minute s pomakom od pola minute, pa je watchdog radio
  # svakih 30 s. Vidljivo u priming-dijagnostika.log 23.8.2026.
  # $trigger.Repetition = $rep

  # DRUGI OKIDAC. Ponavljanje visi o okidacu na koji je zakaceno, pa okidac
  # "pri prijavi" pocinje ponavljati TEK nakon sljedece prijave. Ako se zadatak
  # ponovno registrira usred sesije, NextRunTime ostane prazan i watchdog tiho
  # umre do sljedeceg logona. Izmjereno 23.8.2026.: bio je mrtav 19,8 sati.
  # Zato jos jedan samostalni okidac koji krece odmah.
  $odmah = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(-1)
  $rep2 = (New-ScheduledTaskTrigger -Once -At (Get-Date) `
            -RepetitionInterval (New-TimeSpan -Minutes 1) `
            -RepetitionDuration (New-TimeSpan -Days 365)).Repetition
  $rep2.StopAtDurationEnd = $false
  $odmah.Repetition = $rep2

  # MORA biti Interactive: promjene displaya iz sesije 0 ne diraju korisnikov desktop.
  $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
                 -LogonType Interactive -RunLevel Highest
  $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                 -StartWhenAvailable -MultipleInstances IgnoreNew `
                 -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger, $odmah) `
    -Principal $principal -Settings $settings -Force | Out-Null
  Say "Zadatak '$taskName' registriran - pri prijavi i svake minute, neovisno o prijavi."
  return
}

# ------------------------------------------------------------------- POMOCNO
$sig = @'
using System;
using System.Runtime.InteropServices;

public class SRD {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DISPLAY_DEVICE {
    public int cb;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]  public string DeviceName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
    public int StateFlags;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
  }

  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
    public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
    public uint dmFields;
    public int dmPositionX, dmPositionY;
    public uint dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
    public ushort dmLogPixels;
    public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight;
    public uint dmDisplayFlags, dmDisplayFrequency, dmICMMethod, dmICMIntent, dmMediaType;
    public uint dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }

  // lpDevice je IntPtr da se izbjegne marshalling null stringa
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool EnumDisplayDevicesW(IntPtr lpDevice, uint iDevNum, ref DISPLAY_DEVICE dd, uint flags);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern bool EnumDisplaySettingsW(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)]
  public static extern int ChangeDisplaySettingsExW(string dev, ref DEVMODE dm, IntPtr hwnd, uint flags, IntPtr param);
  [DllImport("user32.dll")]
  public static extern int ChangeDisplaySettingsW(IntPtr dm, uint flags);
  [DllImport("user32.dll")]
  public static extern int SetDisplayConfig(uint a, IntPtr b, uint c, IntPtr d, uint flags);
}
'@
if (-not ('SRD' -as [type])) { Add-Type -TypeDefinition $sig }

# Popis displaya se dohvaca iz SVJEZEG procesa, jer se Screen::AllScreens kesira
# po procesu i nakon promjene topologije vraca staro stanje. Pokusaj s
# EnumDisplayDevices u istom procesu se pokazao nepouzdanim (nekad prazan popis).
# Popis displaya iz SVJEZEG procesa: Screen::AllScreens se kesira po procesu i
# nakon promjene topologije vraca staro stanje.
#
# OPREZ: uzastopni pozivi `& powershell.exe` iz iste skripte znaju vratiti
# prazno - prvi prode, drugi ne. Zato se rezultat sprema u $script:displayCache,
# a osvjezava se izricito preko -Force nakon promjene topologije.
$script:displayCache = $null
function Get-Displays {
  param([switch]$Force)
  if (-not $Force -and $null -ne $script:displayCache) { return $script:displayCache }
  $pomocni = Join-Path $skripte 'list-displays.ps1'
  $lista = @()
  if (Test-Path $pomocni) {
    # Start-Process s preusmjeravanjem u datoteku. Operator poziva (&) je znao
    # vratiti prazno kod drugog uzastopnog poziva iz iste skripte.
    $tmp = Join-Path $env:TEMP "displays-$PID.txt"
    Start-Process -FilePath 'powershell.exe' `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$pomocni`"") `
      -RedirectStandardOutput $tmp -NoNewWindow -Wait
    $izlaz = if (Test-Path $tmp) { Get-Content $tmp } else { @() }
    Remove-Item $tmp -ErrorAction SilentlyContinue
    foreach ($red in @($izlaz)) {
      if ("$red" -match '^(\S+)\|(\d+)\|(\d+)\|(\d+)\|(\w+)$') {
        $lista += [PSCustomObject]@{
          DeviceName = $matches[1]
          Width      = [int]$matches[2]
          Height     = [int]$matches[3]
          Refresh    = [int]$matches[4]
          Primary    = ($matches[5] -eq 'True')
          Area       = [int]$matches[2] * [int]$matches[3]
        }
      }
    }
  }
  $script:displayCache = $lista
  return $lista
}
function Deaktiviraj($ime) {
  $dm = New-Object SRD+DEVMODE
  $dm.dmSize = [Runtime.InteropServices.Marshal]::SizeOf([type]'SRD+DEVMODE')
  [SRD]::EnumDisplaySettingsW($ime, -1, [ref]$dm) | Out-Null
  $dm.dmPelsWidth = 0; $dm.dmPelsHeight = 0; $dm.dmPositionX = 0; $dm.dmPositionY = 0
  # DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT
  $dm.dmFields = 0x00000020 -bor 0x00080000 -bor 0x00100000
  # CDS_UPDATEREGISTRY | CDS_NORESET
  [SRD]::ChangeDisplaySettingsExW($ime, [ref]$dm, [IntPtr]::Zero, (0x00000001 -bor 0x10000000), [IntPtr]::Zero) | Out-Null
  [SRD]::ChangeDisplaySettingsW([IntPtr]::Zero, 0) | Out-Null
}

function Tece-Stream {
  # NVENC sesija > 0 znaci da netko upravo strema. Dok stream tece NE SMIJEMO
  # dirati topologiju - priming bi korisniku srusio rezoluciju usred rada.
  # nvidia-smi u gostu radi djelomicno: baci gresku za device handle fizickog
  # GPU-a, ali --query-gpu prode.
  $smi = 'C:\Windows\System32\nvidia-smi.exe'
  if (-not (Test-Path $smi)) { return $false }
  $izlaz = & $smi --query-gpu=encoder.stats.sessionCount --format=csv,noheader 2>$null
  foreach ($red in @($izlaz)) {
    if ("$red" -match '(\d+)' -and [int]$Matches[1] -gt 0) { return $true }
  }
  return $false
}

function Radi-Vulkan {
  # Izravno pitanje umjesto posrednog pokazatelja: radi li Vulkan uopce?
  # Ako radi, priming ne treba - bez obzira sto se s displayima dogadjalo.
  $vt = Join-Path $skripte 'vulkantest.ps1'
  if (-not (Test-Path $vt)) { return $true }   # ne mogu provjeriti - ne diraj nista
  $tmp = Join-Path $env:TEMP "vk-$PID.txt"
  Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$vt`"") `
    -RedirectStandardOutput $tmp -NoNewWindow -Wait
  $ok = (Get-Content $tmp -Raw -ErrorAction SilentlyContinue) -match 'GeForce|Radeon|Quadro'
  Remove-Item $tmp -ErrorAction SilentlyContinue
  return [bool]$ok
}

function Broj-Vulkan {
  # Vraca broj Vulkan uredaja kao string ('0', '1', ...) ili '?' ako se ne da izmjeriti.
  $vt = Join-Path $skripte 'vulkantest.ps1'
  if (-not (Test-Path $vt)) { return '?' }
  $tmp = Join-Path $env:TEMP "vkbr-$PID.txt"
  Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"`"$vt`"") `
    -RedirectStandardOutput $tmp -NoNewWindow -Wait
  $txt = Get-Content $tmp -Raw -ErrorAction SilentlyContinue
  Remove-Item $tmp -ErrorAction SilentlyContinue
  if ("$txt" -match 'uredaja:\s*(\d+)') { return $Matches[1] }
  return '?'
}

function Dijagnostika($faza) {
  # Zapisuje stanje u trajni dnevnik. Postoji zbog otvorenog pitanja iz 23.8.2026.:
  # deaktivacija Hyper-V displaya je toga dana obarala ICD, a ranije nije. Bez
  # mjerenja PRIJE i POSLIJE deaktivacije nema se sto analizirati - upravo je to
  # mjerenje nedostajalo kad se problem prvi put pojavio.
  try {
    $d = @(Get-Displays -Force)
    $opis = ($d | ForEach-Object { "$($_.DeviceName.Replace('\\.\',''))=$($_.Width)x$($_.Height)@$($_.Refresh)$(if($_.Primary){'*'}else{''})" }) -join ' '
    $red = '{0}  {1,-22} displayi={2}  vulkan={3}  |  {4}' -f `
             (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $faza, $d.Count, (Broj-Vulkan), $opis
    Add-Content -Path 'C:\Users\Public\priming-dijagnostika.log' -Value $red -Encoding UTF8
    Say "  [dijag] $faza  displayi=$($d.Count)  vulkan=$(($red -split 'vulkan=')[1].Split(' ')[0])"
  } catch {
    Add-Content -Path 'C:\Users\Public\priming-dijagnostika.log' -Value "$(Get-Date -Format 'HH:mm:ss')  $faza  GRESKA: $_" -Encoding UTF8
  }
}

# --------------------------------------------------------------------- RADNJA

# 1. Jesmo li na konzoli? Ako nismo, netko je na RDP-u - ne diramo nista.
# Pitaj Windows izravno, ne `query user`. Taj alat ovisi o System32 u PATH-u, a
# kad ga nema izlaz je prazan - pa bi se iz "ne mogu izmjeriti" zakljucilo
# "nisam na konzoli" i watchdog bi tiho stao. Isti obrazac je 24.8.2026. srusio
# instalaciju na G10.
if (-not ('SESIJA2' -as [type])) {
  Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public class SESIJA2 {
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  public static bool Udaljena() { return GetSystemMetrics(0x1000) != 0; }
}
'@
}
if ([SESIJA2]::Udaljena()) {
  Say 'Sesija je udaljena (RDP) - displayi su drugi, preskacem.'
  return
}

Dijagnostika 'na-pocetku'

# 1b. IDENTITET - je li ovo klon VM-a?
#     Sunshineov identitet prema Moonlightu su credentials\cacert.pem (koji
#     Moonlight pinga) i root.uniqueid iz sunshine_state.json. Kopirani VM ih
#     nosi identicne kao izvornik, pa Moonlight vidi dva hosta koji tvrde da su
#     isti stroj i odbija se spojiti.
#
#     Klon se prepoznaje po BIOS UUID-u, kojeg Hyper-V dodjeljuje po VM-u.
#     Pecat pise INSTALL.ps1; ovdje se samo provjerava i, ako se razlikuje,
#     stari identitet se SKLANJA (ne brise) pa ga Sunshine izgenerira nanovo.
$pecatDat = 'C:\Users\Public\luxstream-identity.txt'
$biosUuid = (Get-CimInstance Win32_ComputerSystemProduct -ErrorAction SilentlyContinue).UUID
if ($biosUuid -and (Test-Path $pecatDat)) {
  $pecatSad   = "$biosUuid|$env:COMPUTERNAME"
  $pecatPrije = (Get-Content $pecatDat -Raw).Trim()
  if ($pecatPrije -ne $pecatSad) {
    Say "KLON: pecat je '$pecatPrije', stroj je '$pecatSad'. Radim novi Sunshine identitet."
    $cfgDir = 'C:\Program Files\Sunshine\config'
    $spremi = "C:\Users\Public\sunshine-identitet-stari-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    New-Item -ItemType Directory -Path $spremi -Force | Out-Null
    Get-Process sunshine -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 4
    foreach ($dat in "$cfgDir\credentials\cacert.pem", "$cfgDir\credentials\cakey.pem", "$cfgDir\sunshine_state.json") {
      if (Test-Path $dat) { Move-Item $dat $spremi -Force -ErrorAction SilentlyContinue }
    }
    Set-Content $pecatDat $pecatSad -Encoding ASCII
    Say "  stari identitet je u $spremi - svi klijenti se moraju ponovno spariti"

    # Na klonu se instalater NE pokrece - VM se samo kopira i digne. Zato ovdje
    # treba pociscati i ono sto je vezano za stari stroj:
    #
    #   output_name  = GUID VDD displaya. Specifican je za stroj i na klonu moze
    #                  biti drugi. Ako pokazuje na nepostojeci display, bolje ga
    #                  maknuti - Sunshine tada hvata primarni, a to je bas VDD.
    #   sunshine_name = ime koje se vidi u Moonlightu. Bez sufiksa bi klon i
    #                  izvornik stajali u popisu pod istim imenom.
    $konf = 'C:\Program Files\Sunshine\config\sunshine.conf'
    if (Test-Path $konf) {
      $redci = @(Get-Content $konf -Encoding UTF8 | Where-Object { $_ -notmatch '^\s*(output_name|sunshine_name)\s*=' })
      $sufiks = if ($biosUuid) { '-' + $biosUuid.Substring(0,4) } else { '' }
      $redci += "sunshine_name = $env:COMPUTERNAME$sufiks"
      # BEZ BOM-a - inace Sunshine prvi kljuc procita kao \ufeff... i tiho ga ignorira
      [System.IO.File]::WriteAllLines($konf, $redci, (New-Object System.Text.UTF8Encoding($false)))
      Say "  sunshine.conf: output_name maknut, ime hosta -> $env:COMPUTERNAME$sufiks"
    }
  }
}

# 2. Hyper-V ADAPTER mora biti ukljucen. Bez njega nema ICD-a uopce.
$hv = Get-PnpDevice -FriendlyName 'Microsoft Hyper-V Video' -ErrorAction SilentlyContinue
if (-not $hv) {
  Say 'UPOZORENJE: Microsoft Hyper-V Video adapter ne postoji.'
} elseif ($hv.Status -ne 'OK') {
  Say "Hyper-V adapter je u stanju '$($hv.Status)' - ukljucujem."
  Enable-PnpDevice -InstanceId $hv.InstanceId -Confirm:$false -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 10
} else {
  Say 'Hyper-V adapter: OK.'
}

# 3. PRIMING
#    Potpis = vrijeme podizanja sustava + ime primarnog displaya. Restart VDD
#    RANIJE je potpis bio "vrijeme podizanja | ime primarnog displaya", uz
#    pretpostavku da promjena rezolucije ime ne mijenja. TA PRETPOSTAVKA JE BILA
#    NETOCNA. Kad Sunshine promijeni rezoluciju (dd_resolution_option = auto),
#    display dobije NOVO ime (DISPLAY7 -> DISPLAY9). Watchdog je to citao kao
#    reset display stoga i odradio priming, koji je 23.8.2026. usred rada srusio
#    streaming rezoluciju s 5120x1440 natrag na 1920x1080.
#
#    SADA se pita ono sto nas stvarno zanima - radi li Vulkan - i nikad se ne
#    dira nista dok stream tece. Potpis se i dalje pise, ali samo za dijagnostiku.
$boot     = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime.ToString('o')
$primarni = (@(Get-Displays) | Where-Object { $_.Primary }).DeviceName
$potpis   = "$boot|$primarni"
$primed   = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { '' }

# BRANA PROTIV VRTNJE. Nije fiksna nego ovisi o tome je li zadnji priming USPIO:
#   uspio  -> smijemo opet vec za minutu. To je normalan slucaj: Sunshine pri
#             spajanju klijenta promijeni rezoluciju, ICD pogine za ~15-25 s, i
#             zelimo ga vratiti odmah.
#   nije   -> cekamo 10 minuta. Tada je display stog degradiran i ponavljanje ga
#             samo dodatno kvari (izmjereno 23.8.2026., dva puta).
# Zapis prije podizanja sustava se ne racuna - datoteka prezivi restart.
$zadnjiPrimingDat = 'C:\Users\Public\streamready-lastprime.txt'
$zadnjiUspio = $true
$odZadnjeg = if (Test-Path $zadnjiPrimingDat) {
  try {
    $z = (Get-Content $zadnjiPrimingDat -Raw).Trim() -split '\|'
    $kada = [datetime]::Parse($z[0])
    if ($z.Count -gt 1) { $zadnjiUspio = ($z[1] -eq 'ok') }
    if ($kada -lt (Get-CimInstance Win32_OperatingSystem).LastBootUpTime) { 999 }
    else { ((Get-Date) - $kada).TotalMinutes }
  } catch { 999 }
} else { 999 }
$pauza = if ($zadnjiUspio) { 1 } else { 10 }

if (Tece-Stream) { Say 'Stream tece - priming ce ga nakratko prekinuti (tako je trazeno).' }

$trebaPriming =
  if ($Reprime)        { Say 'Priming na zahtjev (-Reprime).'; $true }
  elseif (Radi-Vulkan) { $false }
  elseif ($odZadnjeg -lt $pauza) {
    Say ("Vulkan ne radi, ali priming je bio prije {0:N1} min (pauza {1} min) - cekam." -f $odZadnjeg, $pauza)
    $false
  }
  else { Say 'Vulkan NE radi - pokrecem priming.'; $true }

if ($trebaPriming) {
  # Zapamti mod koji je NA SNAZI - to je onaj koji je Sunshine postavio za
  # klijenta. Njemu se moramo vratiti PRIJE inicijalizacije drivera.
  $vddSad = @(Get-Displays -Force) | Where-Object { $_.Primary } | Select-Object -First 1
  $modCilj = if ($vddSad) { @{ W = $vddSad.Width; H = $vddSad.Height; Hz = $vddSad.Refresh } } else { $null }
  if ($modCilj) { Say "  ciljni mod: $($modCilj.W)x$($modCilj.H) @ $($modCilj.Hz) Hz" }

  Say 'Priming: aktiviram Hyper-V display.'
  # SDC_APPLY | SDC_TOPOLOGY_EXTEND
  $rc = [SRD]::SetDisplayConfig(0, [IntPtr]::Zero, 0, [IntPtr]::Zero, (0x80 -bor 0x04))
  Say "  extend rc=$rc"
  Start-Sleep -Seconds 10

  # REDOSLIJED JE BITAN. `extend` zna resetirati mod VDD-a na zadani, a SVAKA
  # promjena moda POSLIJE inicijalizacije drivera obara ICD. Zato se mod vraca
  # ovdje, a driver se inicijalizira TEK ZATIM. Izmjereno 23.8.2026. u 15:29:
  # extend -> postavi 5120x1440 -> init  =  Vulkan radi.
  if ($modCilj) {
    $sada = @(Get-Displays -Force) | Where-Object { $_.Primary } | Select-Object -First 1
    if ($sada -and ($sada.Width -ne $modCilj.W -or $sada.Height -ne $modCilj.H)) {
      Say "  vracam mod $($sada.Width)x$($sada.Height) -> $($modCilj.W)x$($modCilj.H)"
      $sr = Join-Path $skripte 'set-resolution-from-client.ps1'
      if (Test-Path $sr) {
        $env:SUNSHINE_CLIENT_WIDTH = $null; $env:SUNSHINE_CLIENT_HEIGHT = $null; $env:SUNSHINE_CLIENT_FPS = $null
        & $sr -Sirina $modCilj.W -Visina $modCilj.H -Fps $modCilj.Hz | Out-Null
      }
    }
  }

  # Nije dovoljno da put bude aktivan - driver se mora INICIJALIZIRATI dok jest,
  # i to POSLIJE zadnje promjene moda.
  Say '  inicijaliziram NVIDIA driver dok je put aktivan...'
  foreach ($test in @('vulkantest.ps1', 'gltest.ps1')) {
    $put = Join-Path $skripte $test
    if (Test-Path $put) {
      try { (& $put 2>&1) | Select-String 'uredaja:|GL_RENDERER' | ForEach-Object { Say "    $_" } }
      catch { Say "    $test pao: $_" }
    }
  }

  Dijagnostika 'poslije-priminga'
}

# 4. Deaktiviraj Hyper-V display (najmanja povrsina), NIKAD VDD.
# Svjez popis treba samo ako je priming mijenjao topologiju. Inace je popis iz
# koraka 3 jos uvijek tocan, a izbjegava se drugi uzastopni poziv koji zna pasti.
$svi = @(if ($trebaPriming) { Get-Displays -Force } else { Get-Displays })
# ODLUKA OD 23.8.2026.: Hyper-V display OSTAJE aktivan.
#
# Izmjereno na svjezem stogu odmah nakon podizanja sustava:
#   17:03:53  displayi=2  vulkan=1
#   17:04:05  displayi=1  vulkan=0   <- pao odmah po deaktivaciji
#   17:05:20  displayi=1  vulkan=1
#   17:05:52  displayi=1  vulkan=0   <- pao unutar 32 s
# S dva displaya Vulkan i OpenGL rade pouzdano, s jednim ne prezive.
#
# Deaktivacija je zato ISKLJUCENA. Watchdog se inace vrtio: primi, deaktiviraj,
# Vulkan padne, za minutu opet - i trepnuo bi slikom svaki put.
#
# Prozori koji odlutaju na taj display vraca scripts\vrati-prozore.ps1.
# Za staro ponasanje (jedan display, bez izvornog Vulkana) dodaj -JedanDisplay.
if (-not $JedanDisplay -and $svi.Count -ge 2) {
  Say "Dva displaya - tako i ostaje (izvorni Vulkan/OpenGL trazi aktivan Hyper-V display)."
} elseif ($JedanDisplay -and $svi.Count -ge 2) {
  $hvd = $svi | Sort-Object Area | Select-Object -First 1
  Say "Deaktiviram Hyper-V display $($hvd.DeviceName) ($($hvd.Width)x$($hvd.Height))."
  Deaktiviraj $hvd.DeviceName
  Start-Sleep -Seconds 6
  Start-Sleep -Seconds 2
  Say "  ostalo displaya: $(@(Get-Displays -Force).Count)"
  Dijagnostika 'poslije-deaktivacije'
} elseif ($svi.Count -eq 1) {
  Say "Jedan display ($($svi[0].Width)x$($svi[0].Height) @ $($svi[0].Refresh) Hz) - u redu."
} else {
  Say 'UPOZORENJE: nema nijednog prikacenog displaya!'
}


# 4b. Sporedni zaslon drzi DOLJE-DESNO, i vrati sve sto je na njemu zavrsilo.
#
#     Windows slaze ikone od gornjeg LIJEVOG kuta VIRTUALNOG desktopa. Dok je
#     sporedni stajao lijevo, ishodiste je bilo NA NJEMU i svaka nova mapa je
#     zavrsavala ondje. Dijagonalno dolje-desno ishodiste postaje (0,0), a
#     zasloni se dodiruju samo u tocki pa mis ne moze prijeci.
foreach ($pom in @('pozicioniraj-sporedni.ps1', 'vrati-s-malog-ekrana.ps1')) {
  $pp = Join-Path $skripte $pom
  if (Test-Path $pp) {
    try { & $pp -Quiet | Out-Null } catch { Say "  $pom pao: $_" }
  }
}

# 4c. Zapisi je li priming USPIO. Kocnica na temelju toga bira pauzu: nakon
#     uspjeha smije opet za minutu (normalan slucaj - Sunshine promijeni
#     rezoluciju pri spajanju i ICD pogine), nakon neuspjeha ceka 10 minuta
#     (stog je degradiran i ponavljanje ga samo kvari).
if ($trebaPriming) {
  $uspjeh = if (Radi-Vulkan) { 'ok' } else { 'fail' }
  Set-Content $zadnjiPrimingDat ((Get-Date).ToString('o') + '|' + $uspjeh) -Encoding ASCII
  Say "  ishod priminga: $uspjeh"
}

# 5. Sunshine
if (Get-Process sunshine -ErrorAction SilentlyContinue) {
  Say 'Sunshine radi.'
} else {
  Say 'Sunshine ne radi - pokrecem zadatak SunshineUser.'
  Start-ScheduledTask -TaskName 'SunshineUser' -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 12
  $p = Get-Process sunshine -ErrorAction SilentlyContinue
  Say "  sunshine: $(if ($p) { "PID $($p.Id)" } else { 'NIJE SE PODIGAO' })"
  if (-not $p) {
    # Zadatak ga pali kroz VBS omotac (da nema konzolnog prozora). Ako taj put
    # zakaze - nema skripte, wscript blokiran politikom - ne smijemo ostati bez
    # streama. Zato izravno pokretanje kao zadnja linija obrane. Tada se konzolni
    # prozor vidi, ali to je bolje nego da Sunshine uopce ne radi.
    $exe = 'C:\Program Files\Sunshine\Sunshine.exe'
    if (Test-Path $exe) {
      Say '  zadatak ga nije podigao - pokrecem izravno (prozor ce se vidjeti)'
      Start-Process $exe -WorkingDirectory (Split-Path $exe -Parent) -ErrorAction SilentlyContinue | Out-Null
      Start-Sleep -Seconds 10
      $p = Get-Process sunshine -ErrorAction SilentlyContinue
      Say "  sunshine: $(if ($p) { "PID $($p.Id)" } else { 'I DALJE NE RADI' })"
    }
  }
}

# 6. Potpis se zapisuje TEK na kraju, kad je stanje slozeno.
if ($trebaPriming) {
  $konacni = (@(Get-Displays -Force) | Where-Object { $_.Primary }).DeviceName
  Set-Content -Path $marker -Value "$boot|$konacni" -Encoding UTF8
  Say "Potpis zapisan: $boot|$konacni"
}
