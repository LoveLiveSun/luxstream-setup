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
    na Default Switchu upravo host. Ako ni jedan gateway ne odgovori, klijent
    sam potrazi posluzitelj na lokalnoj mrezi i zapamti ga, pa radi i kad je VM
    prebacen na vanjski preklopnik (vidi Nadji-Hosta):

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

    Velicina datoteke nije ogranicena (granice su 0 = bez granice). Ostalo
    (-NoClipboard, -NoFiles, -PollMs, -ChunkKB, -AllowedClients) ima razumne
    zadane vrijednosti - vidi param blok.

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
        0x20  F_POCETAK  UTF-8 JSON  { name, size, rel? }
                         "rel" ide SAMO za datoteku koja je izasla iz mape -
                         relativna putanja s imenom mape na celu, da se na
                         drugoj strani vrati ista struktura. Bez "rel" datoteka
                         ide ravno u Primljeno\. Stariji sugovornik ga ignorira.
        0x21  F_KOMAD    sirovi bajtovi (komad od ChunkBytes)
        0x22  F_KRAJ     prazno
        0x30  PAUZA      UTF-8 JSON  { name, size }   (suvisno - samo se biljezi)
        0x31  NASTAVI    prazno                       (suvisno - samo se biljezi)

    POPIS sluzi da se nakon cijele grupe primljene datoteke mogu staviti u
    meduspremnik - tako "copy file" u Exploreru na jednoj strani zavrsi kao
    paste datoteke na drugoj, bez ikakvog rucnog koraka.

    ==========================================================================
    KANAL ZA DATOTEKE - zasto Ctrl+V pokrece prijenos (01.11.2026.)
    ==========================================================================
    Prije se prijenos pokretao Ctrl+C-om: cim se kopiranje primijeti, most
    posalje najavu grupe i odmah pocne prenositi bajtove, a meduspremnik na
    drugoj strani postavi TEK kad zadnji bajt sleti. Posljedica se mjerila u
    stvarnim dnevnicima: kod ISO datoteke od 6,5 GB meduspremnik je bio gotov
    3 min 19 s nakon Ctrl+C-a, kod one od 3,3 GB 1 min 33 s, a kod dokumenta od
    0,4 MB u istoj sekundi. Ako korisnik zalijepi PRIJE toga, Explorer zalijepi
    ono sto je u tom trenutku u meduspremniku (stari sadrzaj), a datoteka nikad
    ne zavrsi tamo gdje je htjela. Upravo je to bio "prvi Ctrl+V ne radi".

    Sada meduspremnik ne nosi PUTANJU (CF_HDROP), nego OPISNIK - isto ono sto
    rade RDP i VMware:

        FileGroupDescriptorW   popis: ime, velicina i vrijeme svake datoteke
        FileContents           sadrzaj, po JEDAN po datoteci (bira ga "lindex")
        Preferred DropEffect   1 = COPY

    Time se jednim potezom rjesavaju dva problema:

      1. Cijela grupa ide odjednom. Opisnik nosi SVE datoteke, a Explorer za
         svaku trazi svoj FileContents s rednim brojem. Jedan Ctrl+V zalijepi
         cijelu mapu - prije je to mogla samo zadnja datoteka grupe.
      2. Nema vise praznih datoteka pri lijepljenju na drugi disk. Sadrzaj
         dolazi iz NASE struje, a ne s putanje koju Explorer preuzme, pa
         Explorer nad izvorom ne radi nista (COPY, ne MOVE) i nema trenutka
         u kojem kopira datoteku dok je ova jos prazna.

    Kako ide, korak po korak:

      1. Host prvo posalje SVA zaglavlja grupe (0x20), jedno za drugim, pa tek
         onda sadrzaj. To je promjena i na hostu - bez nje bi se na opisnik
         cekalo dok se ne prenese sve prije zadnje datoteke.
      2. Kad su zaglavlja stigla, ovaj most sastavi opisnik i stavi ga u
         meduspremnik (LuxShim). Zaglavlja dolaze prije sadrzaja, pa je to
         rano - ne ceka se ni jedan bajt.
      3. Datoteke se pune na disk kako komadi (0x21) pristizu. Struja
         (FileContents) ih cita ODAVDE - ako cilj cita brze nego sto veza
         dovodi, struja ceka (vidi LuxShim). Zato se nikad ne dobije krnja
         datoteka, ni kod 6,5 GB.
      4. Kraj je procitan zadnji bajt svake datoteke. Ctrl+V NE salje
         CFSTR_PASTESUCCEEDED (to postoji samo u OLE drag&drop), pa se zna
         drugacije: struja koja vrati 0 B je gotova.
      5. Nakratko zatim kanal se povlaci (OleSetClipboard NULL) i Primljeno\
         se cisti. Cilj je sve vec zapisao na svoje odrediste.

    Zasto se NE flusha (OleFlushClipboard): on u meduspremnik upise samo
    HGLOBAL mediume, a nas sadrzaj je IStream - proxy natrag u ovaj proces.
    Flush bi dakle izgubio upravo ono sto nosimo. Zato meduspremnik drzi
    proxy, a ovaj proces mora biti ziv dok cilj ne procita - i zato se u
    Primljeno\ ne dira dok kanal stoji.

    Zasto IStream, a ne HGLOBAL za sadrzaj: HGLOBAL je JEDAN komad memorije,
    pa bi 10 GB ISO znacilo 10 GB u RAM-u. IStream se cita s diska na zahtjev.
    HGLOBAL se ipak nudi kao rezerva (neki programi traze bas njega), ali se
    isporucuje samo za male datoteke.

    Ako nitko ne zalijepi unutar LazyCekajSec (zadano 10 min), kanal se
    povlaci, a datoteke OSTAJU u Primljeno\ - nista se ne gubi i nista se ne
    brise naslijepo.

    Stariji sugovornik (host koji ne zna da zaglavlja idu prva) salje
    zaglavlje pa odmah sadrzaj te datoteke; most i tada radi, samo se na
    opisnik ceka do kraja prijenosa - ponasanje se svodi na staro, bez greske.
    Okviri 0x30 i 0x31 su sada suvisni (kanal ih ne koristi): primaju se i
    biljeze, a u smjeru slanja se ne salju.

    ==========================================================================
    OGRANICENJA (namjerna)
    ==========================================================================
      * Promet NIJE kriptiran. Zajednicka tajna u HELLO samo sprecava slucajan
        spoj, ne prisluskivanje. Namijenjeno povjerljivom LAN-u.
      * Velicina datoteke NIJE ogranicena - prenosi se i najveca. Prijenos ide
        u komadima i odmah na disk, pa velicina ne odreduje memoriju. Ako ipak
        treba granica, postavi -ClipFileMaxMB / -DropFileMaxMB na >0.
      * Mape SE prenose, rekurzivno. Kopirana mapa ide cijela, sa strukturom
        podmapa. Junkcije (reparse points) se preskacu da se obilazak ne bi
        vrtio u krug. Mapa iz Drop/ se ne razvija - Drop/ prima datoteke.
      * Ponovno kopiranje ISTOG sadrzaja ne salje nista: prepoznaje se po
        popisu putanja kao "nema promjene". Ako je datoteka u meduvremenu
        promijenjena, kopiraj nesto drugo pa opet nju.
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
  # 0 = bez gornje granice (zadano). Datoteka ide u komadima od ChunkKB, a
  # druga strana svaki komad odmah zapisuje na disk - velicina datoteke zato
  # ne odreduje ni potrosnju memorije ni velicinu pojedinog okvira. Ogranicenje
  # velicine je bilo samo politika, ne tehnicka nuznost, pa ga nema. Postavi
  # na >0 (u MB) da ga vratis.
  [int]$ClipFileMaxMB = 0,                        # najveci UKUPNI promet pri copy/paste datoteka
  [int]$DropFileMaxMB = 0,                        # najveca pojedinacna datoteka iz Drop/

  [switch]$NoClipboard,
  [switch]$NoFiles,

  # --- cekanje na lijepljenje (vidi zaglavlje) -------------------------------
  # Zadano je 0: meduspremnik se postavlja za SVAKU grupu iz meduspremnika.
  # Novi kanal nosi opisnik cijele grupe i sve se datoteke postavljaju zajedno,
  # pa bi prag samo znacio da male datoteke zavrse u Primljeno\ i tamo i ostanu.
  # Vrijednost > 0 vraca staro ponasanje: ispod praga se ne ceka.
  [int]$LazyMinMB = 0,
  # Najdulje cekanje na lijepljenje prije nego se odustane. Ovo je ujedno i
  # rok za cijelu grupu, a ne za pojedinu datoteku - pa mora biti velik.
  [int]$LazyCekajSec = 600,
  [switch]$NoLazy,                                # iskljuci cijeli mehanizam

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

# ------------------------------------------------- RDP kanal za datoteke ----
# Zasto ovo postoji, i zasto bas ovako.
#
# Prije ovoga datoteke su isle ovako: primljena datoteka se na disku odmah
# "unaprijed" napuhala na najavljenu velicinu (SetLength), pa se u
# meduspremnik stavila Putanja te datoteke, a Explorer ju je pri Ctrl+V
# PREMJESTIO. Dvije su posljedice bile nepopravljive:
#
#   1. Lijepljenje na DRUGI disk. Explorer "premjestanje" preko granice diska
#      izvede kao kopiraj-pa-obrisi. Kopiranje procita datoteku u trenutku kad
#      je ona jos puna nula, pa na odredistu ostane prazna datoteka - a nas
#      drzac poslije pise u obrisanu datoteku. Prijenos "prodje", rezultat je
#      0 bajtova. (Vidjeno 31.10.2026.)
#
#   2. Grupa s vise datoteka. Meduspremnik se nije smio mijenjati u pola
#      grupe, pa je cekanje na Ctrl+V bilo moguce samo za JEDNU datoteku -
#      onu koja stigne zadnja i to samo ako je veca od LazyMinMB. Ostale
#      datoteke iz grupe zavrsile su u Primljeno\ i nikad nisu zalijepljene.
#
# Rjesenje je isto koje koristi RDP: meduspremnik ne nosi PUTANJE, nego
# OPISNIK cijele grupe (FileGroupDescriptorW) i po jednu STRUJU sadrzaja za
# svaku datoteku (CFSTR_FILECONTENTS). Time:
#
#   * Explorer ne dira nasu datoteku: sadrzaj cita iz nase struje i sam ga
#     stvara na odredistu. Efekt je COPY, pa nema "kopiraj pa obrisi" i nema
#     prazne datoteke ni na drugom disku.
#   * Imena i podmape dolaze iz opisnika, pa se na odredistu dobije tocno
#     ono sto je poslano - neovisno o tome kako se datoteka zove na disku.
#   * CIJELA grupa ide u jednom Ctrl+V-u: jedan opisnik nosi sve datoteke.
#   * Nema vise pogadanja je li korisnik zalijepio: struja se cita dok cilj
#     ne procita zadnji bajt, pa se to tocno vidi.
#
# Cijena, svjesno prihvacena: datoteka se prvo mora primiti na disk (drugacije
# se ne zna njezina velicina, a bez velicine opisnik ne vrijedi). Zato kod
# velikih datoteka Ctrl+V treba stisnuti malo poslije - ali samo jednom, i
# nikad se ne dobije krnja datoteka: struja ceka dok prijenos ne zavrsi.
#
# Sve sto dira OLE (IDataObject, IEnumFORMATETC, IStream, message pump) je u
# ugnijezdjenom C# kodu nize. PowerShell ga samo poziva.
#
# NAPOMENA: meduspremnik se NE flusha. U njemu stoji proxy koji pokazuje
# natrag na nas proces, pa ova nit mora biti ziva dok cilj ne procita - vidi
# LuxClip.Ocisti i izlaz iz Sync-Loop.
$script:LuxTip    = $false
$script:LuxGreska = ''

function Init-LuxClip {
  if ($script:LuxTip) { return $true }
  try {
    Add-Type -TypeDefinition @'
// LuxShim.cs -- RDP-ovski kanal za datoteke u meduspremniku.
//
// Sto se nudi meduspremniku:
//   FileGroupDescriptorW  (CFSTR_FILEDESCRIPTORW)     HGLOBAL - popis datoteka
//   FileContents          (CFSTR_FILECONTENTS)        IStream - sadrzaj po lindexu
//   Preferred DropEffect  (CFSTR_PREFERREDDROPEFFECT) HGLOBAL - 1 = COPY
//
// Zasto opisnik, a ne CF_HDROP: CF_HDROP salje PUTANJE s nase strane, pa ime
// i podmapu odreduje Explorer prema onome sto na disku zatekne. Opisnik salje
// IMENA i VELICINE, a sadrzaj ide kroz nasu struju - pa se na odredistu dobije
// tocno ono sto je poslano (i podmapa iz "rel"), neovisno o tome gdje se
// datoteka stvarno nalazi i kako se zove.
//
// Zasto IStream, a ne HGLOBAL za sadrzaj: HGLOBAL je JEDAN komad memorije, pa
// bi 10 GB ISO znacio 10 GB u RAM-u. IStream se cita s diska na zahtjev, pa
// velicina datoteke ne odreduje potrosnju memorije. HGLOBAL ostaje ponuden kao
// rezerva, jer neki programi traze bas njega.
//
// Zasto vlastita IDataObject, a ne System.Windows.Forms.DataObject: FORMATETC
// nosi i "lindex", a upravo lindex bira KOJU datoteku iz grupe cilj trazi.
// WinForms DataObject lindex uopce ne izlaze, pa se grupa po njemu ne moze
// razluciti. Zato je IDataObject ovdje napisan rucno.
//
// NAPOMENA O ZIVOTU: meduspremnik se NE flusha (nema OleFlushClipboard).
// Umjesto toga u meduspremniku stoji proxy koji pokazuje natrag na nas proces,
// pa nas proces mora biti ziv dok cilj ne procita. To nam odgovara - most je
// ionako stalno pokrenut - ali znaci i da se ova nit NE SMIJE ugasiti dok je
// sto u meduspremniku.

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
using System.Threading;

namespace LuxShim
{
    // ================================================================ Win32
    [StructLayout(LayoutKind.Sequential)]
    internal struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int x;
        public int y;
    }

    internal static class Win
    {
        [DllImport("ole32.dll", ExactSpelling = true)]
        internal static extern int OleInitialize(IntPtr pvReserved);

        [DllImport("ole32.dll", ExactSpelling = true)]
        internal static extern void OleUninitialize();

        [DllImport("ole32.dll", ExactSpelling = true)]
        internal static extern int OleSetClipboard(IntPtr pDataObj);

        [DllImport("ole32.dll", ExactSpelling = true)]
        internal static extern int OleGetClipboard(out IntPtr ppDataObj);

        [DllImport("ole32.dll", CharSet = CharSet.Unicode, EntryPoint = "RegisterClipboardFormatW")]
        internal static extern uint RegisterClipboardFormat(string lpszFormat);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr GlobalAlloc(uint uFlags, UIntPtr dwBytes);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr GlobalLock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern bool GlobalUnlock(IntPtr hMem);

        [DllImport("kernel32.dll", SetLastError = true)]
        internal static extern IntPtr GlobalFree(IntPtr hMem);

        [DllImport("user32.dll", SetLastError = true)]
        internal static extern bool PeekMessageW(out MSG lpMsg, IntPtr hWnd,
            uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);

        [DllImport("user32.dll")]
        internal static extern bool TranslateMessage(ref MSG lpMsg);

        [DllImport("user32.dll")]
        internal static extern IntPtr DispatchMessageW(ref MSG lpMsg);

        internal const uint GMEM_MOVEABLE = 0x0002;
        internal const uint PM_REMOVE    = 0x0001;
    }

    // ============================================================ OLE tipovi
    [StructLayout(LayoutKind.Sequential)]
    public struct FORMATETC
    {
        public short  cfFormat;
        public IntPtr ptd;
        public int    dwAspect;
        public int    lindex;
        public int    tymed;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STGMEDIUM
    {
        public int    tymed;
        public IntPtr unionmember;
        public IntPtr pUnkForRelease;
    }

    // IDataObject je ovdje deklariran rucno, a ne preko
    // System.Runtime.InteropServices.ComTypes.IDataObject, jer ta verzija
    // trazi IEnumADVISE koji u .NET Frameworku nije javan - pa se ta
    // IDataObject uopce ne moze implementirati izvan mscorliba.
    // IID je isti kao pravi, pa ole32 prepoznaje sucelje i marshalling radi.
    [ComImport]
    [Guid("0000010e-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IDataObjectRaw
    {
        [PreserveSig] int QueryGetData(ref FORMATETC pformatetc);
        [PreserveSig] int GetData(ref FORMATETC pformatetcIn, out STGMEDIUM pmedium);
        [PreserveSig] int GetDataHere(ref FORMATETC pformatetc, ref STGMEDIUM pmedium);
        [PreserveSig] int GetCanonicalFormatEtc(ref FORMATETC pformatectIn, out FORMATETC pformatetcOut);
        [PreserveSig] int SetData(ref FORMATETC pformatetc, ref STGMEDIUM pmedium,
                                  [MarshalAs(UnmanagedType.Bool)] bool fRelease);
        [PreserveSig] int EnumFormatEtc(int dwDirection, out IEnumFormatEtcRaw ppenumFormatEtc);
        [PreserveSig] int DAdvise(ref FORMATETC pformatetc, int advf, IntPtr pAdviseSink,
                                  out int pdwConnection);
        [PreserveSig] int DUnadvise(int dwConnection);
        [PreserveSig] int EnumDAdvise(out IntPtr ppenumAdvise);
    }

    [ComImport]
    [Guid("00000103-0000-0000-C000-000000000046")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IEnumFormatEtcRaw
    {
        [PreserveSig] int Next(int celt,
            [Out, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] FORMATETC[] rgelt,
            IntPtr pceltFetched);
        [PreserveSig] int Skip(int celt);
        [PreserveSig] int Reset();
        [PreserveSig] int Clone(out IEnumFormatEtcRaw ppenum);
    }

    internal static class Hr
    {
        internal const int S_OK           = 0;
        internal const int S_FALSE        = 1;
        internal const int E_NOTIMPL      = unchecked((int)0x80004001);
        internal const int E_OUTOFMEMORY  = unchecked((int)0x8007000E);
        internal const int E_INVALIDARG   = unchecked((int)0x80070057);
        internal const int E_UNEXPECTED   = unchecked((int)0x8000FFFF);
        internal const int DV_E_FORMATETC = unchecked((int)0x80040064);
        internal const int DV_E_LINDEX    = unchecked((int)0x80040068);
        internal const int DV_E_TYMED     = unchecked((int)0x80040069);
        internal const int OLE_E_ADVISENOTSUPPORTED = unchecked((int)0x80040003);
    }

    internal static class For
    {
        internal const int DATADIR_GET     = 1;
        internal const int DVASPECT_CONTENT = 1;
        internal const int TYMED_HGLOBAL   = 1;
        internal const int TYMED_ISTREAM   = 4;
        internal const int TYMED_ISTORAGE  = 8;

        // FILEDESCRIPTORW.dwFlags
        internal const uint FD_ATTRIBUTES = 0x00000004;
        internal const uint FD_WRITESTIME = 0x00000020;
        internal const uint FD_FILESIZE   = 0x00000040;
        internal const uint FD_UNICODE    = 0x80000000;

        internal const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;

        // FILEDESCRIPTORW je 592 bajta u Unicode inacici:
        //   dwFlags 4 + clsid 16 + sizel 8 + pointl 8 + dwFileAttributes 4
        //   + 3 x FILETIME 8 + nFileSizeHigh 4 + nFileSizeLow 4
        //   + cFileName 260 WCHAR (520)  =  592
        internal const int FD_SIZE        = 592;
        internal const int FD_NAME_OFFSET = 72;

        internal static short _fgdw = 0;
        internal static short _fc   = 0;
        internal static short _pdde = 0;
        internal static short _pdd  = 0;
        internal static short _psuc = 0;
        private static readonly object _lok = new object();

        // Registracija se kesira: RegisterClipboardFormat vraca isti broj za isto
        // ime, ali svaki poziv je sistemski poziv, a ovdje se ide u petlji.
        internal static void Registriraj()
        {
            lock (_lok)
            {
                if (_fgdw == 0) _fgdw = (short)Win.RegisterClipboardFormat("FileGroupDescriptorW");
                if (_fc   == 0) _fc   = (short)Win.RegisterClipboardFormat("FileContents");
                if (_pdde == 0) _pdde = (short)Win.RegisterClipboardFormat("Preferred DropEffect");
                if (_pdd  == 0) _pdd  = (short)Win.RegisterClipboardFormat("Performed DropEffect");
                if (_psuc == 0) _psuc = (short)Win.RegisterClipboardFormat("Paste Succeeded");
            }
        }
    }

    // ============================================================ jedna stavka
    public class Stavka
    {
        internal string Put;   // gdje datoteka stvarno jest (Primljeno\...)
        internal string Rel;   // ime u meduspremniku, s podmapom: "mapa/sub/x.txt"
        internal long   Vel;
    }

    // ==================================================== IStream nad diskom
    // Cita s diska na zahtjev. Kad zadnji bajt ode, javlja se u LuxClip - to
    // je najbolji moguci signal da je cilj procitao cijelu datoteku, a Explorer
    // pise u odrediste dok cita, pa je to ujedno i "gotovo".
    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public class LuxStream : IStream
    {
        private FileStream _fs;
        private int _indeks;
        private long _vel;
        private bool _javljeno;
        private DateTime _cekanjeOd;

        public LuxStream(string put, int indeks, long vel)
        {
            // FileShare.Delete je OBAVEZAN, i to iz drugog razloga nego prije:
            // ovu struju nitko ne zatvara (OLE ju drzi preko svog proxyja do
            // kraja), pa bi datoteka ostala zakljucana dok ju GC ne pokupi - a
            // most je u meduvremenu zeli obrisati iz Primljeno\. Bez Delete u
            // nacinu dijeljenja Remove-Item pukne na "datoteka je u upotrebi".
            // Brisanje je sigurno: brise se tek kad su sve struje procitane do
            // kraja i prodje predah (vidi Provjeri-Opisnik).
            _fs = new FileStream(put, FileMode.Open, FileAccess.Read,
                                 FileShare.ReadWrite | FileShare.Delete);
            _indeks = indeks;
            _vel = vel;
            _cekanjeOd = DateTime.UtcNow;
        }

        ~LuxStream()
        {
            try { if (_fs != null) _fs.Dispose(); } catch { }
        }

        public void Read(byte[] pv, int cb, IntPtr pcbRead)
        {
            while (true)
            {
                int n = _fs.Read(pv, 0, cb);
                if (n > 0)
                {
                    if (pcbRead != IntPtr.Zero) Marshal.WriteInt32(pcbRead, n);
                    return;
                }

                // Kraj datoteke. Ako je najavljena veca velicina, a prijenos
                // jos traje, ovdje se ceka: cilj (Explorer) cita u istoj petlji
                // dok pise u odrediste, pa se datoteka na odredistu sastavi u
                // jednom potezu i bez ijednog dodatnog Ctrl+V-a. Bez ovoga bi
                // korisnik morao pogoditi trenutak kad je prijenos gotov.
                bool cekaj = !LuxClip.JeGotov(_indeks)
                          && _fs.Length < _vel
                          && !LuxClip.JeKraj()
                          && (DateTime.UtcNow - _cekanjeOd).TotalSeconds < 1800;

                if (cekaj)
                {
                    Thread.Sleep(25);
                    continue;
                }

                if (pcbRead != IntPtr.Zero) Marshal.WriteInt32(pcbRead, 0);
                if (!_javljeno)
                {
                    _javljeno = true;
                    LuxClip.OznaciProcitano(_indeks);
                }
                return;
            }
        }

        public void Write(byte[] pv, int cb, IntPtr pcbWritten)
        {
            if (pcbWritten != IntPtr.Zero) Marshal.WriteInt32(pcbWritten, 0);
        }

        public void Seek(long dlibMove, int dwOrigin, IntPtr plibNewPosition)
        {
            long np = _fs.Seek(dlibMove, (SeekOrigin)dwOrigin);
            if (plibNewPosition != IntPtr.Zero) Marshal.WriteInt64(plibNewPosition, np);
        }

        public void SetSize(long libNewSize) { _fs.SetLength(libNewSize); }

        public void CopyTo(IStream pstm, long cb, IntPtr pcbRead, IntPtr pcbWritten)
        {
            if (pcbRead != IntPtr.Zero) Marshal.WriteInt32(pcbRead, 0);
            if (pcbWritten != IntPtr.Zero) Marshal.WriteInt32(pcbWritten, 0);
        }

        public void Commit(int grfCommitFlags) { }
        public void Revert() { }
        public void LockRegion(long libOffset, long cb, int dwLockType) { }
        public void UnlockRegion(long libOffset, long cb, int dwLockType) { }

        public void Stat(out STATSTG pstatstg, int grfStatFlag)
        {
            pstatstg = new STATSTG();
            pstatstg.type = 2;                       // STGTY_STREAM
            pstatstg.cbSize = _fs.Length;
        }

        public void Clone(out IStream ppstm) { ppstm = null; }
    }

    // ================================================== IEnumFORMATETC rucno
    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public class LuxEnum : IEnumFormatEtcRaw
    {
        private FORMATETC[] _a;
        private int _i;

        public LuxEnum(FORMATETC[] a) { _a = a; _i = 0; }

        public int Next(int celt, FORMATETC[] rgelt, IntPtr pceltFetched)
        {
            int n = 0;
            while (n < celt && _i < _a.Length)
            {
                rgelt[n] = _a[_i];
                n++; _i++;
            }
            if (pceltFetched != IntPtr.Zero) Marshal.WriteInt32(pceltFetched, n);
            return (n == celt) ? Hr.S_OK : Hr.S_FALSE;
        }

        public int Skip(int celt) { _i += celt; return (_i < _a.Length) ? Hr.S_OK : Hr.S_FALSE; }
        public int Reset()        { _i = 0; return Hr.S_OK; }
        public int Clone(out IEnumFormatEtcRaw ppenum) { ppenum = new LuxEnum(_a); return Hr.S_OK; }
    }

    // ========================================================== IDataObject
    [ComVisible(true)]
    [ClassInterface(ClassInterfaceType.None)]
    public class LuxDataObject : IDataObjectRaw
    {
        private Stavka[] _s;
        private FORMATETC[] _svi;

        public LuxDataObject(Stavka[] s)
        {
            _s = s;
            For.Registriraj();
            List<FORMATETC> l = new List<FORMATETC>();

            l.Add(Napravi(For._fgdw, -1, For.TYMED_HGLOBAL));
            for (int i = 0; i < _s.Length; i++)
                l.Add(Napravi(For._fc, i, For.TYMED_ISTREAM | For.TYMED_HGLOBAL));
            l.Add(Napravi(For._pdde, -1, For.TYMED_HGLOBAL));
            _svi = l.ToArray();
        }

        private static FORMATETC Napravi(short fmt, int lindex, int tymed)
        {
            FORMATETC f = new FORMATETC();
            f.cfFormat = fmt;
            f.ptd      = IntPtr.Zero;
            f.dwAspect = For.DVASPECT_CONTENT;
            f.lindex   = lindex;
            f.tymed    = tymed;
            return f;
        }

        // ---------------------------------------------------------- HGLOBAL
        private static IntPtr UGlobal(byte[] podaci)
        {
            IntPtr h = Win.GlobalAlloc(Win.GMEM_MOVEABLE, new UIntPtr((uint)podaci.Length));
            if (h == IntPtr.Zero) return IntPtr.Zero;
            IntPtr p = Win.GlobalLock(h);
            if (p == IntPtr.Zero) { Win.GlobalFree(h); return IntPtr.Zero; }
            Marshal.Copy(podaci, 0, p, podaci.Length);
            Win.GlobalUnlock(h);
            return h;
        }

        // FILEGROUPDESCRIPTORW = UINT cItems + cItems x FILEDESCRIPTORW(592).
        // Pise se rucno, bajt po bajt, jer se na strukturu oslanja Explorer:
        // svaki pomak mora biti tocno tamo gdje Windows ocekuje.
        internal byte[] Opisnik()
        {
            int vel = 4 + _s.Length * For.FD_SIZE;
            byte[] b = new byte[vel];
            BitConverter.GetBytes((uint)_s.Length).CopyTo(b, 0);

            for (int i = 0; i < _s.Length; i++)
            {
                int o = 4 + i * For.FD_SIZE;
                Stavka st = _s[i];

                uint flagovi = For.FD_ATTRIBUTES | For.FD_WRITESTIME
                             | For.FD_FILESIZE | For.FD_UNICODE;
                BitConverter.GetBytes(flagovi).CopyTo(b, o + 0);
                // clsid (16), sizel (8), pointl (8) ostaju nula - i tako treba:
                // dimenzije i CLSID smisla imaju samo za OLE objekte.
                BitConverter.GetBytes(For.FILE_ATTRIBUTE_NORMAL).CopyTo(b, o + 36);
                // ftCreationTime (o+40) i ftLastAccessTime (o+48) ostaju nula,
                // jer FD_CREATETIME / FD_ACCESSTIME nisu postavljeni.
                long ft = DateTime.UtcNow.ToFileTimeUtc();
                BitConverter.GetBytes(ft).CopyTo(b, o + 56);              // ftLastWriteTime
                BitConverter.GetBytes((uint)(st.Vel >> 32)).CopyTo(b, o + 64);
                BitConverter.GetBytes((uint)(st.Vel & 0xFFFFFFFFL)).CopyTo(b, o + 68);

                // cFileName: 260 WCHAR, UTF-16LE, sa zavrsnom nulom. Rel moze
                // nositi podmapu ("mapa/sub/x.txt") - Explorer je tada stvara.
                string ime = st.Rel;
                if (ime.Length > 259) ime = ime.Substring(0, 259);
                byte[] nb = Encoding.Unicode.GetBytes(ime);
                Array.Copy(nb, 0, b, o + For.FD_NAME_OFFSET, Math.Min(nb.Length, 518));
            }
            return b;
        }

        internal byte[] OpisnikZaTestni() { return Opisnik(); }

        private static byte[] Effekt(uint v) { return BitConverter.GetBytes(v); }

        // ---------------------------------------------------------- medium
        private static bool Ima(int tymed, int koji) { return (tymed & koji) != 0; }

        public int QueryGetData(ref FORMATETC f)
        {
            if (f.dwAspect != For.DVASPECT_CONTENT) return Hr.DV_E_FORMATETC;

            if (f.cfFormat == For._fgdw)
            {
                if (f.lindex != -1) return Hr.DV_E_LINDEX;
                return Ima(f.tymed, For.TYMED_HGLOBAL) ? Hr.S_OK : Hr.DV_E_TYMED;
            }
            if (f.cfFormat == For._fc)
            {
                if (f.lindex < 0 || f.lindex >= _s.Length) return Hr.DV_E_LINDEX;
                if (Ima(f.tymed, For.TYMED_ISTREAM) || Ima(f.tymed, For.TYMED_HGLOBAL))
                    return Hr.S_OK;
                return Hr.DV_E_TYMED;
            }
            if (f.cfFormat == For._pdde || f.cfFormat == For._pdd)
            {
                return Ima(f.tymed, For.TYMED_HGLOBAL) ? Hr.S_OK : Hr.DV_E_TYMED;
            }
            // Nepoznato se odbija, a ne prihvaca pa presuti: prihvacanje bez
            // podataka daje cilju praznu datoteku i to bez ijedne greske.
            return Hr.DV_E_FORMATETC;
        }

        public int GetData(ref FORMATETC f, out STGMEDIUM m)
        {
            m = new STGMEDIUM();
            m.pUnkForRelease = IntPtr.Zero;

            int provjera = QueryGetData(ref f);
            if (provjera != Hr.S_OK) return provjera;

            if (f.cfFormat == For._fgdw)
            {
                m.tymed = For.TYMED_HGLOBAL;
                m.unionmember = UGlobal(Opisnik());
                if (m.unionmember == IntPtr.Zero) return Hr.E_OUTOFMEMORY;
                return Hr.S_OK;
            }
            if (f.cfFormat == For._fc)
            {
                Stavka st = _s[f.lindex];
                // HGLOBAL se nudi samo ako ga cilj izricito trazi: to znaci da
                // nema nade da ce citati struju, pa se cijela datoteka ucitava
                // u memoriju. IStream je inace uvijek prvi izbor.
                if (!Ima(f.tymed, For.TYMED_ISTREAM) && Ima(f.tymed, For.TYMED_HGLOBAL))
                {
                    byte[] sadrzaj = File.ReadAllBytes(st.Put);
                    m.tymed = For.TYMED_HGLOBAL;
                    m.unionmember = UGlobal(sadrzaj);
                    if (m.unionmember == IntPtr.Zero) return Hr.E_OUTOFMEMORY;
                    return Hr.S_OK;
                }
                LuxStream ls = new LuxStream(st.Put, f.lindex, st.Vel);
                m.tymed = For.TYMED_ISTREAM;
                m.unionmember = Marshal.GetComInterfaceForObject(ls, typeof(IStream));
                return Hr.S_OK;
            }
            if (f.cfFormat == For._pdde || f.cfFormat == For._pdd)
            {
                m.tymed = For.TYMED_HGLOBAL;
                m.unionmember = UGlobal(Effekt(1));      // 1 = DROPEFFECT_COPY
                if (m.unionmember == IntPtr.Zero) return Hr.E_OUTOFMEMORY;
                return Hr.S_OK;
            }
            return Hr.DV_E_FORMATETC;
        }

        public int GetDataHere(ref FORMATETC f, ref STGMEDIUM m) { return Hr.E_NOTIMPL; }

        public int GetCanonicalFormatEtc(ref FORMATETC fIn, out FORMATETC fOut)
        {
            fOut = fIn;
            fOut.ptd = IntPtr.Zero;
            return Hr.S_FALSE;      // S_FALSE = "nije bilo preusmjeravanja"
        }

        public int SetData(ref FORMATETC f, ref STGMEDIUM m, bool fRelease)
        {
            // Cilj ovdje javlja da je lijepljenje uspjelo - ali to rade samo
            // OLE drag/drop sudionici, ne i Explorer pri Ctrl+V. Ovo je zato
            // samo dodatni signal; glavni je kad struja stigne do kraja.
            if (f.cfFormat == For._psuc) LuxClip.OznaciLijepljenje();
            if (fRelease) RelMedium(ref m);
            return Hr.S_OK;
        }

        internal static void RelMedium(ref STGMEDIUM m)
        {
            if (m.unionmember == IntPtr.Zero) return;
            try
            {
                if (m.tymed == For.TYMED_HGLOBAL) Win.GlobalFree(m.unionmember);
                else if (m.tymed == For.TYMED_ISTREAM) Marshal.Release(m.unionmember);
            }
            catch { }
            m.unionmember = IntPtr.Zero;
        }

        public int EnumFormatEtc(int dwDirection, out IEnumFormatEtcRaw ppenum)
        {
            if (dwDirection != For.DATADIR_GET) { ppenum = null; return Hr.E_NOTIMPL; }
            ppenum = new LuxEnum(_svi);
            return Hr.S_OK;
        }

        public int DAdvise(ref FORMATETC f, int advf, IntPtr sink, out int conn)
        {
            conn = 0;
            return Hr.OLE_E_ADVISENOTSUPPORTED;
        }
        public int DUnadvise(int conn) { return Hr.OLE_E_ADVISENOTSUPPORTED; }
        public int EnumDAdvise(out IntPtr ppenum) { ppenum = IntPtr.Zero; return Hr.OLE_E_ADVISENOTSUPPORTED; }
    }

    // ============================================================== LuxClip
    // PS strana ne dira OLE izravno: sve ide kroz ovu klasu, koja drzi
    // vlastitu STA nit i na njoj vrti pravi message pump. Bez message pumpa
    // proxy s druge strane ne dobije odgovor - a to je upravo tihi neuspjeh
    // koji se ne vidi kao greska, samo kao "Ctrl+V ne radi".
    public static class LuxClip
    {
        private static readonly object _lok = new object();
        private static Thread _nit;
        private static volatile bool _kraj = true;
        private static volatile bool _postavljeno;
        private static volatile string _greska;
        private static Stavka[] _stavke;
        private static int[] _oznaka;
        private static int[] _gotovo;
        private static int _broj;
        private static int _procitano;
        private static volatile bool _lijepljeno;
        private static volatile bool _isteklo;

        // opis: jedan redak po datoteci, polja odvojena TAB-om: put, rel, velicina
        public static string Postavi(string opis, int timeoutSec)
        {
            Ocisti();
            Stavka[] ss = Parsaj(opis);
            if (ss == null || ss.Length == 0) return "nema stavki";

            lock (_lok)
            {
                _stavke = ss;
                _oznaka = new int[ss.Length];
                _gotovo = new int[ss.Length];
                _broj = ss.Length;
                _procitano = 0;
                _lijepljeno = false;
                _isteklo = false;
                _greska = null;
                _postavljeno = false;
                _kraj = false;

                _nit = new Thread(Nit);
                _nit.SetApartmentState(ApartmentState.STA);
                _nit.IsBackground = true;
                _nit.Name = "LuxClip";
                _nit.Start(timeoutSec);
            }

            // Cekanje na potvrdu da je meduspremnik stvarno postavljen. Bez
            // ovoga bi PS odmah javio "spremno", a korisnikov Ctrl+V bi dosao
            // na jos prazan meduspremnik.
            int cek = 0;
            while (cek < 500 && !_postavljeno && !_isteklo && _greska == null)
            {
                Thread.Sleep(10); cek++;
            }
            if (_greska != null) return _greska;
            if (!_postavljeno) return "meduspremnik nije postavljen u roku";
            return "";
        }

        private static Stavka[] Parsaj(string opis)
        {
            if (string.IsNullOrEmpty(opis)) return null;
            List<Stavka> l = new List<Stavka>();
            string[] redci = opis.Split('\n');
            foreach (string r in redci)
            {
                if (r.Length == 0) continue;
                string[] p = r.Split('\t');
                if (p.Length < 3) continue;
                Stavka s = new Stavka();
                s.Put = p[0];
                s.Rel = p[1];
                long v;
                if (!long.TryParse(p[2], out v)) v = 0;
                s.Vel = v;
                l.Add(s);
            }
            return l.ToArray();
        }

        private static void Nit(object stanje)
        {
            int timeoutSec = (int)stanje;
            IntPtr pdo = IntPtr.Zero;
            try
            {
                int hr = Win.OleInitialize(IntPtr.Zero);
                if (hr != Hr.S_OK && hr != Hr.S_FALSE)
                {
                    _greska = "OleInitialize: 0x" + hr.ToString("X8");
                    _isteklo = true;
                    return;
                }

                LuxDataObject doo = new LuxDataObject(_stavke);
                pdo = Marshal.GetComInterfaceForObject(doo, typeof(IDataObjectRaw));
                hr = Win.OleSetClipboard(pdo);
                if (hr != Hr.S_OK)
                {
                    _greska = "OleSetClipboard: 0x" + hr.ToString("X8");
                    _isteklo = true;
                    return;
                }
                _postavljeno = true;

                DateTime krajnji = DateTime.UtcNow.AddSeconds(timeoutSec);
                MSG m;
                while (!_kraj)
                {
                    // PeekMessage + kratki predah, a ne GetMessage: GetMessage
                    // blokira, pa se ni timeout ni Ocisti() ne bi primijetili.
                    while (Win.PeekMessageW(out m, IntPtr.Zero, 0, 0, Win.PM_REMOVE))
                    {
                        Win.TranslateMessage(ref m);
                        Win.DispatchMessageW(ref m);
                    }
                    if (DateTime.UtcNow > krajnji) { _isteklo = true; break; }
                    Thread.Sleep(15);
                }

                // OleSetClipboard(NULL) prazni OLE meduspremnik. Ne smije se
                // zvati OleFlushClipboard: on bi u meduspremnik prepisao samo
                // HGLOBAL formate, a struja (FileContents) bi se izgubila.
                Win.OleSetClipboard(IntPtr.Zero);
            }
            catch (Exception ex)
            {
                _greska = ex.GetType().Name + ": " + ex.Message;
            }
            finally
            {
                if (pdo != IntPtr.Zero) { try { Marshal.Release(pdo); } catch { } }
                try { Win.OleUninitialize(); } catch { }
                _postavljeno = false;
            }
        }

        internal static void OznaciProcitano(int i)
        {
            if (_oznaka == null || i < 0 || i >= _oznaka.Length) return;
            if (Interlocked.Exchange(ref _oznaka[i], 1) == 0)
                Interlocked.Increment(ref _procitano);
        }

        // Javlja da je prijenos te datoteke gotov - od tog trenutka LuxStream
        // vise ne ceka na rast datoteke, nego na pitanje "ima li jos" odgovara
        // "nema". Bez ovoga bi svaka datoteka cija je stvarna velicina manja od
        // najavljene cekala do tvrdog roka.
        public static void OznaciGotovo(int i)
        {
            if (_gotovo == null || i < 0 || i >= _gotovo.Length) return;
            Interlocked.Exchange(ref _gotovo[i], 1);
        }

        // Javlja da je prijenos te datoteke gotov - od tog trenutka LuxStream
        // vise ne ceka na rast datoteke, nego na pitanje "ima li jos" odgovara
        // "nema". Bez ovoga bi svaka datoteka cija je stvarna velicina manja od
        // najavljene cekala do tvrdog roka.
        internal static bool JeGotov(int i)
        {
            if (_gotovo == null || i < 0 || i >= _gotovo.Length) return true;
            return Interlocked.CompareExchange(ref _gotovo[i], 0, 0) != 0;
        }

        internal static bool JeKraj() { return _kraj; }

        internal static void OznaciLijepljenje() { _lijepljeno = true; }

        // 0 = nista ne visi, 1 = postavljeno (nitko nije citao),
        // 2 = cita se, 3 = sve procitano, 4 = greska
        public static int Stanje()
        {
            if (_greska != null) return 4;
            if (_isteklo || !_postavljeno) return 0;
            if (_broj > 0 && _procitano >= _broj) return 3;
            if (_procitano > 0) return 2;
            return 1;
        }

        public static int Procitano()   { return _procitano; }
        public static int Broj()        { return _broj; }
        public static bool Lijepljeno() { return _lijepljeno; }
        public static string Greska()   { return _greska; }

        public static void Ocisti()
        {
            _kraj = true;
            Thread t = _nit;
            if (t != null && t.IsAlive) { try { t.Join(3000); } catch { } }
            _nit = null;
            _postavljeno = false;
        }

        // --- dijagnostika za -SelfTest: opisnik se gradi bez meduspremnika ---
        public static byte[] OpisnikZaTest(string opis)
        {
            Stavka[] ss = Parsaj(opis);
            if (ss == null) return new byte[0];
            LuxDataObject d = new LuxDataObject(ss);
            return d.OpisnikZaTestni();
        }

        public static int FormatEtaBrojZaTest()
        {
            Stavka[] ss = Parsaj("a\tx.txt\t1\n");
            if (ss == null) return 0;
            LuxDataObject d = new LuxDataObject(ss);
            IEnumFormatEtcRaw e;
            if (d.EnumFormatEtc(For.DATADIR_GET, out e) != Hr.S_OK) return 0;
            FORMATETC[] a = new FORMATETC[8];
            IntPtr n = Marshal.AllocHGlobal(4);
            int c = 0;
            try { e.Next(8, a, n); c = Marshal.ReadInt32(n); }
            finally { Marshal.FreeHGlobal(n); }
            return c;
        }

        // Citа jedan HGLOBAL iz GetData i vraca ga kao bajtove - time se u
        // samotestu provjerava da opisnik stvarno izlazi onakav kakav treba.
        public static byte[] MedijZaTest(string opis, int lindex)
        {
            Stavka[] ss = Parsaj(opis);
            if (ss == null) return new byte[0];
            LuxDataObject d = new LuxDataObject(ss);
            FORMATETC f = new FORMATETC();
            f.cfFormat = (lindex < 0) ? For._fgdw : For._fc;
            f.ptd = IntPtr.Zero;
            f.dwAspect = For.DVASPECT_CONTENT;
            f.lindex = (lindex < 0) ? -1 : lindex;
            f.tymed = For.TYMED_HGLOBAL;

            STGMEDIUM m;
            if (d.GetData(ref f, out m) != Hr.S_OK) return new byte[0];
            byte[] r;
            try
            {
                long cb;
                if (lindex < 0)
                {
                    cb = 4 + ss.Length * For.FD_SIZE;
                }
                else
                {
                    cb = ss[lindex].Vel;
                }
                r = new byte[cb];
                IntPtr p = Win.GlobalLock(m.unionmember);
                try { if (p != IntPtr.Zero) Marshal.Copy(p, r, 0, (int)cb); }
                finally { if (p != IntPtr.Zero) Win.GlobalUnlock(m.unionmember); }
            }
            finally { LuxDataObject.RelMedium(ref m); }
            return r;
        }
    }
}
'@ -Language CSharp -ErrorAction Stop
    $script:LuxTip = $true
    return $true
  } catch {
    $script:LuxGreska = $_.Exception.Message
    Log ('  [!] LuxShim se ne moze sastaviti: ' + $script:LuxGreska)
    return $false
  }
}

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
        # Prihvaca se I mapa, ne samo datoteka. Mapa se ne salje kao takva -
        # razvija ju Prosiri-Putove - ali ovdje se odbacivala bez rijeci, pa je
        # kopiranje mape izgledalo kao da se nista nije dogodilo.
        foreach ($p in $popis) { if ($p -and (Test-Path -LiteralPath $p)) { $dat += $p } }
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

# Primljene datoteke se od 01.11.2026. NE stavljaju u meduspremnik preko
# CF_HDROP (SetFileDropList). Ukinuto je jer je nosilo putanju, pa je Explorer
# pri Ctrl+V sam odlucivao ime i odrediste i, kod lijepljenja na drugi disk,
# kopirao datoteku dok je ova jos prazna. Umjesto toga se postavlja OPISNIK
# cijele grupe (vidi Postavi-Opisnik i LuxShim) - imena i velicine dolaze od
# nas, a sadrzaj iz nase struje, pa Explorer nad nasom datotekom ne radi nista.
#
# Ostaje samo citanje (Dohvati-Meduspremnik), jer ono sluzi za DRUGI smjer -
# da se ono sto korisnik kopira ovdje posalje na drugu stranu.

# Nakon sto se meduspremnik POSTAVI iz mreze, mora se zapamtiti sto u njemu
# sada stoji - inace bi ga lokalna anketa vidjela kao "novo" i poslala natrag.
#
# ZA DATOTEKE I TEKST SE NE CITA PONOVNO, nego se hash racuna iz onoga sto je
# upravo poslano (Zapamti-Poznati). Razlog je konkretan, vidjen 31.10.2026.:
# prije je odmah nakon SetDataObject slijedio STA krug Dohvati-Meduspremnik,
# dakle OleGetClipboard() na ISTOJ STA dretvi koja je meduspremnik upravo
# postavila (Invoke-Sta radi na jednoj, ponovno koristenoj dretvi). Kad se to
# izvede u prvih nekoliko milisekundi, Explorerov PRVI Ctrl+V na radnoj
# povrsini ne napravi nista, a DRUGI radi normalno - jer je meduspremnik tada
# vec "sjeo". Kod datoteka i teksta ponovno citanje ionako ne donosi nista:
# sadrzaj je identican onome koji smo poslali, pa je hash deterministicki.
# Kod slike ponovno citanje OSTAJE - vidi Zapamti-Trenutni.
#
# Prozor se drzi duze (3 s, prije 1.5 s): dok on traje, Luxstream NE dira
# meduspremnik, pa korisnikov prvi Ctrl+V sigurno dolazi na miran meduspremnik.
function Zapamti-Poznati($s) {
  $script:ZadnjiHash = Prezivjeli-Hash $s
  $script:PreskociDo = (Get-Date).AddSeconds(3)
}

# Slika: hash se MORA dobiti ponovnim citanjem, jer se PNG pri ponovnom
# kodiranju ne dobije uvijek bajt-identican. Ako citanje vrati 'N' (drugi
# proces je u meduvremenu drzao meduspremnik), NE pamti se 'N' - anketa bi
# nakon isteka prozora nas sadrzaj vidjela kao nov i poslala ga natrag. Tada
# se koristi hash onoga sto je poslano; isti obrazac kao m_AppliedHash u
# luxbridge.cpp na hostu.
function Zapamti-Trenutni([string]$poznati = '') {
  $s = Dohvati-Meduspremnik
  $h = Prezivjeli-Hash $s
  if ($h -eq 'N' -and $poznati) { $h = $poznati }
  $script:ZadnjiHash = $h
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
  $zadnji = Get-Date
  while ($read -lt $n) {
    try {
      $k = $stream.Read($buf, $read, $n - $read)
    } catch [System.IO.IOException] {
      # Istek citanja je NORMALAN dok se ceka pocetak novog okvira, ali NIJE
      # normalan na pola okvira: tip je vec procitan, pa bi se sljedeci bajt
      # uzeo kao novi tip i cijeli bi se tok raslojio. Zato se ovdje ceka
      # dalje - ali ne vjecno, jer bi mrtva veza inace visila zauvijek.
      if (((Get-Date) - $zadnji).TotalSeconds -gt 60) { throw 'veza zastala na pola okvira' }
      continue
    }
    if ($k -le 0) { throw 'veza zatvorena' }
    $read += $k
    $zadnji = Get-Date
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

# Je li veza jos ziva?
#
# $klijent.Connected je samo ZAPAMCENO stanje - kad druga strana posalje FIN,
# .NET ga ne mijenja. I Receive-Frame se poziva samo kad je $stream.DataAvailable
# istinit, a za zatvorenu vezu je on laz. Veza koja je umrla dok se nista nije
# slalo zato se nikad ne primijeti: petlja se vrti u prazno, u log se ne pise
# nista, i klijent ostaje "spojen" na mrtvu uticnicu dok se ne pokusa pisati -
# a to se ne dogodi ako se u meduvremenu ne kopira nista NA TOJ strani. Tocno
# tako je most ostao nijem 40 minuta nakon sto je Moonlight na hostu zatvoren.
#
# Poll(SelectRead) je ono sto se stvarno dogodilo na uticnici: citljiv bez
# ijednog bajta znaci da je druga strana zatvorila vezu (ili ju je resetirala).
function Test-Veza($klijent, $stream) {
  try {
    if (-not $klijent.Connected) { return $false }
    if ($klijent.Client.Poll(0, [System.Net.Sockets.SelectMode]::SelectRead)) {
      return $stream.DataAvailable
    }
    return $true
  } catch { return $false }
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

# Razvija stavke iz meduspremnika (datoteke I MAPE) u parove
# @{ Put = apsolutna putanja; Rel = relativna putanja }.
#
# Za golu datoteku relativna je samo njezino ime. Za mapu se rekurzivno prode
# cijelo stablo, a relativna putanja nosi ime same mape na celu - tako druga
# strana vrati "<mapa>\..." umjesto da se sadrzaj raspe razasut.
#
# Obilazak je rucni, s vlastitim stogom: Get-ChildItem -Recurse prati junkcije
# (reparse points) i na mapi koja ih sadrzi vrti se u krug. Windows ih ima
# posvuda - svaki "Application Data" je jedan.
function Prosiri-Putove([string[]]$stavke) {
  $parovi = New-Object System.Collections.ArrayList
  $videno = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($p in $stavke) {
    $fi = $null
    try { $fi = Get-Item -LiteralPath $p -ErrorAction Stop } catch { continue }
    if (-not $fi.PSIsContainer) {
      if ($videno.Add($fi.Name)) { [void]$parovi.Add(@{ Put = $fi.FullName; Rel = $fi.Name }) }
      continue
    }
    $baza = $fi.Name
    $korijen = $fi.FullName.TrimEnd('\', '/')
    $stog = New-Object System.Collections.Stack
    $stog.Push($korijen)
    while ($stog.Count -gt 0) {
      $dir = [string]$stog.Pop()
      $djeca = @()
      try { $djeca = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction Stop) } catch { continue }
      foreach ($c in $djeca) {
        if ((([int]$c.Attributes) -band ([int][System.IO.FileAttributes]::ReparsePoint)) -ne 0) { continue }
        if ($c.PSIsContainer) { $stog.Push($c.FullName); continue }
        $unutra = $c.FullName.Substring($korijen.Length).TrimStart('\', '/')
        $rel = $baza + '/' + ($unutra -replace '\\', '/')
        if ($videno.Add($rel)) { [void]$parovi.Add(@{ Put = $c.FullName; Rel = $rel }) }
      }
    }
  }
  # Bez trika sa zarezom: polje se pusta da se raspetlja normalno, a pozivatelj
  # ga normalizira s @(...). Zarez bi ovdje polje umotao jos jednom, pa bi
  # .Count bio 1 iako su unutra dva para.
  $parovi.ToArray()
}

# Kamo primljena datoteka ide. Ako zaglavlje nosi "rel" (datoteka je dosla iz
# mape), putanja se gradi ispod Primljeno\, segment po segment, i mape se
# stvaraju usput - tako se vrati ista struktura kakva je poslana. Bez "rel"
# ponasanje je kao prije: ravno u Primljeno\, uz sufiks kod kolizije.
#
# Svaki segment prolazi kroz Ocisti-Ime, pa se "..\..\Windows" ne moze popeti
# izvan Primljeno\.
function Odredi-Odrediste($zag) {
  $rel = [string]$zag.rel
  if ([string]::IsNullOrWhiteSpace($rel)) { return (Slobodno-Ime $prim (Ocisti-Ime $zag.name)) }
  $seg = @()
  foreach ($d in ($rel -replace '\\', '/').Split('/')) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    $seg += (Ocisti-Ime $d)
  }
  if ($seg.Count -eq 0) { return (Slobodno-Ime $prim (Ocisti-Ime $zag.name)) }
  $dir = $prim
  for ($i = 0; $i -lt ($seg.Count - 1); $i++) {
    $dir = Join-Path $dir $seg[$i]
    if (-not (Test-Path -LiteralPath $dir)) {
      $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction SilentlyContinue
    }
  }
  # Ako se mapa ne moze stvoriti (npr. prava pristupa), datoteka ide ravno u
  # Primljeno\ - bolje izgubiti strukturu nego datoteku.
  if (-not (Test-Path -LiteralPath $dir)) { return (Slobodno-Ime $prim (Ocisti-Ime $zag.name)) }
  Slobodno-Ime $dir $seg[-1]
}

# ------------------------------------------------- cekanje na lijepljenje ----
# Sto ovaj odjeljak radi: cijelu grupu primljenih datoteka predaje
# meduspremniku kao OPISNIK (FileGroupDescriptorW) i ceka da ju cilj procita.
# Potpuno objasnjenje je u zaglavlju skripte.
#
# Nema vise citanja putanje iz drzaca (GetFinalPathNameByHandle): Explorer
# datoteku od sada ne premjesta i ne preimenuje - sadrzaj cita iz nase struje,
# pa se u dnevniku vise ne moze (niti treba) pokazati kamo je otisla.



# Otvara odrediste primljene datoteke. Nista se ne najavljuje unaprijed i
# nista se ne napuhava: datoteka se samo pise, svojom stvarnom velicinom.
# Meduspremnik se postavlja tek kad su poznata SVA zaglavlja grupe - vidi
# Postavi-Opisnik.
#
# Drzac se otvara s ReadWrite, a BEZ Delete: Explorer datoteku od sada ne
# premjesta (efekt je COPY), pa nema koga pustiti da ju obrise - a otvoren
# drzac bez Delete je ono sto nas sprecava da ju sami obrisemo na kraju.
function Novi-Prijem([string]$odred, $zag) {
  $velicina = [int64]$zag.size
  $fs = [System.IO.File]::Open($odred, 'Create', 'Write', 'ReadWrite')
  @{
    Fs        = $fs
    Putanja   = $odred
    Got       = 0
    Ocekivano = $velicina
    Indeks    = -1          # popunjava pozivatelj (0x20), vidi Sync-Loop
  }
}

# Postavlja meduspremnik za cijelu grupu - jednim potezom, iz opisnika.
#
# Zove se tek kad su poznata SVA zaglavlja grupe: opisnik mora nositi ime i
# velicinu svake datoteke, pa se prije toga ne moze sastaviti. Host zaglavlja
# salje prva, jedno za drugim, pa je taj trenutak rano - ne ceka se ni jedan
# bajt sadrzaja (vidi zaglavlje skripte).
function Postavi-Opisnik($grupa) {
  if ($NoLazy -or -not $script:LuxTip) { return }
  if (-not $grupa) { return }
  if ($grupa.Ocekivano -le 0) { return }
  if ($grupa.Zaglavlja -lt $grupa.Ocekivano) { return }
  if ($grupa.Opisnik) { return }

  $uk = 0
  foreach ($e in $grupa.Stavke) { $uk += [int64]$e.Vel }
  if ($LazyMinMB -gt 0 -and $uk -lt ($LazyMinMB * 1MB)) { return }

  $redci = @()
  foreach ($e in $grupa.Stavke) {
    $rel = ($e.Rel -replace '\\', '/')
    if ([string]::IsNullOrWhiteSpace($rel)) { $rel = (Split-Path $e.Put -Leaf) }
    $redci += ($e.Put + "`t" + $rel + "`t" + [int64]$e.Vel)
  }
  $opis = ($redci -join "`n")

  $greska = ''
  try { $greska = [LuxShim.LuxClip]::Postavi($opis, $LazyCekajSec) }
  catch { $greska = $_.Exception.Message }

  if ($greska) {
    Log ("  [!] opisnik nije postavljen: " + $greska)
    $script:Grupa = $null
    return
  }

  $grupa.Opisnik = $true
  $grupa.OpisnikOd = Get-Date
  $grupa.SmirenjeOd = $null
  Log ("  <- meduspremnik spreman: {0} datoteka ({1} MB) - Ctrl+V ih lijepi sve odjednom" -f `
         $grupa.Stavke.Count, [math]::Round($uk / 1MB, 1))
}

# Je li grupa zalijepljena, i je li vrijeme da se kanal zatvori i pocisti?
#
# Signal nije vise "putanja je nestala" - Explorer datoteku NE dira, efekt je
# COPY. Gleda se nasa strana kanala: LuxStream javi kad cilj procita zadnji
# bajt svake datoteke, pa Stanje() prijede u 3. Tek tada - i to nakon kratkog
# predaha, da cilj stigne zapisati u odrediste - kanal se zatvara i
# Primljeno\ cisti.
function Provjeri-Opisnik($grupa) {
  if (-not $grupa -or -not $grupa.Opisnik -or -not $script:LuxTip) { return }

  $sada = Get-Date
  $stanje = 0
  $lijepljeno = $false
  try {
    $stanje = [LuxShim.LuxClip]::Stanje()
    $lijepljeno = [LuxShim.LuxClip]::Lijepljeno()
  } catch { }

  if ($stanje -eq 3 -or $lijepljeno) {
    if (-not $grupa.SmirenjeOd) { $grupa.SmirenjeOd = $sada }
    if (($sada - $grupa.SmirenjeOd).TotalSeconds -lt 3) { return }
    $sek = [int]($sada - $grupa.OpisnikOd).TotalSeconds
    Log ("  <- zalijepljeno nakon {0} s ({1} datoteka) - kanal zatvoren" -f $sek, $grupa.Stavke.Count)
    Zatvori-Opisnik $grupa
    return
  }

  # Kanal je zatvoren izvana: istekao je rok u LuxClip-u, sastavljanje je
  # palo, ili je meduspremnik preuzeo netko drugi.
  if ($stanje -eq 0 -or $stanje -eq 4) {
    $g = ''
    try { $g = [LuxShim.LuxClip]::Greska() } catch { }
    $cekalo = [int]($sada - $grupa.OpisnikOd).TotalSeconds
    if ($g) {
      Log ("  [!] kanal: " + $g)
    } else {
      Log ("  [.] nitko nije zalijepio {0} s - opisnik povucen; datoteke ostaju u Primljeno\" -f $cekalo)
    }
    $grupa.Opisnik = $null
    $script:Grupa = $null
  }
}

# Zatvara kanal i brise primljene datoteke ove grupe.
#
# Brise se TEK nakon sto je cilj procitao zadnji bajt (vidi Provjeri-Opisnik),
# pa datoteka nikome vise ne treba. MOVE se namjerno ne koristi: pri
# lijepljenju na drugi disk Explorer bi ga izveo kao kopiraj-pa-obrisi i
# kopirao bi datoteku u trenutku dok je jos prazna ili nedovrsena.
function Zatvori-Opisnik($grupa) {
  if ($script:LuxTip) { try { [LuxShim.LuxClip]::Ocisti() } catch { } }
  Ocisti-Primljeno $grupa
  $grupa.Opisnik = $null
  $script:Grupa = $null
  # Kratki muk nakon zatvaranja: bez njega bi anketa mogla procitati nas
  # vlastiti meduspremnik u trenutku dok se jos rasklapao.
  $script:PreskociDo = (Get-Date).AddSeconds(1.5)
}

# Brise primljene datoteke ove grupe iz Primljeno\, a zatim i mape koje je
# Odredi-Odrediste usput napravio - od najdublje prema plici, i to samo one
# koje su ostale prazne.
function Ocisti-Primljeno($grupa) {
  if (-not $grupa) { return }
  $mape = New-Object 'System.Collections.Generic.HashSet[string]'
  $obrisano = 0
  foreach ($e in $grupa.Stavke) {
    try {
      if (Test-Path -LiteralPath $e.Put) {
        Remove-Item -LiteralPath $e.Put -Force -ErrorAction Stop
        $obrisano++
      }
      $d = Split-Path $e.Put -Parent
      while ($d -and $d.Length -gt $prim.Length -and $d.StartsWith($prim)) {
        [void]$mape.Add($d)
        $d = Split-Path $d -Parent
      }
    } catch {
      Log ("  [!] ne mogu obrisati {0}: {1}" -f (Split-Path $e.Put -Leaf), $_.Exception.Message)
    }
  }
  $ured = @($mape) | Sort-Object Length -Descending
  foreach ($d in $ured) {
    try {
      $ostalo = @(Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)
      if ($ostalo.Count -eq 0) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
    } catch { }
  }
  if ($obrisano -gt 0) { Log ("  [.] pocisceno {0} datoteka iz Primljeno\" -f $obrisano) }
}

# Tekst i slika koji stignu DOK kanal za datoteke stoji.
#
# Meduspremnik u tom trenutku drzi opisnik grupe koju korisnik upravo lijepi.
# Postaviti tekst preko toga znaci pojesti upravo ono sto korisnik lijepi.
# Zato se takav sadrzaj ne odbacuje nego ODGADA - primijeni se odmah nakon sto
# se kanal zatvori. U praksi se ovo ne bi trebalo ni dogoditi: host ne salje
# meduspremnik dok kanal stoji (vidi pollClipboard u luxbridge.cpp). Ovo je
# druga linija obrane, za stariji host koji to ne provjerava.
function Odgodi-Meduspremnik([string]$vrsta, $sadrzaj) {
  $script:Odgoda = @{ Vrsta = $vrsta; Sadrzaj = $sadrzaj }
  Log ("  [.] {0} iz mreze odgodjen dok traje cekanje na lijepljenje" -f $vrsta)
}

function Primijeni-Odgodu {
  if (-not $script:Odgoda) { return }
  $o = $script:Odgoda
  $script:Odgoda = $null
  if ($o.Vrsta -eq 'text') {
    if (Postavi-Tekst $o.Sadrzaj) {
      Log ("  <- (odgodjeni) tekst {0} B" -f ([Text.Encoding]::UTF8.GetByteCount($o.Sadrzaj)))
      Zapamti-Poznati @{ Vrsta = 'text'; Tekst = $o.Sadrzaj }
    }
  } elseif ($o.Vrsta -eq 'image') {
    if (Postavi-Sliku $o.Sadrzaj) {
      Log ("  <- (odgodjena) slika {0} B" -f $o.Sadrzaj.Length)
      Zapamti-Trenutni ('I' + (Hash ([Convert]::ToBase64String($o.Sadrzaj))))
    }
  }
}

# ------------------------------------------------------------ slanje datoteke
function Send-Datoteku($stream, [string]$putanja, [string]$rel = '') {
  $fi = Get-Item -LiteralPath $putanja -ErrorAction Stop
  if ($DropFileMaxMB -gt 0 -and $fi.Length -gt ($DropFileMaxMB * 1MB)) {
    throw ("prevelika ({0} MB > {1} MB)" -f [math]::Round($fi.Length/1MB,1), $DropFileMaxMB)
  }
  # "rel" se salje samo za datoteku koja je izasla iz mape. Stariji sugovornik
  # ga jednostavno ignorira i slozi datoteke ravno - to je staro ponasanje, a
  # ne greska.
  $zag = @{ name = $fi.Name; size = [int64]$fi.Length }
  if ($rel) { $zag.rel = $rel }
  Send-Frame $stream 0x20 (Utf8 (Json-Ukratko $zag))

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

# Izvor izlazne grupe: @{ Stavke = @(@{Put=...;Rel=...}); Clip = $true/$false }
#
# Stavke su VEC razvijene (vidi Prosiri-Putove) - tako se stablo mape obilazi
# samo jednom, a ne i pri racunanju ukupne velicine i pri slanju.
function Posalji-Grupu($stream, $grupa) {
  $stavke = @($grupa.Stavke)
  if ($stavke.Count -eq 0) { return }
  $ukupno = 0
  foreach ($e in $stavke) { try { $ukupno += (Get-Item -LiteralPath $e.Put -EA Stop).Length } catch { } }

  if ($grupa.Clip) {
    Send-Frame $stream 0x12 (Utf8 (Json-Ukratko @{ count = $stavke.Count; ukupno = [int64]$ukupno }))
  }

  $poslano = 0
  foreach ($e in $stavke) {
    try {
      $n = Send-Datoteku $stream $e.Put $e.Rel
      $poslano++
      Log ("  -> datoteka {0}  ({1} B)" -f $e.Rel, $n)
      if ($grupa.Premjesti) {
        $odred = Slobodno-Ime $posl $([System.IO.Path]::GetFileName($e.Put))
        try { Move-Item -LiteralPath $e.Put -Destination $odred -Force -EA Stop } catch { }
      }
    } catch {
      Log ("  [!] {0}: {1}" -f $e.Rel, $_.Exception.Message)
    }
  }
  $grupa.Poslano = $poslano
}

# --------------------------------------------------------- primanje datoteke
#
# Zatvara drzac i javlja kanalu da je ova datoteka gotova - od tog trenutka
# LuxStream vise ne ceka na njezin rast, nego odmah daje kraj struje.
#
# Duljina se NE svodi na broj primljenih bajtova: datoteka nikad nije bila
# napuhana na najavljenu velicinu (vidi Novi-Prijem), pa je na disku tocno
# onolika koliko je bajtova stiglo. Ako je veza pukla prije kraja, datoteka
# ostaje kratka - i to se u dnevniku izricito vidi.
function Zavrsi-Primanje($rx) {
  if (-not $rx) { return }
  try { if ($rx.Fs) { $rx.Fs.Dispose() } } catch { }
  if ($script:LuxTip -and $rx.Indeks -ge 0) {
    try { [LuxShim.LuxClip]::OznaciGotovo($rx.Indeks) } catch { }
  }
  $script:Rx = $null

  $kratko = ''
  if ($rx.Got -lt $rx.Ocekivano) {
    $kratko = ("  [!] primljeno {0} od {1} B - veza je pukla prije kraja" -f $rx.Got, $rx.Ocekivano)
  }
  Log ("  <- datoteka {0}  ({1} B)" -f (Split-Path $rx.Putanja -Leaf), $rx.Got)
  if ($kratko) { Log $kratko }
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

# $MyInvocation.MyCommand.Path je prazan kad se tijelo skripte izvodi iz
# scriptblocka (npr. kod -SelfTest ili kad se skripta posalje kroz vezu i
# pokrene iz stringa). Tada je i $PSCommandPath prazan, pa se putanja skripte
# uopce ne moze izvesti - ostaje $PSScriptRoot ili nista. NAMJERNO se ne
# koristi $MyInvocation.MyCommand.Definition: u scriptblocku to vrati CIJELO
# tijelo skripte, a ne putanju, pa Split-Path pukne na "nelegalnom znaku".
# $skripte treba samo -Install (VBS omotac), a on se uvijek izvodi iz prave
# datoteke - zato je prazan $skripte ovdje bezopasan.
$self = $MyInvocation.MyCommand.Path
if (-not $self) { $self = $PSCommandPath }
$skripte = if ($self) { Split-Path $self -Parent } else { $PSScriptRoot }

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
  if (-not $tajna) { $tajna = '' }

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
  if ($tajna) {
    Say 'Zajednicka tajna - MORA BITI ista na obje strane:'
    Say ('  ' + $tajna)
  } else {
    Say 'Bez zajednicke tajne - provjerava se samo popis dopustenih adresa.'
  }
  if ($Mode -eq 'Server') {
    $sw = Daj-Mrezu
    Say ''
    if ($tajna) { Say "Na drugoj strani pokreni:  -Mode Client -Secret '$tajna'" }
    else        { Say 'Na drugoj strani pokreni:  -Mode Client' }
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
    if ($tajna) { Say "  .\luxstream-bridge.ps1 -Mode Server -Secret '$tajna' -Install" }
    else        { Say '  .\luxstream-bridge.ps1 -Mode Server -Install' }
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

  # Ugnijezdjeni C# (kanal za datoteke) sastavlja se odmah: ako ne prodje,
  # 3b ce to prijaviti kao [FAIL], ali se greska vidi i ovdje, s pravim
  # razlogom - a ne kao niz nerazumljivih "nije pronadjeno".
  Init-LuxClip | Out-Null

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

  # 3b. JEZGRO kanala: opisnik (FileGroupDescriptorW) koji ide meduspremniku.
  #     Cijeli mehanizam stoji na rucno slozenim bajtovima - FILEDESCRIPTOR je
  #     tocno 592 B po datoteci, a Explorer ga cita po fiksnim pomacima. Jedan
  #     pomaknut bajt znaci opisnik koji Windows procita kao smece (ili, gore,
  #     kao ime iz susjedne datoteke). Zato se svaki pomak provjerava izricito.
  #
  #     Ako ovo padne, kanal ne radi: datoteke ostanu u Primljeno\ i korisnik
  #     ih mora premjestiti rucno. Zato se ne prepusta vjeri u dokumentaciju.
  if (-not $script:LuxTip) {
    T 'kanal: LuxShim se sastavio' $false
    Say ('  [!] ' + $script:LuxGreska)
  } else {
    T 'kanal: LuxShim se sastavio' $true

    # Dvije datoteke, namjerno razlicite: prva mala, druga iznad 4 GB - da se
    # vidi da nFileSizeHigh nije uvijek nula (tamo se lomi najlakse).
    $v1 = 1234
    $v2 = [int64]5368709197            # 5 GB + 77 B
    $opisTest = ("C:\x\a.txt`tpocetak/a.txt`t" + $v1 + "`n" +
                 "C:\x\b.txt`tpocetak/pod/b.txt`t" + $v2 + "`n")
    $bz = [LuxShim.LuxClip]::OpisnikZaTest($opisTest)

    T 'opisnik: velicina = 4 + N*592' ($bz.Length -eq (4 + 2 * 592))

    $cItems = [BitConverter]::ToUInt32($bz, 0)
    T 'opisnik: cItems nosi broj datoteka' ($cItems -eq 2)

    # --- prva datoteka (pomaci su ono na cemu sve visi) ---
    $o = 4
    $flags1 = [BitConverter]::ToUInt32($bz, $o + 0)
    T 'opisnik: FD_UNICODE postavljen (ime je UTF-16)' (($flags1 -band 0x80000000) -ne 0)
    T 'opisnik: FD_FILESIZE postavljen'                (($flags1 -band 0x40) -ne 0)
    T 'opisnik: FD_WRITESTIME postavljen'              (($flags1 -band 0x20) -ne 0)

    $attr1 = [BitConverter]::ToUInt32($bz, $o + 36)
    T 'opisnik: atribut FILE_ATTRIBUTE_NORMAL' ($attr1 -eq 0x80)

    $ft1 = [BitConverter]::ToUInt64($bz, $o + 56)
    T 'opisnik: ftLastWriteTime nije nula' ($ft1 -gt 0)

    $lo1 = [BitConverter]::ToUInt32($bz, $o + 68)
    $hi1 = [BitConverter]::ToUInt32($bz, $o + 64)
    T 'opisnik: nFileSizeLow prve'  ($lo1 -eq $v1)
    T 'opisnik: nFileSizeHigh prve' ($hi1 -eq 0)

    $ime1 = [Text.Encoding]::Unicode.GetString($bz, $o + 72, 10)   # "a.txt" = 5 WCHAR
    T 'opisnik: ime prve, UTF-16, s podmapom' ($ime1 -eq 'pocet')

    # --- druga datoteka: 5 GB + 77 B, ime "b.txt" u podmapi ---
    $o = 4 + 592
    $lo2 = [BitConverter]::ToUInt32($bz, $o + 68)
    $hi2 = [BitConverter]::ToUInt32($bz, $o + 64)
    T 'opisnik: nFileSizeLow druge'  ($lo2 -eq 1073741901)
    T 'opisnik: nFileSizeHigh druge (5 GB)' ($hi2 -eq 1)
    $ime2 = [Text.Encoding]::Unicode.GetString($bz, $o + 72, 38)   # "pocetak/pod/b.txt"
    $ime2 = $ime2.Substring(0, $ime2.IndexOf([char]0))
    T 'opisnik: ime druge nosi podmapu' ($ime2 -eq 'pocetak/pod/b.txt')

    # --- isti opisnik mora izaci i kroz GetData (HGLOBAL), ne samo iz ruke ---
    $bg = [LuxShim.LuxClip]::MedijZaTest($opisTest, -1)
    T 'opisnik: GetData daje isti opisnik' (
      ($bg.Length -eq $bz.Length) -and
      ([Convert]::ToBase64String($bg) -eq [Convert]::ToBase64String($bz)))

    # --- koje formate nudimo: fgdw + po jedan filecontents po datoteci + pdde ---
    $nFmt = [LuxShim.LuxClip]::FormatEtaBrojZaTest()
    T 'kanal: nudi 3 formata za jednu datoteku' ($nFmt -eq 3)

    # --- struja: sadrzaj mora izaci citan s diska, u komadima, tocno u cijelosti ---
    $stIzvor = Join-Path $tmp 'struja.bin'
    $stBytes = New-Object byte[] 300000
    (New-Object Random 7).NextBytes($stBytes)
    [System.IO.File]::WriteAllBytes($stIzvor, $stBytes)

    $buf = New-Object byte[] 65536
    $pn  = [Runtime.InteropServices.Marshal]::AllocHGlobal(4)
    $ms  = New-Object System.IO.MemoryStream
    $citanja = 0
    try {
      $ls = New-Object LuxShim.LuxStream -ArgumentList @($stIzvor, 0, [int64]$stBytes.Length)
      while ($citanja -lt 1000) {
        $ls.Read($buf, $buf.Length, $pn)
        $got = [Runtime.InteropServices.Marshal]::ReadInt32($pn)
        if ($got -le 0) { break }
        $ms.Write($buf, 0, $got)
        if ($got -lt $buf.Length) { break }      # zadnji komad
        $citanja++
      }
    } finally {
      [Runtime.InteropServices.Marshal]::FreeHGlobal($pn)
    }
    T 'struja: zadnji Read javlja kraj (0 B)' ($got -le 0)
    T 'struja: procitano u komadima, ne odjednom' ($citanja -ge 4)
    T 'struja: sadrzaj identican izvoru' (
      ([Convert]::ToBase64String($ms.ToArray()) -eq [Convert]::ToBase64String($stBytes)))
    $ms.Dispose()
  }


  # 3c. PAUZA / NASTAVI kroz pravi spoj
  Send-Frame $b 0x30 (Utf8 (Json-Ukratko @{ name = 'x.iso'; size = 123 }))
  $f = Receive-Frame $a
  $fh = if ($f.Tip -eq 0x30) { [Text.Encoding]::UTF8.GetString($f.Payload) | ConvertFrom-Json } else { $null }
  T 'okvir PAUZA nosi ime i velicinu' (($f.Tip -eq 0x30) -and ($fh.name -eq 'x.iso') -and ([int64]$fh.size -eq 123))
  Send-Frame $b 0x31 @()
  $f = Receive-Frame $a
  T 'okvir NASTAVI' ($f.Tip -eq 0x31)

  # 4. imena
  T 'ime bez putanje' ((Ocisti-Ime 'C:\a\b\zlo.txt') -eq 'zlo.txt')
  T 'ime bez zabranjenih znakova' ((Ocisti-Ime 'a<b>c:d.txt') -eq 'a_b_c_d.txt')
  T 'prazno ime se sanira' ((Ocisti-Ime '   ') -eq 'datoteka')
  T 'kolizija dobiva sufiks' ((Split-Path (Slobodno-Ime $script:prim 'test.bin') -Leaf) -eq 'test-1.bin')

  # 5. mape: rekurzivno razvijanje i vracanje strukture
  $mapa = Join-Path $tmp 'Mapa'
  New-Item -ItemType Directory -Path (Join-Path $mapa 'pod') -Force | Out-Null
  Set-Content -Path (Join-Path $mapa 'a.txt') -Value 'a' -Encoding ASCII
  Set-Content -Path (Join-Path $mapa 'pod\b.txt') -Value 'b' -Encoding ASCII

  $par = @(Prosiri-Putove @($mapa))
  $relovi = (@($par | ForEach-Object { $_.Rel }) | Sort-Object) -join ','
  T 'mapa se razvija na sve svoje datoteke' ($par.Count -eq 2)
  T 'relativna putanja nosi ime mape' ($relovi -eq 'Mapa/a.txt,Mapa/pod/b.txt')

  $o1 = Odredi-Odrediste ([pscustomobject]@{ name = 'b.txt'; rel = 'Mapa/pod/b.txt' })
  T 'rel vraca strukturu podmapa' ($o1 -eq (Join-Path $script:prim 'Mapa\pod\b.txt'))
  T 'podmapa je stvorena' (Test-Path -LiteralPath (Join-Path $script:prim 'Mapa\pod'))

  $o2 = Odredi-Odrediste ([pscustomobject]@{ name = 'x.txt' })
  T 'bez rel ide ravno u Primljeno' ($o2 -eq (Join-Path $script:prim 'x.txt'))

  # ".." mora zavrsiti kao obicno ime, a ne kao izlaz iz Primljeno\
  $o3 = Odredi-Odrediste ([pscustomobject]@{ name = 'zlo.txt'; rel = '../../zlo.txt' })
  T 'rel ne moze pobjeci iz Primljeno' ($o3.StartsWith($script:prim, [StringComparison]::OrdinalIgnoreCase))

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
# $PeerAuto znaci: adresa u bridge.json je NAJDENA skeniranjem, a ne upisana
# rukom. Samo se takva smije kasnije zamijeniti - rukom zadanu adresu je netko
# odlucio i ona ostaje, cak i kad trenutacno ne odgovara. Inace bi host koji je
# promijenio adresu (DHCP) bio tiho izgubljen - isti kvar koji ovaj most upravo
# prestaje praviti.
$PeerAuto = $false
if (-not $Peer -and $k) { $Peer = $k.peer; if ($k.peerAuto) { $PeerAuto = $true } }
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
# Zajednicka tajna je NAMJERNO neobavezna. Njome se sprecava samo slucajno
# spajanje; pravi filtar je popis dopustenih adresa. Kad tajne nema, posluzitelj
# prihvaca svaki pozdrav - inace se klijent koji tajnu nikad nije dobio ne moze
# spojiti, a kvar izgleda kao "nista se ne dogadja" na oba stroja.
if ($null -eq $Secret) { $Secret = '' }

# Klijent: koje adrese posluzitelja uopce pokusavati.
#
# Uz -Peer se ne nagada - pokusava se tocno ta jedna. Bez -Peer se uzima zadani
# gateway, a to je na Default Switchu upravo host.
#
# Zasto ih moze biti VISE: stroj s Default Switchom cesto ima i drugu zadanu
# rutu (vanjski LAN). Gateway s najboljom metrikom tada ne mora biti host, pa
# bi se klijent zauvijek kucao na vrata koja nisu nigdje. Zato se pamte svi
# kandidati i pokusavaju po redu - pogresan se preskoci u sljedecem krugu.
#
# Ako ni jedan ne prodje, klijent NE ostaje na tome: potrazi posluzitelj na
# lokalnoj vezi i zapamti ga (vidi Nadji-Hosta). Time prestaje ovisiti o tome
# je li zadani gateway ujedno i host - sto vrijedi na Default Switchu, ali ne i
# kad je VM prebacen na vanjski preklopnik, gdje je gateway pravi router.
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

# ------------------------------------------------------------------- trazenje
# Kad posluzitelj nije ni na jednom zadanom gatewayu, preostaje ga potraziti na
# lokalnoj vezi. To je slucaj koji se lako previdi: VM koji visi na VANJSKOM
# preklopniku ima za zadani gateway pravi router, a ne host - pa klijent bez
# -Peer kuca na vrata za kojima nema nista, i to zauvijek, bez ijedne vidljive
# greske. Oba stroja su na istoj mrezi, samo se ne gadjaju.
#
# Skenira se lokalna /24 svakog IPv4 sucelja. Siri prefiks (/20 i slicno) znaci
# tisuce adresa bez koristi, a posluzitelj ionako mora biti na istom linku.
#
# Uspjeh se NE cita iz toga sto je port otvoren - otvoren port dokazuje samo da
# tamo nesto slusa, ne da je to NAS posluzitelj. Pravo dokazivanje je pozdrav sa
# zajednickom tajnom: racuna se samo onaj koji odgovori 'OK'.
function Nadji-Hosta {
  param([int]$CekajMs = 3000, [int]$Najvise = 1024, [int]$PoSkupini = 128)

  $moje = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
              ForEach-Object { $_.IPAddress })
  if ($moje.Count -eq 0) { return $null }

  $ciljevi = New-Object System.Collections.Generic.List[string]
  foreach ($m in @($moje | ForEach-Object { ($_ -split '\.')[0..2] -join '.' } | Select-Object -Unique)) {
    foreach ($h in 1..254) {
      $a = "$m.$h"
      if ($moje -contains $a) { continue }
      $ciljevi.Add($a)
      if ($ciljevi.Count -ge $Najvise) { break }
    }
    if ($ciljevi.Count -ge $Najvise) { break }
  }
  if ($ciljevi.Count -eq 0) { return $null }

  # U dnevnik, a ne samo na konzolu: most se vrti iz zakazanog zadatka sa
  # skrivenim prozorom, pa je konzola nigdje. Kad se ovo pisalo samo na
  # konzolu, "klijent ne nalazi posluzitelj" nije ostavljalo ni jedan trag.
  Log ("posluzitelj nije na gatewayu - skeniram " + $ciljevi.Count + " adresa na portu $Port")

  for ($poc = 0; $poc -lt $ciljevi.Count; $poc += $PoSkupini) {
    $skupina = @($ciljevi | Select-Object -Skip $poc -First $PoSkupini)

    # Svi spojevi idu ODJEDNOM. Jedan po jedan bi trajao minutama i most bi se
    # u meduvremenu ponasao kao da je mrtav.
    $ceka = New-Object System.Collections.Generic.List[object]
    foreach ($a in $skupina) {
      try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $ceka.Add(@{ A = $a; C = $c; T = $c.BeginConnect($a, $Port, $null, $null) })
      } catch { }
    }

    # Rok je za cijelu skupinu, ali se cekanje vodi PO SPOJU. Prije je skupina
    # dijelila jedan rok, pa je sve sto nije stiglo unutar njega proglaseno
    # mrtvim - a 256 spojeva odjednom ne stigne ni zapoceti u roku. Ziv
    # posluzitelj je tako zavrsio medju "mrtvima": na njemu se vidjela veza
    # koja se odmah zatvori bez ijednog bajta, pa nije bilo ni "ODBIJEN" ni
    # "spojen", a klijent je zakljucio da posluzitelja nema nigdje.
    # Sada se svaki spoj ceka pojedinacno do isteka roka, a stanje se cita iz
    # IsCompleted - pa se prepozna i onaj koji je zavrsio tek nakon isteka.
    $pocetak = Get-Date
    $zivi = New-Object System.Collections.Generic.List[string]
    foreach ($e in $ceka) {
      while (((Get-Date) - $pocetak).TotalMilliseconds -lt $CekajMs) {
        try { if ($e.T.AsyncWaitHandle.WaitOne(40)) { break } } catch { break }
      }
      try { if ($e.T.IsCompleted -and $e.C.Connected) { $zivi.Add($e.A) } } catch { }
    }
    # Mrtve spojeve zatvaram odmah, da se ne skupljaju rukovatelji kroz krugove.
    foreach ($e in $ceka) {
      if ($zivi -notcontains $e.A) { try { $e.C.Close() } catch { } }
    }

    foreach ($a in $zivi) {
      try {
        $v = Povezi-Se $a            # salje pozdrav i trazi 'OK'
        try { $v.Klijent.Close() } catch { }
        Log "nadjen posluzitelj na ${a}:$Port"
        return $a
      } catch { }
    }
    # I probni spojevi zivih se zatvaraju. Bez toga ostane po jedan otvoren
    # u svakom krugu, pa posluzitelj stalno biljezi parove "spojen pa odmah
    # zatvoreno" - sto izgleda kao kvar, a kvar nije.
    foreach ($e in $ceka) {
      if ($zivi -contains $e.A) { try { $e.C.Close() } catch { } }
    }
  }
  return $null
}

# Nadenu adresu treba i zapamtiti, inace bi se skeniranje ponavljalo pri svakom
# pokretanju. Zapis ide u bridge.json: to je jedina konfiguracija koju most
# ionako cita, pa nema drugoga mjesta koje bi trebalo drzati u sinkronizaciji.
# Most se vrti iz zakazanog zadatka s -RunLevel Highest, pa ima pravo pisati
# tamo gdje obican korisnik ne bi imao.
function Zapisi-Peer([string]$adresa) {
  try {
    $staro = Ucitaj-Konf
    if (-not $staro) { return $false }
    $novo = @{}
    foreach ($p in $staro.PSObject.Properties) { $novo[$p.Name] = $p.Value }
    $novo['peer'] = $adresa
    $novo['peerAuto'] = $true        # najdeno skeniranjem, nije upisano rukom
    [IO.File]::WriteAllText($konf, ($novo | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
    return $true
  } catch { return $false }
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
        # Prazna tajna na ovoj strani znaci "ne provjeravaj" - isto kao u
        # LuxBridge::handleFrame na hostu. Popis dopustenih adresa se provjerio
        # prije ovoga i on je pravi filtar.
        if (-not $podaci -or ($Secret -and $podaci.secret -ne $Secret)) {
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
  $promasaja = 0
  $zadnjiSken = [datetime]::MinValue
  while ($true) {
    $adresa = $kandidati[$i % $kandidati.Count]
    $v = $null          # bez ovoga bi neuspjeh ostavio proslu, vec zatvorenu vezu
    try {
      $v = Povezi-Se $adresa
      Log "spojen na ${adresa}:$Port"
      $cekaj = 2
      $promasaja = 0
      Sync-Loop $v.Klijent $v.Stream 'Client'
    } catch {
      Log "nema veze na ${adresa}:$Port ($($_.Exception.Message)); novi pokusaj za $cekaj s"
      $promasaja++
    } finally {
      try { if ($v) { $v.Klijent.Close() } } catch { }
    }
    # Vise kandidata -> svaki krug ide na sljedecu adresu, pa se pogresan
    # gateway preskoci u jednom krugu umjesto zauvijek.
    if ($kandidati.Count -gt 1) { $i++ }

    # Adresa nije zadana rukom (ili je zadana skeniranjem, pa smije biti
    # zamijenjena), a veza ne radi -> posluzitelj je negdje na lokalnoj vezi.
    # Skenira se najvise svakih 15 s, da se trajno lose stanje ne pretvori u
    # trajno skeniranje mreze.
    if ((-not $Peer -or $PeerAuto) -and $promasaja -ge 1 -and ((Get-Date) - $zadnjiSken).TotalSeconds -ge 15) {
      $zadnjiSken = Get-Date
      $nadjen = Nadji-Hosta
      if ($nadjen) {
        $script:Peer = $nadjen
        $script:PeerAuto = $true
        $kandidati = @($nadjen)
        $i = 0
        $cekaj = 2
        if (Zapisi-Peer $nadjen) { Log "adresa posluzitelja zapamcena u $konf" }
        else { Log 'adresu nisam mogao zapamtiti, ali je koristim u ovoj sesiji' }
      }
    }

    Start-Sleep -Seconds $cekaj
    if ($cekaj -lt 30) { $cekaj = [Math]::Min(30, $cekaj * 2) }
  }
}

# ------------------------------------------------------------------ sync loop
# Zatvara sve sto je jedan spoj mogao ostaviti otvoreno: drzac datoteke u
# prijenosu, kanal u meduspremniku i nedovrsenu grupu u Primljeno\.
#
# Redoslijed je vazan: kanal se zatvara PRIJE brisanja. U njemu je proxy na
# ovaj proces, pa bi cilj inace mogao citati datoteku u trenutku dok je
# brisemo.
function Zatvori-Sve {
  if ($script:Rx -and $script:Rx.Fs) { try { $script:Rx.Fs.Dispose() } catch { } }
  $script:Rx = $null
  if ($script:LuxTip) { try { [LuxShim.LuxClip]::Ocisti() } catch { } }
  if ($script:Grupa) {
    Ocisti-Primljeno $script:Grupa
    $script:Grupa = $null
  }
}

function Sync-Loop($klijent, $stream, [string]$uloga) {
  # Ostatak iz PROSLOG spoja. Ako je veza pukla usred prijenosa, drzac je
  # ostao otvoren, kanal postavljen, a grupa nedovrsena - pa bi se na svakom
  # prekidu izgubio jedan drzac, a u Primljeno\ ostala datoteka koju nitko ne
  # moze zalijepiti (kanal je vec mrtav).
  $biloGrupe = [bool]$script:Grupa
  Zatvori-Sve
  if ($biloGrupe) { Log '  [!] prethodna grupa nije dovrsena - pocisceno iz Primljeno\' }

  $script:Odgoda = $null     # tekst/slika koji cekaju kraj pauze (vidi Odgodi-Meduspremnik)
  $zadnjiDrop = @{}          # sto je iz Drop-a vec poslano (ime|duljina|vrijeme)
  $script:ZadnjiHash = Prezivjeli-Hash (Dohvati-Meduspremnik)
  $script:PreskociDo = [datetime]::MinValue

  Log 'veza uspostavljena - sinkroniziram'

  try {
  while ($klijent.Connected) {
    # Mrtva veza se mora primijetiti i kad se nista ne salje. Bez ovoga bi
    # klijent ostao u petlji nad zatvorenom uticnicom - vidi Test-Veza.
    if (-not (Test-Veza $klijent $stream)) { throw 'veza zatvorena' }

    # ---- 0. meduspremnik: je li grupa zalijepljena?
    #
    # Provjera ide prije dolaznog prometa. Dok opisnik stoji, posiljatelj
    # ionako salje punom brzinom, pa nema sto cekati - a sto se prije primijeti
    # kraj citanja, to se prije kanal zatvori i Primljeno\ pocisti.
    if ($script:Grupa -and $script:Grupa.Opisnik) {
      Provjeri-Opisnik $script:Grupa
    }
    # Odgodjeni tekst/slika se primjenjuju cim kanal vise nije zauzet. Provjera
    # ide svaki okretaj, a funkcija odmah izlazi kad nema nista odgodjeno.
    if (-not ($script:Grupa -and $script:Grupa.Opisnik)) { Primijeni-Odgodu }

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
              # Dok opisnik stoji, meduspremnik drzi datoteke koje korisnik
              # upravo lijepi - tekst preko toga pojede upravo njih.
              if ($script:Grupa -and $script:Grupa.Opisnik) {
                Odgodi-Meduspremnik 'text' $t
              } elseif (Postavi-Tekst $t) {
                $p = if ($t.Length -gt 40) { $t.Substring(0,40) + '...' } else { $t }
                Log ("  <- tekst {0} B  {1}" -f $f.Payload.Length, ($p -replace '\r?\n',' '))
                Zapamti-Poznati @{ Vrsta = 'text'; Tekst = $t }
              }
            }
          }
          0x11 {
            if ($f.Payload.Length -le $MaxImageBytes) {
              if ($script:Grupa -and $script:Grupa.Opisnik) {
                Odgodi-Meduspremnik 'image' $f.Payload
              } elseif (Postavi-Sliku $f.Payload) {
                Log ("  <- slika {0} B" -f $f.Payload.Length)
                # Slika zadrzava ponovno citanje, ali uz poznati hash kao
                # rezervu ako citanje vrati 'N' - vidi Zapamti-Trenutni.
                Zapamti-Trenutni ('I' + (Hash ([Convert]::ToBase64String($f.Payload))))
              }
            } else { Log ("  [!] slika prevelika ({0} B)" -f $f.Payload.Length) }
          }
          0x12 {
            $g = [Text.Encoding]::UTF8.GetString($f.Payload) | ConvertFrom-Json
            # Grupa se pamti u cjelini: opisnik mora nositi ime i velicinu SVAKE
            # datoteke, pa se popis stavki gradi dok zaglavlja pristizu, a
            # meduspremnik se postavlja tek kad ih stigne tocno "count" - vidi
            # Postavi-Opisnik. "Preostalo" je ukinuto: ono je brojalo komade
            # sadrzaja, a kanal sada radi iz zaglavlja, ne iz komada.
            $script:Grupa = @{
              Stavke     = @()      # @{ Ime; Put; Vel; Rel } - jedna po datoteci
              Slovar     = @{}      # ime -> indeks u Stavke (za uklanjanje dvojnika)
              Zaglavlja  = 0        # koliko je okvira 0x20 stiglo
              Ocekivano  = [int]$g.count
              Opisnik    = $null    # $true kad je meduspremnik postavljen
              OpisnikOd  = $null    # kad je postavljen (za rok i dnevnik)
              SmirenjeOd = $null    # kad je cilj poceo citati (predah prije zatvaranja)
              Ukupno     = [int64]$g.ukupno
            }
            Log ("  <- najava grupe: {0} datoteka, {1} MB" -f $g.count, [math]::Round($g.ukupno/1MB,1))
          }
          0x20 {
            $h = [Text.Encoding]::UTF8.GetString($f.Payload) | ConvertFrom-Json
            $odred = Odredi-Odrediste $h
            # Nista se ne najavljuje unaprijed i nista se ne napuhava: datoteka
            # se pise svojom stvarnom velicinom (vidi Novi-Prijem). Meduspremnik
            # se postavlja tek kad su poznata SVA zaglavlja - vidi Postavi-Opisnik.
            $script:Rx = Novi-Prijem $odred $h
            $rx = $script:Rx

            # Grupa postoji samo ako je najava (0x12) stigla prije zaglavlja.
            # Ako nije - ovo je samostalna datoteka; i za nju se pravi grupa od
            # jednog clana, da prodje kroz isti kanal (i da se poslije pocisti).
            if (-not $script:Grupa) {
              $script:Grupa = @{
                Stavke     = @()
                Slovar     = @{}
                Zaglavlja  = 0
                Ocekivano  = 1
                Opisnik    = $null
                OpisnikOd  = $null
                SmirenjeOd = $null
                Ukupno     = [int64]$h.size
              }
            }
            $grupa = $script:Grupa

            # Kljuc za uklanjanje dvojnika je IME, a ne "rel": kod mape se
            # njezin naziv ponavlja u "rel" svake datoteke, pa bi kao kljuc
            # spojio razlicite datoteke iste mape.
            $ime = [string]$h.name
            if (-not $grupa.Slovar.ContainsKey($ime)) {
              $relKljuc = ([string]$h.rel -replace '\\', '/')
              if ([string]::IsNullOrWhiteSpace($relKljuc)) { $relKljuc = (Ocisti-Ime $ime) }
              $grupa.Slovar[$ime] = $grupa.Stavke.Count
              $grupa.Stavke = @($grupa.Stavke) + @{ Ime = $ime; Put = $odred; Vel = [int64]$h.size; Rel = $relKljuc }
            }
            # lindex u opisniku je redni broj stavke; LuxStream po njemu zna
            # koju datoteku cita - vidi LuxShim.
            $rx.Indeks = $grupa.Slovar[$ime]

            # Zaglavlja se broje odvojeno od Stavke: dvojnik imena ne smije
            # blokirati sastavljanje opisnika (Stavke ne bi rasla, a Zaglavlja
            # bi - pa se broji ono sto je stvarno stiglo).
            $grupa.Zaglavlja = $grupa.Zaglavlja + 1

            # Ako je ovo zadnje zaglavlje grupe, kanal se otvara odmah - ne
            # ceka se ni jedan bajt sadrzaja.
            Postavi-Opisnik $grupa
          }
          0x21 {
            if (-not $script:Rx) { throw 'komad bez najave datoteke' }
            $script:Rx.Fs.Write($f.Payload, 0, $f.Payload.Length)
            $script:Rx.Got += $f.Payload.Length
          }
          0x22 {
            if ($script:Rx) {
              # Zavrsi-Primanje zatvara drzac i javlja kanalu da je ova datoteka
              # gotova - od tog trenutka njezina struja daje kraj (vidi LuxShim).
              # Grupa se NE umanjuje: kanal se drzi dok cilj ne procita sve.
              Zavrsi-Primanje $script:Rx
            }
          }
          0x30 {
            # PAUZA koju je poslao sugovornik - a ovaj most je ovdje POSILJATELJ.
            # Cekanje je dogovoreno za onu stranu koja prima datoteku, pa se ovdje
            # nema sto zaustavljati: nas prijenos u tom trenutku uopce ne traje
            # (jedna veza, jedan prijenos u jednom smjeru). Zapisuje se da se u
            # dnevniku vidi tko je trazio pauzu.
            Log ("  [.] sugovornik je trazio pauzu - ne saljem dok ne kaze NASTAVI")
          }
          0x31 {
            Log ("  [.] sugovornik je rekao NASTAVI")
          }
          default { Log ("  [!] nepoznat tip okvira {0}" -f $f.Tip) }
        }
      }
    } catch [System.IO.IOException] { }        # istek citanja je normalan
      catch { throw }

    # ---- 2. odlazno: meduspremnik
    #
    # Dok opisnik stoji, meduspremnik je ZAUZET: u njemu su datoteke koje
    # korisnik upravo lijepi, a citaju se iz ovog procesa (proxy na nasu
    # struju). Poslati u tom trenutku bilo sto iz naseg meduspremnika znacilo
    # bi pregaziti upravo taj opisnik - i korisnikovo lijepljenje bi puklo.
    # Hash se zato ne trosi: sve sto je korisnik kopirao za vrijeme dok kanal
    # stoji ide van odmah nakon sto se kanal zatvori.
    if (-not $NoClipboard -and (Get-Date) -gt $script:PreskociDo -and
        -not ($script:Grupa -and $script:Grupa.Opisnik)) {
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
            # Mape se razvijaju OVDJE, jednom - Posalji-Grupu dobiva gotove
            # stavke, pa se stablo ne obilazi i pri racunanju velicine.
            $stavke = @(Prosiri-Putove $s.Datoteke)
            $ukupno = 0
            foreach ($e in $stavke) { try { $ukupno += (Get-Item -LiteralPath $e.Put -EA Stop).Length } catch { } }
            if ($ClipFileMaxMB -le 0 -or $ukupno -le ($ClipFileMaxMB * 1MB)) {
              $script:ZadnjiHash = $h
              Posalji-Grupu $stream @{ Stavke = $stavke; Clip = $true; Premjesti = $false }
              Log ("  -> u meduspremnik poslano {0} datoteka ({1} MB)" -f $stavke.Count, [math]::Round($ukupno/1MB,1))
            } else {
              Log ("  [!] kopirano {0} MB > {1} MB - preskacem; koristi mapu Drop" -f [math]::Round($ukupno/1MB,1), $ClipFileMaxMB)
              $script:ZadnjiHash = $h
            }
          }
        }
      }
    }

    # ---- 3. odlazno: mapa Drop
    #
    # Dok je grupa u tijeku (zaglavlja pristizu ili opisnik stoji) ne salje se
    # nista iz Drop-a: jedan spoj nosi jedan prijenos, pa bi umijesani okviri
    # pokvarili i primanje i slanje.
    if (-not $NoFiles -and -not $script:Grupa) {
      try {
        $novi = @(Get-ChildItem -LiteralPath $drop -File -ErrorAction SilentlyContinue | Sort-Object Name)
        foreach ($fi in $novi) {
          $kljuc = $fi.Name + '|' + $fi.Length + '|' + $fi.LastWriteTimeUtc.Ticks
          if ($zadnjiDrop.ContainsKey($kljuc)) { continue }
          $staro = $fi.LastWriteTimeUtc -lt (Get-Date).ToUniversalTime().AddSeconds(-1)
          if (-not $staro) { continue }     # datoteka se jos kopira
          $zadnjiDrop[$kljuc] = $true
          Log ("  -> Drop: {0} ({1} B)" -f $fi.Name, $fi.Length)
          Posalji-Grupu $stream @{ Stavke = @(@{ Put = $fi.FullName; Rel = $fi.Name }); Clip = $false; Premjesti = $true }
        }
      } catch { Log ("  [!] Drop: " + $_.Exception.Message) }
    }

    Start-Sleep -Milliseconds $PollMs
  }

  # Veza je pukla (ili se gasimo) - sve sto je ostalo otvoreno zatvara se
  # ovdje, pa sljedeci spoj pocinje cist.
  } finally {
    $biloGrupe = [bool]$script:Grupa
    Zatvori-Sve
    if ($biloGrupe) { Log '  [.] veza prekinuta usred grupe - pocisceno iz Primljeno\' }
  }
}

switch ($Mode) {
  # Ugnijezdjeni C# se sastavlja prije prve veze, a ne u njoj: sastavljanje
  # zna potrajati, a u Sync-Loopu bi taj zastoj izgledao kao mrtva veza.
  # Ako sastavljanje padne, Init-LuxClip to zapise u dnevnik, a most i dalje
  # radi - samo bez kanala (datoteke ostanu u Primljeno\).
  'Server' { Init-LuxClip | Out-Null; Vrti-Posluzitelj }
  'Client' { Init-LuxClip | Out-Null; Vrti-Klijenta }
}
