<#
    luxstream-bridge.ps1
    Dvosmjerni most izmedju VM-a (Sunshine) i klijenta (Moonlight):

      * MEDUSPREMNIK  - tekst, slika (PNG) i POPIS kopiranih datoteka
      * DATOTEKE      - mapa Drop/ -> mapa Primljeno/ na drugoj strani

    Sunshine i Moonlight ne dijele ni meduspremnik ni datoteke. To nije
    postavka koja nedostaje, nego funkcija koje u protokolu NEMA: Sunshine
    prenosi samo sliku, zvuk i ulaz. Provjereno - sunshine.exe nema nijednu
    referencu na Windows clipboard API (OpenClipboard, SetClipboardData,
    CF_UNICODETEXT - sve nula).

    Most to popunjava IZVAN protokola, obicnim TCP-om. Protokol streama se
    ne dira, pa radi s bilo kojom verzijom Sunshinea i Moonlighta.

    Zamjenjuje stari clipboard-bridge.ps1, koji je prenosio samo tekst.

    ==========================================================================
    POKRETANJE
    ==========================================================================

    Na HOSTU (posluzitelj). Host na Default Switchu ima fiksnu adresu, pa je
    host prirodna strana koja slusa:

        .\luxstream-bridge.ps1 -Mode Server

    U VM-u (klijent). Ako se -Peer ne zada, uzima se zadani gateway - a to je
    na Default Switchu upravo host:

        .\luxstream-bridge.ps1 -Mode Client

    Adresa Default Switcha NIJE ista na svakom stroju: 172.29.32.1 je cest,
    ali 172.21.80.1 je takoder uobicajen (vidi Nadji-Switch). Skripta ju sama
    procita, pa se i popis dopustenih klijenata i naredba za vatrozid izvode
    iz nje umjesto iz tvrde vrijednosti - inace most tiho odbija svaki spoj.

    Automatski (registrira zakazani zadatak pri prijavi):

        .\luxstream-bridge.ps1 -Mode Client -Install

    Isto za posluzitelj, uz odmah otvoren port (trazi ovlasti):

        .\luxstream-bridge.ps1 -Mode Server -Install -DopustiVatru

    Provjera na jednom stroju, bez ikakve vanjske veze:

        .\luxstream-bridge.ps1 -SelfTest

    Provjera stanja i uklanjanje:

        .\luxstream-bridge.ps1 -Status
        .\luxstream-bridge.ps1 -Uninstall      (zadatak; konfiguracija ostaje)

    Ostalo (-NoClipboard, -NoFiles, -PollMs, -ChunkKB, -AllowedClients, granice
    velicina) ima razumne zadane vrijednosti - vidi param blok.

    ==========================================================================
    ZASTO HOST SLUSA, A VM SE SPAJA
    ==========================================================================
    Default Switch daje hostu fiksnu adresu i to se ne mijenja. Adresa VM-a se
    mijenja (DHCP + klonovi), pa bi je na hostu trebalo stalno prepisivati.
    Ovako je jedina adresa koju treba znati - fiksna.

    Nije obavezno: moze i obrnuto, -Mode Server u VM-u uz -AllowedClients
    podesen na adresu hosta.

    ==========================================================================
    PROTOKOL
    ==========================================================================
    TCP, jedan spoj, oba smjera istovremeno. Okvir:

        [1 B tip][4 B duljina LE][payload]

    tipovi:
        0x01  HELLO      UTF-8 JSON  { v, secret }   -> 0x02 HELLO_OK
        0x02  HELLO_OK   UTF-8 'OK'
        0x10  TEKST      UTF-8 tekst (najvise MaxTextBytes)
        0x11  SLIKA      PNG bajtovi (najvise MaxImageBytes)
        0x12  POPIS      UTF-8 JSON  { count, ukupno }  - najava grupe datoteka
        0x20  F_POCETAK  UTF-8 JSON  { name, size }
        0x21  F_KOMAD    sirovi bajtovi (komad od ChunkBytes)
        0x22  F_KRAJ     prazno

    POPIS sluzi da se nakon cijele grupe primljene datoteke mogu staviti u
    meduspremnik - tako "copy file" u Exploreru na jednoj strani zavrsi kao
    paste datoteke na drugoj, bez ikakvog rucnog koraka.

    ==========================================================================
    OGRANICENJA (namjerna)
    ==========================================================================
      * Promet NIJE kriptiran. Zajednicka tajna u HELLO samo sprecava slucajan
        spoj, ne prisluskivanje. Namijenjeno povjerljivom LAN-u.
      * Mape se ne prenose rekurzivno - samo datoteke. Za mapu je koristi
        arhivu ili kopiraj u Drop/ u vise prolaza.
      * Most radi u INTERAKTIVNOJ sesiji. Windows servis u sesiji 0 ne vidi
        meduspremnik korisnika, pa kao servis NE RADI (tiho, bez greske).
#>
[CmdletBinding()]
param(
  [ValidateSet('Server','Client')][string]$Mode,

  [string]$Peer,                                  # Client: adresa posluzitelja
  [int]$Port = 51888,

  [string]$Secret,                                # prazno -> iz konfiguracije ili nova
  [string[]]$AllowedClients = @('172.29.','192.168.','10.','127.'),

  [int]$PollMs = 400,
  [int]$ChunkKB = 256,

  [int]$MaxTextBytes  = 1048576,                  # 1 MB
  [int]$MaxImageBytes = 16777216,                 # 16 MB
  [int]$MaxFrameBytes = 67108864,                 # 64 MB - tvrdi zastit od ludog para
  [int]$ClipFileMaxMB = 64,                       # najveci UKUPNI promet pri copy/paste datoteka
  [int]$DropFileMaxMB = 4096,                     # najveca pojedinacna datoteka iz Drop/

  [switch]$NoClipboard,
  [switch]$NoFiles,

  [switch]$DopustiVatru,                          # uz -Install -Mode Server: otvori port sada

  [switch]$Install,
  [switch]$Uninstall,
  [switch]$Status,
  [switch]$SelfTest,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- konstante
$zadatak  = 'LuxstreamBridge'
$konf     = 'C:\ProgramData\Luxstream\bridge.json'
$dom      = Join-Path $env:USERPROFILE 'Luxstream'
$drop     = Join-Path $dom 'Drop'
$prim     = Join-Path $dom 'Primljeno'
$posl     = Join-Path $dom 'Poslano'
$dnevnik  = Join-Path $dom 'luxstream-bridge.log'
$dnevnikMax = 2MB

function Say($m) { if (-not $Quiet) { Write-Host $m } }

function Log($m) {
  $redak = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m
  if (-not $Quiet) { Write-Host ('  ' + $m) }
  try {
    if ((Test-Path $dnevnik) -and ((Get-Item $dnevnik).Length -gt $dnevnikMax)) {
      Move-Item $dnevnik "$dnevnik.1" -Force
    }
    Add-Content -Path $dnevnik -Value $redak -Encoding UTF8
  } catch { }
}

function Osiguraj-Mape {
  foreach ($m in @($dom, $drop, $prim, $posl)) {
    if (-not (Test-Path $m)) { New-Item -ItemType Directory -Path $m -Force | Out-Null }
  }
}

# ------------------------------------------------------------------- config
function Ucitaj-Konf {
  if (Test-Path $konf) {
    try { return (Get-Content $konf -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
  }
  return $null
}

function Spremi-Konf($o) {
  $dir = Split-Path $konf -Parent
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  # Bez BOM-a: ConvertFrom-Json na PS 5.1 se na BOM-u zna zagrcnuti.
  $json = $o | ConvertTo-Json -Depth 4
  [System.IO.File]::WriteAllText($konf, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Nova-Tajna {
  $b = New-Object byte[] 24
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($b)
  ([BitConverter]::ToString($b)).Replace('-','').ToLower()
}

# ------------------------------------------------------ mreza (Default Switch)
# Opis ove strane na Default Switchu - ili $null ako ga na stroju nema.
#
# Zasto se cita, a ne upisuje: u ovom se sklopu VM spaja na host preko Default
# Switcha, pa se i popis dopustenih klijenata i pravilo vatrozida moraju
# odnositi na TOCNO TU mrezu. ona NIJE svugdje 172.29.32.0/24. Kad se popis
# ostavi tvrd ('172.29.'), posluzitelj na stroju s npr. 172.21.80.0/20 odbije
# svaki spoj - u dnevniku pise ODBIJEN, a na drugoj strani samo puca veza bez
# ijednog objasnjenja. Zato se prefiksi izvode iz stvarne adrese.
function Nadji-Switch {
  $k = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
         Where-Object { $_.InterfaceAlias -like '*Default Switch*' -and $_.IPAddress -notlike '169.254.*' } |
         Select-Object -First 1
  if (-not $k) { return $null }

  $o = @($k.IPAddress.Split('.') | ForEach-Object { [int]$_ })
  $p = [int]$k.PrefixLength

  # mreza: adresa s maskom po bitovima (/20 -> 172.21.80.0)
  $net = @(0, 0, 0, 0); $ostalo = $p
  for ($i = 0; $i -lt 4; $i++) {
    $bit = [Math]::Min(8, [Math]::Max(0, $ostalo))
    if ($bit -eq 8) { $net[$i] = $o[$i] }
    elseif ($bit -gt 0) { $net[$i] = $o[$i] -band (256 - [int][Math]::Pow(2, 8 - $bit)) }
    $ostalo -= 8
  }

  # prefiks za usporedbu ide na granicu okteta (/20 -> '172.21.'), sto je sire
  # od same mreze. Namjerno: prefiks je samo grubi filtar protiv tudih mreza,
  # a stvarno odbija zajednicka tajna. Uzu, tocnu mrezu nosi pravilo vatrozida.
  $koliko = [Math]::Floor($p / 8)
  $pref = (($net[0..([Math]::Max(0, $koliko - 1))]) -join '.') + '.'

  @{
    Ali     = $k.InterfaceAlias
    Ip      = $k.IPAddress
    Prefiks = $p
    Mreza   = (($net -join '.') + '/' + $p)
    Tekst   = $pref
  }
}

# Nadji-Switch se poziva s nekoliko mjesta (popis dopustenih, -Install, -Status).
# Citanje se kesira: racuna se jednom, a svaki poziv vrati isti odgovor.
$script:Mreza = $null
$script:MrezaProcitano = $false
function Daj-Mrezu {
  if (-not $script:MrezaProcitano) {
    $script:Mreza = Nadji-Switch
    $script:MrezaProcitano = $true
  }
  $script:Mreza
}

# ------------------------------------------------------- meduspremnik (STA)
# Windows clipboard API radi samo iz STA niti. Interaktivni powershell.exe jest
# STA, ali zakazani zadaci i pozadinski procesi znaju biti MTA, gdje se
# meduspremnik TIHO ne procita ni ne postavi - bez ijedne greske. Zato se drzi
# jedan trajni STA runspace i sav pristup ide kroz njega.
$script:StaRs = $null
$script:PreskociDo = [datetime]::MinValue

function Init-Sta {
  if ($script:StaRs) { return }
  $rs = [RunspaceFactory]::CreateRunspace()
  $rs.ApartmentState = 'STA'
  $rs.ThreadOptions  = 'ReuseThread'
  $rs.Open()
  $ps = [PowerShell]::Create(); $ps.Runspace = $rs
  $null = $ps.AddScript('Add-Type -AssemblyName System.Windows.Forms; Add-Type -AssemblyName System.Drawing')
  $null = $ps.Invoke(); $ps.Dispose()
  $script:StaRs = $rs
}

# Vraca TOCNO JEDAN objekt koji je STA skripta ispisala (ili $null).
#
# Dva su ugovora ovdje namjerna, jer se oba lako prekrse i to tiho:
#   1. STA skripta NE SMIJE kao zavrsni izraz ispisati polje. PowerShell ga
#      razvuce u N izlaznih objekata, pa se od byte[] (PNG) vrati samo prvi
#      bajt - a provjere tipa "duljina > 50" i "preneseno identicno" ispadnu
#      besmislene, ali ne i vidljivo pogresne. Kad treba polje, umota se u
#      rjecnik: @{ Png = $ms.ToArray() } - rjecnik se ne razvlaci.
#   2. PSObject NE treba rucno raspetljavati. `.BaseObject` na obicnom
#      hashtableu ili byte[] vraci $null (ta svojstva ne postoje), pa bi
#      "sigurnosna" provjera `if ($x -is [PSObject]) { $x = $x.BaseObject }`
#      obrisala upravo ono sto se prenosi. PowerShell omot skida sam.
function Invoke-Sta([string]$kod, [hashtable]$vars) {
  Init-Sta
  $ps = [PowerShell]::Create(); $ps.Runspace = $script:StaRs
  if ($vars) { foreach ($k in $vars.Keys) { $script:StaRs.SessionStateProxy.SetVariable($k, $vars[$k]) } }
  $null = $ps.AddScript($kod)
  try {
    $r = $ps.Invoke()
    # Greske iz STA runspacea bi inace nestale bez traga - a upravo je tihi
    # neuspjeh (npr. MTA nit) razlog zasto cijeli ovaj sloj postoji.
    if ($ps.Streams.Error.Count -gt 0) {
      Log ("  [!] STA: " + $ps.Streams.Error[0].ToString())
    }
    if ($r.Count -eq 0) { return $null }
    if ($r.Count -gt 1) { Log ("  [!] STA je ispisao $($r.Count) objekata - koristim samo prvi") }
    return $r[0]
  } finally { $ps.Dispose() }
}

function Hash([string]$s) {
  if ([string]::IsNullOrEmpty($s)) { return '' }
  $md5 = [System.Security.Cryptography.MD5]::Create()
  ([BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','')
}

# Jedan prolaz kroz meduspremnik vraca sve tri vrste odjednom - tri odvojena
# poziva bila bi tri STA kruga po anketi, a anketa ide 2-3 puta u sekundi.
# Redoslijed je NAMJERAN: datoteke -> tekst -> slika.
#   Kopiranje datoteke u Exploreru postavlja CF_HDROP, ali cesto i CF_UNICODETEXT
#   s putanjom. Da tekst ide prvi, poslala bi se samo putanja, a datoteka ne.
function Dohvati-Meduspremnik {
  if ($NoClipboard) { return @{ Vrsta = 'none' } }
  try {
    $o = Invoke-Sta {
      $r = @{ Vrsta = 'none' }
      if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) {
        $popis = [System.Windows.Forms.Clipboard]::GetFileDropList()
        $dat = @()
        foreach ($p in $popis) { if ($p -and (Test-Path -LiteralPath $p -PathType Leaf)) { $dat += $p } }
        if ($dat.Count -gt 0) { $r.Vrsta = 'files'; $r.Datoteke = $dat; return $r }
      }
      if ([System.Windows.Forms.Clipboard]::ContainsText()) {
        $t = [System.Windows.Forms.Clipboard]::GetText()
        if (-not [string]::IsNullOrEmpty($t)) { $r.Vrsta = 'text'; $r.Tekst = $t; return $r }
      }
      if ([System.Windows.Forms.Clipboard]::ContainsImage()) {
        $img = [System.Windows.Forms.Clipboard]::GetImage()
        if ($img) {
          $ms = New-Object System.IO.MemoryStream
          $img.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
          $r.Vrsta = 'image'; $r.Png = $ms.ToArray()
        }
      }
      $r
    } $null
    # STA skripta vraca rjecnik kao JEDAN objekt, pa nema indeksiranja ni
    # raspetljavanja omota (vidi ugovor uz Invoke-Sta). Slika se ipak svodi
    # na pravi byte[] - kroz granicu runspacea zna doci umotana u PSObject.
    if ($o) {
      if ($o.Vrsta -eq 'image' -and $o.Png) { $o.Png = [byte[]]$o.Png }
      return $o
    }
  } catch { }
  return @{ Vrsta = 'none' }
}

function Postavi-Tekst([string]$t) {
  if ([string]::IsNullOrEmpty($t)) { return $false }
  try { $null = Invoke-Sta '[System.Windows.Forms.Clipboard]::SetText($K); ""' @{ K = $t }; return $true }
  catch { Log "  [!] ne mogu postaviti tekst u meduspremnik: $($_.Exception.Message)"; return $false }
}

function Postavi-Sliku([byte[]]$bytes) {
  if (-not $bytes -or $bytes.Length -eq 0) { return $false }
  try {
    $null = Invoke-Sta @'
$ms = New-Object System.IO.MemoryStream
$ms.Write($B, 0, $B.Length)
$ms.Position = 0
$img = [System.Drawing.Image]::FromStream($ms)
[System.Windows.Forms.Clipboard]::SetImage($img)
""
'@ @{ B = $bytes }
    return $true
  } catch { Log "  [!] ne mogu postaviti sliku u meduspremnik: $($_.Exception.Message)"; return $false }
}

function Postavi-Datoteke([string[]]$putanje) {
  if (-not $putanje -or $putanje.Count -eq 0) { return $false }
  try {
    $null = Invoke-Sta @'
$k = New-Object System.Collections.Specialized.StringCollection
foreach ($p in $P) { [void]$k.Add($p) }
[System.Windows.Forms.Clipboard]::SetFileDropList($k)
""
'@ @{ P = $putanje }
    return $true
  } catch { Log "  [!] ne mogu postaviti datoteke u meduspremnik: $($_.Exception.Message)"; return $false }
}

# Nakon sto se meduspremnik POSTAVI iz mreze, mora se ponovno procitati i
# zapamtiti - inace bi ga lokalna anketa vidjela kao "novo" i poslala natrag.
# Ponovno citanje (a ne prepisivanje poslanog hasha) pokriva i slucaj kad se
# slika pri ponovnom kodiranju u PNG ne dobije bajt-identicna.
function Zapamti-Trenutni {
  $s = Dohvati-Meduspremnik
  $script:ZadnjiHash = Prezivjeli-Hash $s
  $script:PreskociDo = (Get-Date).AddSeconds(1.5)
}

function Prezivjeli-Hash($s) {
  switch ($s.Vrsta) {
    'text'  { return 'T' + (Hash $s.Tekst) }
    'image' { return 'I' + (Hash ([Convert]::ToBase64String($s.Png))) }
    'files' { return 'F' + (Hash (($s.Datoteke | Sort-Object) -join '|')) }
    default { return 'N' }
  }
}

# --------------------------------------------------------------- okviri/IO
function Send-Frame($stream, [byte]$tip, [byte[]]$payload) {
  if ($null -eq $payload) { $payload = @() }
  $len = [BitConverter]::GetBytes([int]$payload.Length)
  $stream.WriteByte($tip)
  $stream.Write($len, 0, 4)
  if ($payload.Length -gt 0) { $stream.Write($payload, 0, $payload.Length) }
  $stream.Flush()
}

function Read-Exact($stream, [int]$n) {
  $buf = New-Object byte[] $n
  $read = 0
  while ($read -lt $n) {
    $k = $stream.Read($buf, $read, $n - $read)
    if ($k -le 0) { throw 'veza zatvorena' }
    $read += $k
  }
  , $buf
}

function Receive-Frame($stream) {
  $tip = $stream.ReadByte()
  if ($tip -lt 0) { throw 'veza zatvorena' }
  $lenB = Read-Exact $stream 4
  $len  = [BitConverter]::ToInt32($lenB, 0)
  if ($len -lt 0 -or $len -gt $MaxFrameBytes) { throw "neispravna duljina okvira: $len" }
  $pl = @()
  if ($len -gt 0) { $pl = Read-Exact $stream $len }
  @{ Tip = [byte]$tip; Payload = $pl }
}

function Json-Ukratko($o) { ($o | ConvertTo-Json -Compress) }
function Utf8([string]$s) { [Text.Encoding]::UTF8.GetBytes($s) }

function Ocisti-Ime([string]$n) {
  if ([string]::IsNullOrWhiteSpace($n)) { return 'datoteka' }
  $n = $n -replace '.*[\\/]', ''                      # odbaci svaku putanju
  $n = $n -replace '[<>:"|?*\x00-\x1f]', '_'          # sto Windows ne dopusta
  $n = $n.Trim(' ', '.')
  if ([string]::IsNullOrWhiteSpace($n)) { return 'datoteka' }
  if ($n.Length -gt 180) { $n = $n.Substring(0, 180) }
  if ($n -eq '.' -or $n -eq '..') { return 'datoteka' }
  $n
}

function Slobodno-Ime($dir, [string]$ime) {
  $p = Join-Path $dir $ime
  if (-not (Test-Path -LiteralPath $p)) { return $p }
  $baza = [System.IO.Path]::GetFileNameWithoutExtension($ime)
  $ext  = [System.IO.Path]::GetExtension($ime)
  $i = 1
  while ($i -lt 10000) {
    $kand = Join-Path $dir ("$baza-$i$ext")
    if (-not (Test-Path -LiteralPath $kand)) { return $kand }
    $i++
  }
  Join-Path $dir ((Get-Date).ToString('HHmmss') + '-' + $ime)
}

# ------------------------------------------------------------ slanje datoteke
function Send-Datoteku($stream, [string]$putanja) {
  $fi = Get-Item -LiteralPath $putanja -ErrorAction Stop
  if ($fi.Length -gt ($DropFileMaxMB * 1MB)) {
    throw ("prevelika ({0} MB > {1} MB)" -f [math]::Round($fi.Length/1MB,1), $DropFileMaxMB)
  }
  Send-Frame $stream 0x20 (Utf8 (Json-Ukratko @{ name = $fi.Name; size = [int64]$fi.Length }))

  $fs = [System.IO.File]::Open($putanja, 'Open', 'Read', 'ReadWrite')
  try {
    $komad = $ChunkKB * 1024
    $buf = New-Object byte[] $komad
    $ukupno = 0
    while ($true) {
      $n = $fs.Read($buf, 0, $komad)
      if ($n -le 0) { break }
      if ($n -eq $komad) {
        Send-Frame $stream 0x21 $buf
      } else {
        $kratki = New-Object byte[] $n
        [Array]::Copy($buf, 0, $kratki, 0, $n)
        Send-Frame $stream 0x21 $kratki
      }
      $ukupno += $n
    }
    Send-Frame $stream 0x22 @()
    return $ukupno
  } finally { $fs.Dispose() }
}

# Izvor izlazne grupe: @{ Datoteke = @(putanje); Clip = $true/$false }
function Posalji-Grupu($stream, $grupa) {
  $popis = @($grupa.Datoteke)
  if ($popis.Count -eq 0) { return }
  $ukupno = 0
  foreach ($p in $popis) { try { $ukupno += (Get-Item -LiteralPath $p -EA Stop).Length } catch { } }

  if ($grupa.Clip) {
    Send-Frame $stream 0x12 (Utf8 (Json-Ukratko @{ count = $popis.Count; ukupno = [int64]$ukupno }))
  }

  $poslano = 0
  foreach ($p in $popis) {
    try {
      $n = Send-Datoteku $stream $p
      $poslano++
      Log ("  -> datoteka {0}  ({1} B)" -f (Split-Path $p -Leaf), $n)
      if ($grupa.Premjesti) {
        $odred = Slobodno-Ime $posl $([System.IO.Path]::GetFileName($p))
        try { Move-Item -LiteralPath $p -Destination $odred -Force -EA Stop } catch { }
      }
    } catch {
      Log ("  [!] {0}: {1}" -f (Split-Path $p -Leaf), $_.Exception.Message)
    }
  }
  $grupa.Poslano = $poslano
}

# --------------------------------------------------------- primanje datoteke
function Zavrsi-Primanje($rx, $stream) {
  if (-not $rx) { return }
  try { if ($rx.Fs) { $rx.Fs.Dispose() } } catch { }
  $script:Rx = $null
  Log ("  <- datoteka {0}  ({1} B)" -f (Split-Path $rx.Putanja -Leaf), $rx.Got)
  if ($rx.ClipGrupa -and $rx.Grupa -and $rx.Grupa.Preostalo -le 0) {
    if (Postavi-Datoteke $rx.Grupa.Putanje) {
      Log ("  <- u meduspremnik stavljeno {0} datoteka" -f $rx.Grupa.Putanje.Count)
      Zapamti-Trenutni
    }
    $script:Grupa = $null
  }
}

function Nadji-Proces {
  # Get-Process u PS 5.1 nema CommandLine (to je svojstvo CIM objekta), pa se
  # ovdje ide preko Win32_Process.
  #
  # Iskljucuje se SEBE i jednokratne nacine rada. I njihova naredbena linija
  # sadrzi putanju do skripte, pa bi bez toga:
  #   * -Status javio "most RADI" i onda kad je taj proces jedini koji ju
  #     spominje - a to je upravo on sam;
  #   * -Uninstall ubio sam sebe odmah nakon odjave zadatka, pa se zavrsna
  #     poruka nikad ne bi ispisala.
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $_.ProcessId -ne $PID -and
      $_.CommandLine -like '*luxstream-bridge*' -and
      $_.CommandLine -notmatch '-(SelfTest|Status|Install|Uninstall)\b'
    }
}

# ============================================================================
#                                 ZADACI
# ============================================================================
# Popis dopustenih klijenata: ako ga korisnik nije zadao, prefiks ove mreze na
# Default Switchu ide ispred opcih. Bez toga posluzitelj na stroju ciji switch
# nije 172.29.32.0/24 odbije svaki spoj ("ODBIJEN" u dnevniku), a na drugoj
# strani se vidi samo puknuta veza. Opci prefiksi ostaju kao rezerva za rucne
# slucajeve (npr. klijent s drugog stroja u LAN-u).
#
# Ovo ide OVDJE, a ne u zadane vrijednosti param bloka: zadana vrijednost se
# racuna prije nego je Nadji-Switch uopce definiran, a i mora se primijeniti i
# na -Install i na -Status, koji se izvrsavaju iznad glavne petlje.
if (-not $PSBoundParameters.ContainsKey('AllowedClients')) {
  $sw = Daj-Mrezu
  if ($sw -and ($AllowedClients -notcontains $sw.Tekst)) {
    $AllowedClients = @($sw.Tekst) + $AllowedClients
  }
}

$self = $MyInvocation.MyCommand.Path
$skripte = Split-Path $self -Parent

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $zadatak -Confirm:$false -ErrorAction SilentlyContinue
  foreach ($p in (Nadji-Proces)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  Say "Zadatak '$zadatak' uklonjen. Konfiguracija je ostala u $konf."
  return
}

if ($Install) {
  if (-not $Mode) { throw 'Uz -Install treba i -Mode Server ili -Mode Client.' }

  $tajna = $Secret
  if (-not $tajna) {
    $stara = Ucitaj-Konf
    if ($stara) { $tajna = $stara.secret }
  }
  if (-not $tajna) { $tajna = Nova-Tajna }

  Spremi-Konf @{
    mode = $Mode; peer = $Peer; port = $Port; secret = $tajna
    allowedClients = $AllowedClients
    instalirano = (Get-Date).ToString('o')
  }

  $vbs = Join-Path $skripte 'luxstream-bridge-hidden.vbs'
  $akcija = if (Test-Path $vbs) {
    New-ScheduledTaskAction -Execute 'wscript.exe' -Argument "`"$vbs`""
  } else {
    # Bez omotaca se nakratko vidi konzolni prozor - isti razlog kao kod
    # Sunshinea i watchdoga. Ne blokira, ali je ruzno.
    Say '[!] nema luxstream-bridge-hidden.vbs - konzola ce se nakratko vidjeti'
    New-ScheduledTaskAction -Execute 'powershell.exe' `
      -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$self`" -Quiet"
  }

  $korisnik = "$env:USERDOMAIN\$env:USERNAME"
  # MORA biti Interactive: sesija 0 ne vidi meduspremnik korisnika.
  $okidac = New-ScheduledTaskTrigger -AtLogOn -User $korisnik
  $princ  = New-ScheduledTaskPrincipal -UserId $korisnik -LogonType Interactive -RunLevel Highest
  $post   = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -StartWhenAvailable -MultipleInstances IgnoreNew `
              -ExecutionTimeLimit ([TimeSpan]::Zero) `
              -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

  # Registracija s -RunLevel Highest trazi ovlasti. Bez njih Register-ScheduledTask
  # padne na "pristup odbijen" - a to je greska koja se ovdje NE vidi kao prekid
  # (CIM cmdleti je ispisu, ali petlja ide dalje), pa bi se lako dogodilo da se
  # ispise "zadatak registriran", a zadatka nema nigdje. Zato se uspjeh provjeri
  # stvarno, a ne po tome sto naredba nije bacila izuzetak.
  $regOk = $true
  try {
    Register-ScheduledTask -TaskName $zadatak -Action $akcija -Trigger $okidac `
      -Principal $princ -Settings $post -Force -ErrorAction Stop | Out-Null
  } catch {
    $regOk = $false
  }

  Say ''
  if ($regOk) {
    Say "Zadatak '$zadatak' registriran ($Mode, port $Port)."
  } else {
    Say "[!] Zadatak NIJE registriran - most se nece sam pokrenuti."
    Say '    Pokreni -Install iz Powershella s ovlastima (Pokreni kao administrator).'
  }
  Say "Konfiguracija: $konf"
  Say ''
  Say 'Zajednicka tajna - MORA BITI ista na obje strane:'
  Say ('  ' + $tajna)
  if ($Mode -eq 'Server') {
    $sw = Daj-Mrezu
    Say ''
    Say "Na drugoj strani pokreni:  -Mode Client -Secret '$tajna'"
    if ($sw) {
      Say 'Klijent ne treba -Peer: sam uzme zadani gateway, a na Default Switchu'
      Say "je to upravo ova adresa ($($sw.Ip) na $($sw.Ali))."
    } else {
      Say 'Na ovom stroju nema Default Switcha, pa klijent ne moze sam pogoditi'
      Say 'adresu - pokreni ga s -Peer <adresa ovog stroja>.'
    }

    # Port mora biti otvoren: bez pravila Windows spoj tiho odbaci, a na drugoj
    # strani samo puca veza bez objasnjenja. Pravilo se ograduje na mrezu s koje
    # klijent dolazi - sire bi pustilo svakoga.
    $pravilo = @{ DisplayName = 'Luxstream bridge'; Direction = 'Inbound'; Protocol = 'TCP'
                  LocalPort = $Port; Action = 'Allow'; Profile = 'Any' }
    if ($sw) { $pravilo.RemoteAddress = $sw.Mreza }
    $naredba = "New-NetFirewallRule -DisplayName 'Luxstream bridge' -Direction Inbound " +
               "-Protocol TCP -LocalPort $Port -Action Allow"
    if ($sw) { $naredba += " -RemoteAddress $($sw.Mreza)" }

    Say ''
    if ($DopustiVatru) {
      Remove-NetFirewallRule -DisplayName 'Luxstream bridge' -ErrorAction SilentlyContinue
      try {
        New-NetFirewallRule @pravilo -ErrorAction Stop | Out-Null
        Say "Port $Port otvoren."
      } catch {
        Say "Port nisam mogao otvoriti sam: $($_.Exception.Message)"
        Say 'Pokreni ovo iz Powershella s ovlastima:'
        Say ('  ' + $naredba)
      }
    } else {
      Say 'Ne zaboravi otvoriti port na ovoj strani (jednom, s ovlastima):'
      Say ('  ' + $naredba)
    }
  } else {
    Say ''
    Say 'Ne zaboravi na HOSTU pokrenuti drugu polovicu:'
    Say "  .\luxstream-bridge.ps1 -Mode Server -Secret '$tajna' -Install"
  }
  # Ako registracija nije prosla, pokretanje nema smisla - zadatka nema.
  if ($regOk) { Start-ScheduledTask -TaskName $zadatak -ErrorAction SilentlyContinue }
  return
}

if ($Status) {
  $k = Ucitaj-Konf
  Say "Konfiguracija: $konf"
  if ($k) { $k | Format-List | Out-String | Write-Host } else { Say '  (nema je)' }
  $p = Nadji-Proces
  Say ("Proces: " + $(if ($p) { "radi, PID $($p.ProcessId -join ',')" } else { 'NE radi' }))
  $t = Get-ScheduledTask -TaskName $zadatak -ErrorAction SilentlyContinue
  Say ("Zadatak: " + $(if ($t) { $t.State } else { 'nije registriran' }))

  $sw = Daj-Mrezu
  if ($sw) {
    Say "Mreza:  $($sw.Ip)/$($sw.Prefiks) na $($sw.Ali)   (mreza $($sw.Mreza))"
  } else {
    Say 'Mreza:  nema Default Switcha na ovom stroju'
  }
  Say ("Dopusteni prefiksi: " + ($AllowedClients -join ', '))
  $fw = Get-NetFirewallRule -DisplayName 'Luxstream bridge' -ErrorAction SilentlyContinue
  if ($fw) { Say "Vatrozid: pravilo postoji ($($fw.Enabled))" } else { Say "Vatrozid: NEMA pravila za port $Port" }

  Say "Mape: $drop  ->  $prim"
  if (Test-Path $dnevnik) {
    Say ''
    Say "--- zadnjih 15 redaka dnevnika ---"
    Get-Content $dnevnik -Tail 15 | ForEach-Object { Say $_ }
  }
  return
}

# ============================================================================
#                                 SAMOTEST
# ============================================================================
if ($SelfTest) {
  Say '=== Samotest mosta (petlja na 127.0.0.1, bez meduspremnika) ==='
  $tmp = Join-Path $env:TEMP ('luxstream-selftest-' + (Get-Date -Format 'HHmmss'))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $uspjeh = $true

  function T($ime, $uvjet) {
    if ($uvjet) { Say ("  [OK]   " + $ime) } else { Say ("  [FAIL] " + $ime); $script:uspjeh = $false }
  }

  # 1. okvir kroz pravi TCP spoj
  $port = 51890 + (Get-Random -Max 8)
  $lis = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port)
  $lis.Start()
  $cli = [System.Net.Sockets.TcpClient]::new()
  $cli.Connect('127.0.0.1', $port)
  $srv = $lis.AcceptTcpClient()
  $a = $srv.GetStream(); $b = $cli.GetStream()
  $a.ReadTimeout = 5000; $b.ReadTimeout = 5000

  Send-Frame $b 0x10 (Utf8 'Hello, ŽČĆŠĐ')
  $f = Receive-Frame $a
  T 'tekst s dijakriticima' (($f.Tip -eq 0x10) -and ([Text.Encoding]::UTF8.GetString($f.Payload) -eq 'Hello, ŽČĆŠĐ'))

  Send-Frame $a 0x10 (Utf8 'nazad')
  $f = Receive-Frame $b
  T 'tekst u oba smjera' ([Text.Encoding]::UTF8.GetString($f.Payload) -eq 'nazad')

  # 2. PNG bajtovi
  Init-Sta
  $o = Invoke-Sta @'
$bmp = New-Object System.Drawing.Bitmap 3,3
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.Clear([System.Drawing.Color]::Red)
$g.Dispose()
$ms = New-Object System.IO.MemoryStream
$bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
# Rjecnik - ne samo zato da se vrati imenovano, nego zato sto bi goli
# $ms.ToArray() kao zavrsni izraz PowerShell razvukao u 126 pojedinacnih
# bajtova i vratio samo prvi. Vidi ugovor uz Invoke-Sta.
@{ Png = $ms.ToArray() }
'@ $null
  $png = if ($o) { $o.Png } else { $null }
  # Vrijednost iz drugog runspacea zna doci umotana u PSObject; Send-Frame je
  # prima kroz [byte[]] pa se omot skine sam, ali ovdje se skida izricito da
  # provjera tipa ne pada bez razloga.
  if ($png) { $png = [byte[]]$png }
  T '3x3 PNG se generirao' (($png -is [byte[]]) -and ($png.Length -gt 50))
  # PNG potpis - da test ne bi prosao na bilo kakvih 50+ bajtova
  T 'PNG ima ispravan potpis' ([BitConverter]::ToString($png[0..7]) -eq '89-50-4E-47-0D-0A-1A-0A')

  Send-Frame $b 0x11 $png
  $f = Receive-Frame $a
  $pngHash = (Get-FileHash -InputStream (New-Object System.IO.MemoryStream (,$png)) -Algorithm MD5).Hash
  $rxHash  = (Get-FileHash -InputStream (New-Object System.IO.MemoryStream (,$f.Payload)) -Algorithm MD5).Hash
  T 'slika prenesena bajt-identicno' (($f.Tip -eq 0x11) -and ($pngHash -eq $rxHash))

  # 3. datoteka: 700 KB da se prijede preko granice komada od 256 KB.
  #    Slanje ide u DRUGU NIT: u jednoj niti bi Send-Datoteku napunio izlazni
  #    medjuspremnik i blokirao se cekajuci da netko cita - a taj netko je
  #    ovdje, na istoj niti. Uvozak (deadlock) je siguran, ne povremen.
  $izvor = Join-Path $tmp 'test.bin'
  $bytes = New-Object byte[] (700 * 1024)
  (New-Object Random 42).NextBytes($bytes)
  [System.IO.File]::WriteAllBytes($izvor, $bytes)

  $script:prim = Join-Path $tmp 'Primljeno'
  New-Item -ItemType Directory -Path $script:prim -Force | Out-Null
  $odred = Join-Path $script:prim 'test.bin'

  # Saljilac dobiva PRAVE funkcije iz ovog skripta, u vlastitom runspaceu.
  #
  # Izvlacenje tijela je osjetljivo na dvije stvari koje su obje provjerene:
  #   * .Definition daje tijelo S param blokom, ali BEZ rijeci "function
  #     <ime>". Splicano tako, u novom runspaceu te linije nisu funkcija
  #     nego INLINE naredbe - pokrenu se odmah pri ucitavanju, prije redaka
  #     s postavkama, i puknu na praznoj granici velicine.
  #   * .Ast.Extent.Text bi dao cijelu definiciju, ali u skripti s
  #     [CmdletBinding()] i param blokom na vrhu vraca prazno.
  # Zato se omot sastavlja rucno. Tijelo se ne prepisuje, pa ne postoji drugi
  # primjerak logike koji bi mogao odlutati od proizvodnog koda.
  $imena = @('Send-Frame', 'Json-Ukratko', 'Utf8', 'Send-Datoteku')
  $defs = (@($imena | ForEach-Object { "function $_ {`n" + (Get-Command $_).Definition + "`n}" }) -join "`n")
  $kod = $defs + "`n" +
         "`$DropFileMaxMB = $DropFileMaxMB`n" +
         "`$ChunkKB = $ChunkKB`n" +
         "Send-Datoteku `$stream `$putanja`n"

  $rs = [RunspaceFactory]::CreateRunspace(); $rs.Open()
  $rs.SessionStateProxy.SetVariable('stream', $b)
  $rs.SessionStateProxy.SetVariable('putanja', $izvor)
  $psS = [PowerShell]::Create(); $psS.Runspace = $rs
  $null = $psS.AddScript($kod)
  $hS = $psS.BeginInvoke()
  T 'saljilac dobiva prave funkcije' (($kod -match 'function Send-Datoteku') -and ($kod -match 'function Send-Frame'))

  try {
    $zag = Receive-Frame $a
    T 'F_POCETAK' ($zag.Tip -eq 0x20)
    $h = [Text.Encoding]::UTF8.GetString($zag.Payload) | ConvertFrom-Json
    T 'najava nosi ime i velicinu' (($h.name -eq 'test.bin') -and ([int64]$h.size -eq $bytes.Length))

    $fs = [System.IO.File]::Open($odred, 'Create', 'Write')
    $got = 0
    while ($true) {
      $f = Receive-Frame $a
      if ($f.Tip -eq 0x22) { break }
      if ($f.Tip -ne 0x21) { throw ("neocekivan tip $($f.Tip)") }
      $fs.Write($f.Payload, 0, $f.Payload.Length)
      $got += $f.Payload.Length
    }
    $fs.Dispose()
    T ("datoteka primljena u cijelosti ({0} B)" -f $got) ($got -eq $bytes.Length)
  } catch {
    T 'datoteka primljena u cijelosti (700 KB)' $false
    Say ("  [!] primanje: " + $_.Exception.Message)
  } finally {
    $null = $psS.EndInvoke($hS)
    foreach ($er in $psS.Streams.Error) { Say ("  [!] saljilac: " + $er.ToString()) }
    $psS.Dispose(); $rs.Close()
  }

  $isti = (Test-Path $odred) -and
          ((Get-FileHash $izvor -Algorithm MD5).Hash -eq (Get-FileHash $odred -Algorithm MD5).Hash)
  T 'sadrzaj datoteke identican (MD5)' $isti

  # 4. imena
  T 'ime bez putanje' ((Ocisti-Ime 'C:\a\b\zlo.txt') -eq 'zlo.txt')
  T 'ime bez zabranjenih znakova' ((Ocisti-Ime 'a<b>c:d.txt') -eq 'a_b_c_d.txt')
  T 'prazno ime se sanira' ((Ocisti-Ime '   ') -eq 'datoteka')
  T 'kolizija dobiva sufiks' ((Split-Path (Slobodno-Ime $script:prim 'test.bin') -Leaf) -eq 'test-1.bin')

  $cli.Close(); $srv.Close(); $lis.Stop()
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue

  Say ''
  if ($uspjeh) { Say '=== SVE PROSLO ===' ; exit 0 } else { Say '=== IMA PALIH ===' ; exit 1 }
}

# ============================================================================
#                                 GLAVNA PETLJA
# ============================================================================
$k = Ucitaj-Konf
if (-not $Mode)     { $Mode = if ($k) { $k.mode } else { $null } }
if (-not $Secret)   { $Secret = if ($k) { $k.secret } else { $null } }
if (-not $Peer -and $k) { $Peer = $k.peer }
if ($k -and $k.port)    { if ($Port -eq 51888) { $Port = [int]$k.port } }

# Mape se stvaraju PRIJE provjera, da bi se razlog zasto most nije krenuo
# imao gdje zapisati. Inace se ovo pokrece iz zakazanog zadatka s skrivenim
# prozorom, pa se kvar ne vidi nigdje - a to je upravo obrazac koji je i sam
# STA runspace uveden da ga ukloni.
Osiguraj-Mape
if (-not $Mode) {
  Log 'most nije pokrenut: nema nacina rada (pokreni -Install)'
  throw 'Nema nacina rada. Zadaj -Mode Server ili -Mode Client (ili pokreni -Install).'
}
if (-not $Secret) {
  Log 'most nije pokrenut: nema zajednicke tajne (pokreni -Install)'
  throw 'Nema zajednicke tajne. Zadaj -Secret ili pokreni -Install.'
}

# Klijent: koje adrese posluzitelja uopce pokusavati.
#
# Uz -Peer se ne nagada - pokusava se tocno ta jedna. Bez -Peer se uzima zadani
# gateway, a to je na Default Switchu upravo host.
#
# Zasto ih moze biti VISE: stroj s Default Switchom cesto ima i drugu zadanu
# rutu (vanjski LAN). Gateway s najboljom metrikom tada ne mora biti host, pa
# bi se klijent zauvijek kucao na vrata koja nisu nigdje. Zato se pamte svi
# kandidati i pokusavaju po redu - pogresan se preskoci u sljedecem krugu.
$kandidati = @()
if ($Mode -eq 'Client') {
  if ($Peer) {
    $kandidati = @($Peer)
  } else {
    try {
      $kandidati = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop |
                       Sort-Object RouteMetric |
                       ForEach-Object { $_.NextHop } |
                       Where-Object { $_ -and $_ -ne '0.0.0.0' } |
                       Select-Object -Unique)
    } catch { }
    if ($kandidati.Count -eq 0) {
      Log 'most nije pokrenut: ne mogu sam odrediti adresu posluzitelja'
      throw 'Ne mogu sam odrediti adresu posluzitelja. Zadaj -Peer <ip>.'
    }
    Say ('Posluzitelj (zadani gateway): ' + ($kandidati -join ', '))
  }
}

function Povezi-Se([string]$Adresa) {
  $klijent = [System.Net.Sockets.TcpClient]::new()
  $klijent.Connect($Adresa, $Port)
  $s = $klijent.GetStream()
  $s.ReadTimeout = 15000
  $s.WriteTimeout = 30000
  Send-Frame $s 0x01 (Utf8 (Json-Ukratko @{ v = 1; secret = $Secret }))
  $odg = Receive-Frame $s
  if ($odg.Tip -ne 0x02 -or [Text.Encoding]::UTF8.GetString($odg.Payload) -ne 'OK') {
    $klijent.Close()
    throw 'posluzitelj je odbio tajnu'
  }
  @{ Klijent = $klijent; Stream = $s }
}

# ------------------------------------------------------------------ posluzitelj
function Vrti-Posluzitelj {
  $lis = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
  $lis.Start()
  Say "Most RADI - posluzitelj na portu $Port"
  Say ("Dopusteni prefiksi: " + ($AllowedClients -join ', '))
  Say ("Drop: $drop   ->   Primljeno: $prim")
  Log "posluzitelj pokrenut, port $Port, dopusteni: $($AllowedClients -join ',')"
  try {
    while ($true) {
      $klijent = $lis.AcceptTcpClient()
      $ip = $klijent.Client.RemoteEndPoint.Address.ToString()

      $dozvoljen = $false
      foreach ($p in $AllowedClients) { if ($ip.StartsWith($p)) { $dozvoljen = $true; break } }
      if (-not $dozvoljen) {
        Log "ODBIJEN $ip (nije na popisu dopustenih)"
        $klijent.Close(); continue
      }

      $s = $klijent.GetStream()
      $s.ReadTimeout = 10000
      $s.WriteTimeout = 30000
      try {
        $uvod = Receive-Frame $s
        $podaci = $null
        if ($uvod.Tip -eq 0x01) { $podaci = [Text.Encoding]::UTF8.GetString($uvod.Payload) | ConvertFrom-Json }
        if (-not $podaci -or $podaci.secret -ne $Secret) {
          Log "ODBIJEN $ip - pogresna tajna"
          Send-Frame $s 0x02 (Utf8 'NO')
          $klijent.Close(); continue
        }
        Send-Frame $s 0x02 (Utf8 'OK')
        Log "spojen $ip"
        Sync-Loop $klijent $s 'Server'
      } catch {
        Log "veza s $ip prekinuta: $($_.Exception.Message)"
      } finally {
        try { $klijent.Close() } catch { }
      }
    }
  } finally { $lis.Stop() }
}

# ---------------------------------------------------------------------- klijent
function Vrti-Klijenta {
  Say "Most RADI - klijent prema $($kandidati -join ', '):$Port"
  Say ("Drop: $drop   ->   Primljeno: $prim")
  $cekaj = 2
  $i = 0
  while ($true) {
    $adresa = $kandidati[$i % $kandidati.Count]
    $v = $null          # bez ovoga bi neuspjeh ostavio proslu, vec zatvorenu vezu
    try {
      $v = Povezi-Se $adresa
      Log "spojen na ${adresa}:$Port"
      $cekaj = 2
      Sync-Loop $v.Klijent $v.Stream 'Client'
    } catch {
      Log "nema veze na ${adresa}:$Port ($($_.Exception.Message)); novi pokusaj za $cekaj s"
    } finally {
      try { if ($v) { $v.Klijent.Close() } } catch { }
    }
    # Vise kandidata -> svaki krug ide na sljedecu adresu, pa se pogresan
    # gateway preskoci u jednom krugu umjesto zauvijek.
    if ($kandidati.Count -gt 1) { $i++ }
    Start-Sleep -Seconds $cekaj
    if ($cekaj -lt 30) { $cekaj = [Math]::Min(30, $cekaj * 2) }
  }
}

# ------------------------------------------------------------------ sync loop
function Sync-Loop($klijent, $stream, [string]$uloga) {
  $script:Rx    = $null      # datoteka koja se upravo prima
  $script:Grupa = $null      # grupa koja se upravo prima (za meduspremnik)
  $zadnjiDrop = @{}          # sto je iz Drop-a vec poslano (ime|duljina|vrijeme)
  $script:ZadnjiHash = Prezivjeli-Hash (Dohvati-Meduspremnik)
  $script:PreskociDo = [datetime]::MinValue

  Log 'veza uspostavljena - sinkroniziram'

  while ($klijent.Connected) {
    # ---- 1. dolazno
    try {
      $iter = 0
      while ($stream.DataAvailable -and $iter -lt 64) {
        $iter++
        $f = Receive-Frame $stream
        switch ($f.Tip) {
          0x10 {
            $t = [Text.Encoding]::UTF8.GetString($f.Payload)
            if ($t.Length -le $MaxTextBytes) {
              if (Postavi-Tekst $t) {
                $p = if ($t.Length -gt 40) { $t.Substring(0,40) + '...' } else { $t }
                Log ("  <- tekst {0} B  {1}" -f $f.Payload.Length, ($p -replace '\r?\n',' '))
                Zapamti-Trenutni
              }
            }
          }
          0x11 {
            if ($f.Payload.Length -le $MaxImageBytes) {
              if (Postavi-Sliku $f.Payload) {
                Log ("  <- slika {0} B" -f $f.Payload.Length)
                Zapamti-Trenutni
              }
            } else { Log ("  [!] slika prevelika ({0} B)" -f $f.Payload.Length) }
          }
          0x12 {
            $g = [Text.Encoding]::UTF8.GetString($f.Payload) | ConvertFrom-Json
            $script:Grupa = @{ Preostalo = [int]$g.count; Putanje = @() }
            Log ("  <- najava grupe: {0} datoteka, {1} MB" -f $g.count, [math]::Round($g.ukupno/1MB,1))
          }
          0x20 {
            $h = [Text.Encoding]::UTF8.GetString($f.Payload) | ConvertFrom-Json
            $ime = Ocisti-Ime $h.name
            $odred = Slobodno-Ime $prim $ime
            $fs = [System.IO.File]::Open($odred, 'Create', 'Write')
            $script:Rx = @{
              Fs = $fs; Putanja = $odred; Got = 0; Ocekivano = [int64]$h.size
              Grupa = $script:Grupa
              ClipGrupa = ($null -ne $script:Grupa)
            }
            if ($script:Grupa) { $script:Grupa.Putanje += $odred }
          }
          0x21 {
            if (-not $script:Rx) { throw 'komad bez najave datoteke' }
            $script:Rx.Fs.Write($f.Payload, 0, $f.Payload.Length)
            $script:Rx.Got += $f.Payload.Length
          }
          0x22 {
            if ($script:Rx) {
              $rx = $script:Rx
              if ($rx.Grupa) { $rx.Grupa.Preostalo-- }
              Zavrsi-Primanje $rx $stream
            }
          }
          default { Log ("  [!] nepoznat tip okvira {0}" -f $f.Tip) }
        }
      }
    } catch [System.IO.IOException] { }        # istek citanja je normalan
      catch { throw }

    # ---- 2. odlazno: meduspremnik
    if (-not $NoClipboard -and (Get-Date) -gt $script:PreskociDo) {
      $s = Dohvati-Meduspremnik
      $h = Prezivjeli-Hash $s
      if ($h -ne $script:ZadnjiHash -and $h -ne 'N') {
        switch ($s.Vrsta) {
          'text' {
            if ($s.Tekst.Length -le $MaxTextBytes) {
              Send-Frame $stream 0x10 (Utf8 $s.Tekst)
              $p = if ($s.Tekst.Length -gt 40) { $s.Tekst.Substring(0,40) + '...' } else { $s.Tekst }
              Log ("  -> tekst {0} B  {1}" -f ([Text.Encoding]::UTF8.GetByteCount($s.Tekst)), ($p -replace '\r?\n',' '))
              $script:ZadnjiHash = $h
            }
          }
          'image' {
            if ($s.Png.Length -le $MaxImageBytes) {
              Send-Frame $stream 0x11 $s.Png
              Log ("  -> slika {0} B" -f $s.Png.Length)
              $script:ZadnjiHash = $h
            }
          }
          'files' {
            $ukupno = 0
            foreach ($p in $s.Datoteke) { try { $ukupno += (Get-Item -LiteralPath $p -EA Stop).Length } catch { } }
            if ($ukupno -le ($ClipFileMaxMB * 1MB)) {
              $script:ZadnjiHash = $h
              Posalji-Grupu $stream @{ Datoteke = $s.Datoteke; Clip = $true; Premjesti = $false }
              Log ("  -> u meduspremnik poslano {0} datoteka ({1} MB)" -f $s.Datoteke.Count, [math]::Round($ukupno/1MB,1))
            } else {
              Log ("  [!] kopirano {0} MB > {1} MB - preskacem; koristi mapu Drop" -f [math]::Round($ukupno/1MB,1), $ClipFileMaxMB)
              $script:ZadnjiHash = $h
            }
          }
        }
      }
    }

    # ---- 3. odlazno: mapa Drop
    if (-not $NoFiles) {
      try {
        $novi = @(Get-ChildItem -LiteralPath $drop -File -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($fi in $novi) {
          $kljuc = $fi.Name + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
          if ($zadnjiDrop.ContainsKey($kljuc)) { continue }
          $staro = $fi.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddSeconds(-1)
          if (-not $staro) { continue }     # datoteka se jos kopira
          $zadnjiDrop[$kljuc] = $true
          Log ("  -> Drop: {0} ({1} B)" -f $fi.Name, $fi.Length)
          Posalji-Grupu $stream @{ Datoteke = @($fi.FullName); Clip = $false; Premjesti = $true }
        }
      } catch { Log ("  [!] Drop: " + $_.Exception.Message) }
    }

    Start-Sleep -Milliseconds $PollMs
  }
}

switch ($Mode) {
  'Server' { Vrti-Posluzitelj }
  'Client' { Vrti-Klijenta }
}
