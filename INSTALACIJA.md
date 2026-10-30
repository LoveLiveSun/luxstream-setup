# INSTALACIJA — jedan pokretač za cijelu postavu

Cilj: na **bilo kojem** Hyper-V gostu s GPU-P particijom pokreneš jednu stvar i sve se
postavi kako treba — zakrpani Sunshine, Virtual Display Driver, ViGEmBus, konfiguracija,
zakazani zadaci i sve naše prilagodbe.

Provjereno na `GPU-test` dana **2026-08-22**: tri uzastopna prolaza, zadnji bez ijedne
greške i bez ijednog upozorenja.

---

## 1. Kako se pokreće

**Najlakše — jedan klik s mreže:** na novom VM-u otvori `\\server\share` i dvoklikni
**`Luxstream-INSTALIRAJ.cmd`**. Sam traži ovlasti, kopira paket na `C:\Luxstream-setup`
i pokrene instalaciju. Ništa se ne raspakirava ručno.

Paket ostaje na `C:\Luxstream-setup`, pa se instalacija poslije može ponoviti i bez mreže.

Ako paket već imaš lokalno, dvoklikni **`INSTALL.cmd`** u njemu.

To je sve. `INSTALL.cmd` sam traži administratorske ovlasti i pokreće `INSTALL.ps1`.

> `.ps1` se dvoklikom ne pokreće nego otvara u editoru — zato omotač u `.cmd`.

Za uklanjanje svega postoji simetričan `Luxstream-ODINSTALIRAJ.cmd`, kojeg
instalater ostavi u paketu (vidi poglavlje 12).

Ručno, iz **povišenog** PowerShella:

```powershell
powershell -ExecutionPolicy Bypass -File .\INSTALL.ps1
```

### Prekidači

| Prekidač | Što radi |
|---|---|
| `-SamoProvjera` | samo preflight; ništa ne mijenja |
| `-PreskociUac` | ne dira UAC postavku (preskače pitanje iz faze 6) |
| `-PreskociAudio` | ne instalira VB-Audio virtualni kabel |
| `-PrisiliSunshine` | reinstalira Sunshine i kad je verzija ista |
| `-Gpu "ime"` | ime GPU-a za VDD; inače se otkriva samo |

**Idempotentan je.** Svaki korak provjerava zatečeno stanje i preskače ono što je već
napravljeno, pa se smije pokretati koliko god puta. Sparivanje s Moonlight klijentima
(`sunshine_state.json`) se ne dira — provjereno, četiri sparena klijenta preživjela su
tri prolaza.

---

## 2. Što mora biti gotovo PRIJE

Instalater radi u **gostu** i ne može ovo napraviti umjesto tebe:

1. **Na hostu:** GPU-P particija dodijeljena VM-u — `host/gpu-p-setup.ps1`.
2. **U gostu:** NVIDIA driver **kopiran** s hosta u
   `C:\Windows\System32\HostDriverStore\FileRepository\nv_dispi.inf_amd64_*`.
   Kod GPU-P-a se driver ne instalira nego kopira, i mora biti **ista verzija** kao na hostu.
3. Prijavljen si na **konzolnoj** sesiji, ne preko RDP-a.

Sve troje preflight provjerava i, ako što nedostaje, staje prije nego bilo što promijeni.

---

## 3. Faze

| # | Faza | Sadržaj |
|---|---|---|
| 0 | preflight | elevacija, konzolna sesija, GPU-P particija, NVIDIA driver, Hyper-V adapter |
| 0b | ugradnja | kopiranje paketa u `C:\Program Files\Luxstream`, da zadaci ne ovise o tome odakle si pokrenuo |
| 1 | driveri | uvoz potpisnika, VDD, ViGEmBus, VB-Audio |
| 2 | VDD konfiguracija | vezanje na GPU + lista modova, restart drivera, provjera da monitor postoji |
| 3 | Sunshine | instalacija zakrpanog builda + provjera da build doista sadrži zakrpe |
| 4 | Sunshine config | otkrivanje GUID-a VDD displaya iz loga, pisanje `sunshine.conf` |
| 5 | zadaci | `SunshineUser`, `StreamReady`, `RestoreConsoleSession`, `VerifyAfterBoot`, `LuxstreamBridge` |
| 6 | prilagodbe | DPI 100 %, Game Bar, **UIAccess**, **automatska prijava**, UAC |
| 7 | priming i provjera | priming grafike, mjerenje (Hyper-V display **ostaje** aktivan) |

Dnevnik: `C:\Users\Public\luxstream-install.log`.

---

## 4. Zamke ugrađene u instalater

Ovo su stvari koje su nas stvarno koštale vremena. Zapisane su ovdje da se ne ponove.

### Potpisnički certifikat drivera
VDD je potpisan certifikatom **SignPath Foundation**, a ne WHQL-om. Na ovom VM-u je taj
certifikat odavno bio u `TrustedPublisher` (ostatak ručne instalacije), pa se propust
**nije vidio** — na svježem VM-u bi PnP otvorio dijalog „želite li instalirati ovaj
softver", kojeg u tihoj instalaciji nema tko potvrditi. Instalater sada vadi potpisnika
iz `.cat` datoteke i uvozi ga prije `pnputil`-a.

### Hardverski ID se čita iz INF-a, ne piše napamet
Pretpostavio sam da je ViGEmBusov hardverski ID `Root\ViGEmBus`. Nije —
`Nefarius\ViGEmBus\Gen1`. Rezultat: stvoren uređaj-siroče i
`UpdateDriverForPlugAndPlayDevices` = 259 (`ERROR_NO_MORE_ITEMS`). Sada se ID čita iz
`[Standard.NTamd64]` sekcije samog INF-a. INF-ovi su često UTF-16LE, pa `grep` nad njima
ne nalazi ništa — čita se kroz `Get-Content -Raw`.

### Detekcija ViGEma po imenu ne radi
Prijateljsko ime je *Nefarius Virtual Gamepad Emulation Bus* — u njemu **nema** niza
„ViGEm". Provjera po imenu je lažno javljala da uređaja nema. Ide po hardverskom ID-u.

### Verzija MSI-ja preko `msi.dll`, ne preko COM-a
`WindowsInstaller.Installer` COM objekt je isti kod izvršavao ispravno izvan skripte, a
unutar instalatera bacao `DISP_E_TYPEMISMATCH` na `View.Execute`. Prazan `catch {}` je to
sakrio, verzija je ispala prazna, instalater je krenuo reinstalirati **već instaliranu**
verziju, msiexec je to protumačio kao popravak i vratio **1603**. Sada su to izravni
pozivi `msi.dll` (P/Invoke) i nijedan `catch` više nije nijem.

### Nepoznata verzija ne smije značiti „instaliraj"
Popravljena i sama logika: ako se verzija ne može pročitati, a Sunshine već postoji na
disku, instalater ga **ne dira**. Za prisilnu reinstalaciju postoji `-PrisiliSunshine`.

### `.ps1` treba BOM, `sunshine.conf` ga ne smije imati
Windows PowerShell 5.1 čita `.ps1` kao ANSI **osim ako datoteka ima UTF-8 BOM** — bez
njega su se hrvatski znakovi i crtice izobličili u ispisu. Obrnuto vrijedi za
`sunshine.conf`: s BOM-om Sunshine prvi ključ pročita kao `\ufeffcapture` i **tiho ga
ignorira**. Zato instalater piše skripte s BOM-om, a konfiguraciju bez njega.

### Granica broja modova u VDD-u
Pokušaj s **17** rezolucija je slomio driver — prestao je prijavljivati monitor. Ovih
**11** je provjereno stabilno. Ako dodaješ, dodaj **jedan po jedan** i svaki put provjeri
da monitor i dalje postoji. Faza 2 to i provjerava i javi ako je konfiguracija slomila VDD.

### VDD nije uvijek na `ROOT\DISPLAY\0000`
Ako je na VM-u ranije postojao drugi virtualni display (sudovda, Sunshine Virtual
Display), MttVDD završi na `0001`. Traži se po opisu, ne po fiksnom instance ID-u.

### GUID displaya se ne da naći jednostavnim regexom
U Sunshineovu logu između `"device_id"` i `"friendly_name"` stoji **ugniježđeni** `edid`
blok, pa `[^}]*` ne prolazi, a lijeni `.*?` preskoči u sljedeći uređaj i uhvati krivi
GUID. Rješenje je uvjet `(?!"device_id")`, koji brani prelazak u sljedeći zapis.

### Konzolni prozor Sunshinea
`Sunshine.exe` je građen kao **konzolna aplikacija** (PE Subsystem = 3), pa mu Windows sam
stvara konzolni prozor. Ne da se isključiti prekidačem — `Sunshine.exe --help` nudi samo
`--creds`, `--version` i zastavice `-0 -1 -2 -p`.

Dok je Sunshine išao kao servis prozora nije bilo, jer servisi nemaju radnu površinu.
Otkad mora ići kao korisnik, prozor se vidi. Zato ga zadatak `SunshineUser` pali kroz
`wscript.exe` i omotač `scripts\start-sunshine-hidden.vbs`, koji ga stvori sa
`SW_HIDE`. Bez bljeska, jer je `wscript.exe` GUI program.

Izmjereno: isti proces pokrenut normalno ima `MainWindowHandle` različit od nule, kroz
omotač `0`.

I watchdog i faza 7 pale Sunshine kroz **taj isti zadatak**, pa je to jedino mjesto koje
određuje kako se pokreće.

### Sunshine ne smije biti servis
Kao SYSTEM ne može aktivirati `Windows.Graphics.Capture` —
`GraphicsCaptureSession::IsSupported()` baci `std::bad_alloc` (to je C++/WinRT-ov prijevod
`E_OUTOFMEMORY` iz `RoGetActivationFactory`). Zato faza 5 **onemogućuje**
`SunshineService` i registrira zadatak `SunshineUser` koji ga vozi kao korisnika.

### Sunshine: MSI je osnova, zakrpa je zasebna datoteka
U `installers\sunshine\` su **dvije** stvari i obje moraju biti u paketu:

| Datoteka | Što nosi |
|---|---|
| `*.msi` | servis, skripte, `assets\`, firewall pravila, alati |
| `Sunshine.exe` | **naš zakrpani build** — WGC instrumentacija i WGC-only put |

Faza 3 pusti MSI, a zatim `Sunshine.exe` **preslika** preko instaliranoga. Zato MSI
može biti i upstream izdanje: njegov `sunshine.exe` ionako biva zamijenjen. Ime
MSI-ja nije važno — ako nema `Luxstream-Sunshine-patched.msi`, uzima se prvi
`*.msi` u mapi.

Zamjena je sigurna jer je naš build **izravna zamjena**: isti MinGW UCRT64
toolchain, statički link, identična tablica uvoza (samo `api-ms-win-crt-runtime`
i `KERNEL32`). Prije kopiranja proces se zaustavi (inače je datoteka zaključana),
a usporedba po SHA256 čini ponovno pokretanje instalatera bezopasnim.

Redoslijed nije proizvoljan: zamjena ide u fazi 3, dakle **prije** UIAccess faze
(6) — potpis mijenja datoteku, pa se mora primijeniti na konačnu verziju.

`Sunshine.exe` ide u paket **stripan**. To je isti postupak koji Sunshineovo
pakiranje radi samo (`CPACK_STRIP_FILES YES`): 121 MB → ~72 MB, a marker
`wgc: init start`, koji instalater provjerava, ostaje netaknut.

---

## 5. Gdje paket živi

Zadaci pokazuju na skripte **apsolutnom putanjom**. Da ne ovise o tome odakle si pokrenuo
instalaciju, faza 0b prekopira paket u:

```
C:\Program Files\Luxstream\
```

i sve zadatke registrira **odande**. ZIP možeš raspakirati bilo gdje — na Desktop, u
Downloads — i mapu poslije mirno obrisati.

Ne kopira se:

| Što | Zašto |
|---|---|
| _(Moonlight vise nije u paketu)_ | ide na **klijent**, ne na VM — vidi `installers\README.md` za izvor |
| `installers\_stari` | stari upstream instalater, mrtav teret |
| `*.log`, `*.bak-*` | radni ostaci |

Ako instalater pokreneš **iz** `C:\Program Files\Luxstream`, kopiranje se preskače.

Sunshine ostaje gdje ga njegov MSI stavi — `C:\Program Files\Sunshine`.

---

## 6. Identitet klona

Sunshineov identitet prema Moonlightu čine **dvije** stvari:

| Datoteka | Uloga |
|---|---|
| `config\credentials\cacert.pem` + `cakey.pem` | TLS certifikat koji Moonlight **pinga** |
| `config\sunshine_state.json` → `root.uniqueid` | ID koji host oglašava |

Kad se VM kopira, klon nosi **identičan certifikat i identičan uniqueid** kao izvornik.
Moonlight tada vidi dva hosta koji tvrde da su isti stroj.

Instalater to rješava sam. Klon prepoznaje po **BIOS/SMBIOS UUID-u**
(`Win32_ComputerSystemProduct.UUID`), kojeg Hyper-V dodjeljuje po VM-u — kopiranje ga
mijenja, obično pokretanje ne. Pečat `BIOS_UUID|IME_RAČUNALA` čuva se u
`C:\Users\Public\luxstream-identity.txt`.

| Situacija | Što se dogodi |
|---|---|
| prva instalacija | pečat se zapiše, identitet se **ne dira** |
| isti stroj, ponovno pokretanje | ništa |
| **klon** (drugi BIOS UUID) | stari identitet se **skloni**, Sunshine generira novi |
| BIOS UUID nečitljiv | provjera se **preskače** (da se ne obrišu sparivanja lažno) |
| `-NoviIdentitet` | prisilni reset |

Isto provjerava i zadatak `StreamReady`, pa se klon popravi sam **i ako instalater ne
pokreneš** — na prvoj prijavi.

Stari identitet se **ne briše** nego premješta u
`C:\Users\Public\sunshine-identitet-stari-<datum>`, pa je povratan.

Ako klon zadrži i isto ime računala, u Moonlightu se javlja kao `IME-xxxx` (četiri
znaka BIOS UUID-a), da se dva hosta razlikuju. Za ljepše ime preimenuj Windows
računalo i pokreni instalater ponovno.

**Poslije reseta se svi klijenti moraju ponovno spariti** — u Moonlightu makni stari
host i dodaj ga ponovno. Sparivanje ide samo od sebe, bez PIN-a (vidi poglavlje 11).

> Izmjereno 22.8.2026.: ako se `cacert.pem` i `cakey.pem` sklone, Sunshine pri
> pokretanju izgenerira nove — potvrđeno drukčijim otiskom certifikata.
> `sunshine_state.json` se ne stvara odmah nego pri prvoj promjeni, što je isti put
> kao kod svježe instalacije.

---

## 7. UIAccess - da se UAC potvrda može kliknuti preko Moonlighta

Bez ovoga se potvrda **vidi ali se ne može kliknuti**. Dvije su prepreke, i obje treba
maknuti:

| Prepreka | Rješenje |
|---|---|
| Windows prebaci ulazni desktop na `Winlogon`, kojeg WGC ne vidi → slika se zamrzne | `PromptOnSecureDesktop = 0` |
| `consent.exe` radi na razini *System*, Sunshine na *High* → UIPI blokira `SendInput` | UIAccess na Sunshineu |

Podizanje Sunshinea na SYSTEM nije opcija — tada ne može aktivirati WGC.

UIAccess traži tri stvari: **sigurnu lokaciju** (`C:\Program Files\Sunshine`, već imamo),
**`uiAccess="true"`** u manifestu i **Authenticode potpis**. Zadnje dvoje radi
`scripts\uiaccess-sunshine.ps1`, kojeg instalater zove u fazi 6.

Provjera da je stvarno prošlo — manifest na disku nije dovoljan, treba token procesa:

```
proces PID 17988:  UIAccess = 1  (DODIJELJEN)
```

Skripta to ispisuje sama. Povratak: `.\uiaccess-sunshine.ps1 -Vrati`.

**Cijena:** certifikat `CN=Luxstream Code Signing` ide u strojne pouzdane korijene, pa
Windows vjeruje svemu potpisanom tim ključem. Ključ ne napušta VM. Bez potpisa nema
UIAccessa — to se ne da zaobići.

**Zašto potpis nije u buildu:** privatni ključ se ne isporučuje u paketu, pa se potpis
ionako mora raditi na stroju. Zato je i izmjena manifesta ovdje, da sve bude na jednom
mjestu.

---

## 8. Dva načina da VM dobije postavu

Paket mora raditi u oba, i radi.

### a) Svjež VM — pokreneš `INSTALL.cmd`

Sve prolazi redom. Zatraži lozinku za automatsku prijavu (ako račun nema lozinku,
samo pritisni Enter). Sparivanje s Moonlightom ne treba ništa ručno — klijent se
spari sam pri prvom kliku na host (vidi poglavlje 11).

### b) Kopiraš cijeli VM na kojem je paket već instaliran

Instalater se **ne pokreće**. Sve odrađuje zadatak `StreamReady` pri prvoj prijavi:

| Što | Zašto |
|---|---|
| nov TLS certifikat i `uniqueid` | klon nosi identične kao izvornik, pa Moonlight vidi dva hosta koji tvrde da su isti stroj |
| `output_name` se **makne** | to je GUID VDD displaya, specifičan za stroj; na klonu može biti drugi i pokazivati na nepostojeći zaslon |
| `sunshine_name` dobije sufiks | inače klon i izvornik stoje u Moonlightu pod istim imenom |

Klon se prepoznaje po **BIOS/SMBIOS UUID-u**, kojeg Hyper-V dodjeljuje po VM-u.
Stari identitet se ne briše nego premješta u `C:\Users\Public\sunshine-identitet-stari-<datum>`.

**Poslije toga se svi klijenti moraju ponovno spariti.** To je namjerno — bez toga bi dva
stroja dijelila isti identitet.

---

## 9. Automatska prijava — obavezna

Nije udobnost nego uvjet. Cijeli lanac visi o prijavljenoj interaktivnoj sesiji:

- **WGC ne radi kao SYSTEM**, samo u korisničkoj sesiji
- promjene topologije displaya iz sesije 0 **ne diraju** korisnikov desktop
- zadaci `SunshineUser` i `StreamReady` okidaju **pri prijavi**

Bez nje se VM digne do zaslona za prijavu, Moonlight vidi host i ne može se spojiti.

Postavlja je `scripts\postavi-auto-prijavu.ps1`, kojeg instalater zove u fazi 6. Traži
lozinku i sprema je u **LSA tajne** (`LsaStorePrivateData`), ne u registry kao običan
tekst — isto kao Sysinternalsov Autologon. Ako u registryju zatekne `DefaultPassword`
kao tekst, makne ga.

**Račun bez lozinke.** Podržan je. Na pitanje za lozinku pritisni Enter, ili dodaj
`-PraznaLozinka` kad skriptu zoveš iz drugog skripta (nema konzole za pitanje). Tada se
**nikakva LSA tajna ne sprema**; umjesto toga se postojeći `DefaultPassword` **obriše** —
i iz LSA tajni i iz registryja — jer bi Winlogon inače i dalje pokušavao prijavu sa starom
lozinkom. Uz to skripta postavi `LimitBlankPasswordUse = 0`
(`HKLM:\SYSTEM\CurrentControlSet\Control\Lsa`), jer Windows inače **odbija** automatsku
prijavu računa bez lozinke. `-Iskljuci` tu vrijednost vraća na zadanu `1`.

Sigurnosno: račun bez lozinke znači da svatko tko dođe do konzole može ući. Prihvatljivo
je samo na izoliranom VM-u kakav je ovaj.

Provjera bez mijenjanja: `.\postavi-auto-prijavu.ps1 -Provjeri` (ispisuje i trenutni
`LimitBlankPasswordUse`)

---

## 10. Što instalater NE radi

- ne instalira Moonlight na klijent (nije ni u paketu — 42 MB koji na VM ne trebaju)
- ne sparuje klijente — to radi Moonlight sam, bez PIN-a (vidi poglavlje 11)
- ne otvara firewall ručno (Sunshineov MSI to radi sam)
- ne postavlja GPU-P na hostu
- ne kopira NVIDIA driver s hosta

---

## 11. Poslije instalacije

Na klijentu, u Moonlightu:

| Postavka | Vrijednost | Zašto |
|---|---|---|
| Video decoder | **Automatic** | `Force software decoding` diže decode s 1,5 ms na 188 ms |
| Video codec | **HEVC** | `Automatic` bi izabrao AV1 |
| Rezolucija | jedna **iz VDD liste** | ostale se neće primijeniti |

Sparivanje: klikni host u Moonlightu. **Ništa se ne unosi.** U ovoj postavi je
Sunshine zakrpan tako da PIN round-trip odgovara odmah, a Moonlight da šalje isti
fiksni PIN, pa se AES ključ na obje strane poklopi i sparivanje završi samo.
Nema četiri znamenke koje bi prepisivao iz Moonlighta u web sučelje, niti dijaloga
s PIN-om u Moonlightu. Sparivanje je trajno — sljedeći put samo klikneš i spojen si.

> Spari se **samo** s Moonlightom iz ovog paketa. Standardni Moonlight iz trgovine
> traži PIN i ne može se sparity bez ručnog unosa.

**Web sučelje Sunshinea nema prijavu.** Otvori `https://<ip-gosta>:47990` (preglednik
će upozoriti na certifikat — to je očekivano, Sunshine ga sam potpisuje; odaberi
*Advanced* → *Continue*). Nema korisničkog imena ni lozinke, ni prvog postavljanja
računa. Sučelje treba samo za promjenu enkodera ili display postavki i za popis
sparenih klijenata.

> Sigurnosno: svatko tko može doći do porta 47990 uđe bez ikakve provjere. Zato VM
> drži na izoliranoj mreži.

Provjera da je sve preživjelo restart: `C:\Users\Public\boot-verify.txt`, koji zadatak
`VerifyAfterBoot` zapiše 100 s nakon prijave.

---

## 12. Uklanjanje

`UNINSTALL.ps1` je dio paketa i instalater ga ostavi tamo gdje ga možeš naći:

- **Start izbornik → Uninstall Luxstream**, ili
- `C:\Program Files\Luxstream\UNINSTALL.cmd`, ili
- `C:\Program Files\Luxstream\Luxstream-ODINSTALIRAJ.cmd` (isto)

Dvoklik na bilo koje. Zatraži administratorske ovlasti i prođe kroz 11 faza. Dva
`.cmd` imena su namjerna: instalater ima `INSTALL.cmd` uz
`Luxstream-INSTALIRAJ.cmd`, pa deinstalater ima isti par.

**Prvo pogledaj što bi napravio** — ispiše sve, ne mijenja ništa:

```powershell
C:\Program Files\Luxstream\UNINSTALL.cmd -Samoprovjera
```

### Prekidači

| Prekidač | Što radi |
|---|---|
| `-Samoprovjera` | samo popis, nijedna promjena |
| `-Obrisi` | podatke u karanteni briše trajno umjesto da ih premjesti |
| `-ZadrziDrivere` | ne dira VDD, ViGEmBus ni VB-Audio kabel |
| `-ZadrziSunshine` | ne uklanja Sunshine |
| `-ObrisiCertifikate` | uklanja i uvezene potpisnike — vidi upozorenje niže |
| `-Prisili` | bez potvrde |
| `-Tiho` | manje ispisa |

### Redoslijed faza

| # | Faza |
|---|---|
| 1 | pet zakazanih zadataka — **prvo**, prije datoteka i drivera |
| 2 | pokrenuti procesi |
| 3 | podaci mosta (`bridge.json`, `%USERPROFILE%\Luxstream`) |
| 4 | VB-Audio kabel |
| 5 | Sunshine (MSI + `C:\Program Files\Sunshine`) |
| 6–7 | VDD (`mttvdd.inf`) i ViGEmBus (`vigembus.inf`) |
| 8 | uvezeni potpisnici — **samo uz `-ObrisiCertifikate`** |
| 9 | registry: UAC, automatska prijava, GameDVR/Game Bar, DPI |
| 10 | firewall pravilo `Luxstream*`, ako postoji |
| 11 | datoteke, prečac u Start izborniku i sam paket |

Zadaci se odjavljuju **prije** drivera i datoteka. Obrnut redoslijed ne radi:
`StreamReady` i `SunshineUser` okidaju pri prijavi i u međuvremenu **ponovno
podignu Sunshine**, pa se vraća ono što je upravo uklonjeno.

Na kraju je **obavezan restart** — uklonjeni su driveri i vraćena je topologija
displaya.

### Ništa tvoje se ne briše samo od sebe

Podaci mosta i `sunshine.conf` (koji nosi certifikate za sparivanje i `uniqueid`)
se **premjeste** u `C:\Luxstream-uklonjeno-<vrijeme>`, pa se postava može vratiti
bez ponovnog sparivanja svih klijenata. Trajno brisanje je `-Obrisi`.

Potpisnici drivera se **ne diraju** bez `-ObrisiCertifikate`. SignPath Foundation
je **javni** CA — njegovo uklanjanje iz `Root` utječe i na drugi softver potpisan
tim certifikatom.

I deinstalater je idempotentan kao i instalater: na sustavu bez Luxstreama samo
ispiše „nema" za svaki korak.

### Što se ne može vratiti skriptom

| Što | Zašto |
|---|---|
| LSA tajna `DefaultPassword` | skripta je ne može obrisati; bez `AutoAdminLogon = 1` više se ne koristi, ali ostaje u spremištu |
| `C:\Program Files\VB\CABLE` | vlastiti deinstalater VB-Audio ga ne obriše uvijek — ako je kabel došao s Luxstreamom, obriši mapu ručno |
| zapisi u `pnputil` spremištu | uklanjaju se, ali povratak znači ponovnu instalaciju drivera |
