# Sunshine + Moonlight na Hyper-V gostu s GPU-P particijom

> **Postavljaš novi VM? Ne čitaj ovo — pokreni `INSTALL.cmd`.**
> Jedan pokretač postavlja sve: zakrpani Sunshine, VDD, ViGEmBus, konfiguraciju, zadatke
> i prilagodbe. Upute i ugrađene zamke: **[INSTALACIJA.md](INSTALACIJA.md)**.
> Ovaj dokument objašnjava *zašto* je postava takva kakva jest.

> **Grafika (OpenGL, Vulkan, Direct3D) ima zaseban dokument: [GRAFIKA.md](GRAFIKA.md).**
> Ondje je sve o Mesi, Dozenu, izmjerenim granicama i postavljanju po aplikaciji.

Kompletan postupak za postavljanje udaljenog rada (CAD/BIM) na Windows VM-u koji GPU dobiva
preko **GPU paravirtualizacije (GPU-P)**, uključujući zaobilazak ograničenja koje inače
onemogućuje streaming.

Provjereno i u radu na dan **2026-08-20**.

---

## 1. Sažetak — pročitaj ovo prvo

**Glavni nalaz:** paravirtualni GPU-P adapter **ne implementira Desktop Duplication API**.
Sunshine je tim API-jem hvatao sliku, pa je na GPU-P gostu padao s
`DuplicateOutput() test failed [0x80070057]` (`E_INVALIDARG`). Nikakva promjena topologije,
broja monitora ni primarnog displaya to ne mijenja.

**Rješenje: vlastita zakrpa Sunshinea.** Sunshine već ima kompletan
Windows.Graphics.Capture backend, ali svaki izlaz filtrira kroz Desktop Duplication probu
prije nego WGC uopće dobije priliku. Zakrpa tu probu preskače uz eksplicitni `capture = wgc`.

WGC ne ide preko display drivera nego preko DWM-a, pa hvata i ono što DDA ne može.
Izmjereno na istom izlazu u istom trenutku:

```
IDXGIOutput1::DuplicateOutput()          -> 0x80070057
GraphicsCaptureItem CreateForMonitor()   -> S_OK, kadrovi teku
```

Fork: `VjekoslavDugec/Sunshine-wgc`. Postupak je u **[FORK.md](FORK.md)**.

**Podjela poslova u konačnom rješenju:**

| Sloj | Gdje se izvršava |
|---|---|
| Renderiranje aplikacija (CAD, igre) | **NVIDIA RTX 4090** preko GPU-P particije |
| Vulkan / OpenGL / Direct3D | **izvorni NVIDIA driver** |
| Hvatanje slike | **WGC** na NVIDIA displayu |
| Enkodiranje streama | **NVENC**, hardverski |

**Prethodna arhitektura je napuštena.** VDD se više ne veže na WARP nego na
`NVIDIA GeForce RTX 4090`, a enkodiranje više ne ide na CPU. Stara verzija ovog
dokumenta je u `README.md.zastarjelo` (lokalna arhiva koja nije u repozitoriju).

Trenutna radna postava s točnim postavkama oba kraja: **[RADNA-POSTAVA.md](RADNA-POSTAVA.md)**.
Grafika: **[GRAFIKA.md](GRAFIKA.md)**. Otvorene stavke: **[TODO.md](TODO.md)**.

---

## 2. Okruženje u kojem je ovo provjereno

| | |
|---|---|
| Host | Windows 10 Enterprise LTSC 2021, Hyper-V uloga, NVIDIA RTX 4090 |
| Gost | Windows 10 Enterprise LTSC 2021, build 19044 UBR 7663 |
| Gost CPU / RAM | 12 logičkih jezgri, 24 GB (statički, **bez** Dynamic Memory) |
| GPU u gostu | RTX 4090 preko GPU-P, 24138 MiB, driver `32.0.15.9159` |
| Virtual Display Driver | MikeTheTech VDD `11.30.4.434` |
| Sunshine | `2026.516.143833` (LizardByte) |

---

## 3. Preduvjeti na hostu

GPU-P particija mora postojati i biti zdrava. Naredbe su u
[`host/gpu-p-setup.ps1`](host/gpu-p-setup.ps1).

Ključna ograničenja koja Hyper-V nameće GPU-P VM-ovima:

| Postavka | Vrijednost | Zašto |
|---|---|---|
| `DynamicMemoryEnabled` | `$false` | Hyper-V odbija startati VM s GPU particijom uz dinamičku memoriju |
| `AutomaticStopAction` | `TurnOff` | `Save` nije podržan uz GPU particiju |
| `CheckpointType` | `Disabled` | Checkpointi nisu podržani i tiho razbijaju postavu |
| `LowMemoryMappedIoSpace` | ≥ 1 GB | |
| `HighMemoryMappedIoSpace` | ≥ 32 GB | |

> **Zamka koja nas je koštala sati.** Ako netko uključi Dynamic Memory, VM se neće pokrenuti
> pa se GPU particija ukloni da bi se VM uopće digao. Gost tada radi na WARP-u s 0 MiB VRAM-a,
> a `Get-PnpDevice -Class Display` prikazuje GPU kao `CM_PROB_PHANTOM`. Provjeri to prvo.

Driver u gostu (`C:\Windows\System32\HostDriverStore\FileRepository\nv_dispi.inf_amd64_*`)
mora biti **bit-identičan** onome na hostu. Nakon svake nadogradnje NVIDIA drivera na hostu
kopija u gostu se mora osvježiti, inače gost daje Code 43.

---

## 4. Instalacija od nule

Sve skripte traže **elevated PowerShell** u **konzolnoj sesiji**.

> Windows 10 je single-session. RDP preseli konzolnu sesiju sebi i VDD tada nije vidljiv,
> pa sva mjerenja displayja postaju bezvrijedna. Provjeri s `query user` — mora pisati
> `console` i `Active`. Povratak: `tscon 1 /dest:console`.

### Korak 0 — provjera preduvjeta

```powershell
.\scripts\00-preflight.ps1
```

Provjerava elevaciju, konzolnu sesiju, prisutnost GPU-P particije, VRAM i verziju drivera.
**Ne nastavljaj ako ovo ne prođe.**

### Korak 1 — Virtual Display Driver

Instaliraj VDD (MikeTheTech, [github.com/VirtualDrivers/Virtual-Display-Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver))
u `C:\VirtualDisplayDriver\`, pa:

```powershell
.\scripts\01-vdd-configure.ps1
```

Upisuje provjerenu konfiguraciju i restarta driver. Ključne postavke i **zašto**:

| Postavka | Vrijednost | Razlog |
|---|---|---|
| `<friendlyname>` | `Microsoft Basic Render Driver` | **Srž rješenja.** Na GPU-u Desktop Duplication pada. |
| `<count>` | `1` | Jedan monitor je dovoljan. Pravilo o dva monitora vrijedi samo na GPU-P adapteru. |
| najniža rezolucija | `1280x720` | Windows pada na najniži ponuđeni mod. Ne stavljaj `800x600`. |

### Korak 2 — Sunshine

Instaliraj Sunshine (LizardByte) kao servis, pa:

```powershell
.\scripts\02-sunshine-configure.ps1
```

Skripta **sama otkrije** GUID VDD monitora iz Sunshineovog loga i upiše ga u `output_name`
— taj se GUID razlikuje od stroja do stroja pa se ne smije prepisivati iz ove dokumentacije.

### Korak 3 — provjera

```powershell
.\scripts\03-verify.ps1
```

Mora javiti `DuplicateOutput: OK` i da je Sunshine odabrao enkoder.

### Korak 4 — DPI

```powershell
.\scripts\set-dpi-100.ps1
```

Windows na širokim rezolucijama sam predloži 200% skaliranje, čime radna površina
5120×1440 postane upotrebljivih 2560×720 razvučenih preko cijelog ekrana. To je bio
jedan od izvornih simptoma.

`SPI_SETLOGICALDPIOVERRIDE` prima **relativni** pomak od Windowsove preporuke, ne apsolutni
postotak. Ako je preporučeno 200%, onda je `-4` jednako 100%, `-3` je 125%, `-2` je 150%.
Za CAD na 32:9 monitoru **125% je često ugodnije od 100%** — tekst ostaje čitljiv, a radna
površina i dalje velika.

### Korak 5 — GPU za aplikacije

Za svaku aplikaciju koja treba GPU: *Settings → Display → Graphics → dodaj → **High performance***.

Provjera da je stvarno na GPU-u:

```powershell
.\scripts\whichgpu.ps1
```

Postavka se zapisuje u `HKCU:\Software\Microsoft\DirectX\UserGpuPreferences`
kao `GpuPreference=2`.

---

### Korak 6 — ukloni Store dijalog pri pokretanju programa

```powershell
.\scripts\disable-gamebar-prompt.ps1
```

Na LTSC izdanju igre i DirectX aplikacije pozivaju Xbox Game Bar preko protokola
`ms-gamingoverlay`, koji nema registriranog rukovatelja jer LTSC nema Store aplikacije.
Windows tada javi **„You'll need a new app to open this ms-gamingoverlay link"** i nudi
Microsoft Store. Skripta gasi GameDVR pa ga aplikacije uopće ne pozivaju.

Pokreni **kao administrator** ako želiš i strojnu politiku (`AllowGameDVR`); bez elevacije
postavlja samo korisničku razinu, što je obično dovoljno. Vrijedi za novopokrenute programe.
Povratak: `-Revert`.

---

### Koraci 7, 8 i 9 — grafika: PREPISANO, vidi GRAFIKA.md

Ovdje su prije stajala tri poglavlja koja su sada **netočna**:

- *Korak 7 — NVIDIA Vulkan: NE RADI na GPU-P*
- *Korak 8 — OpenGL preko D3D12 (Mesa)*
- *Korak 9 — Vulkan preko Dozena*

Izmjereno 21.8.2026.: **izvorni NVIDIA Vulkan i OpenGL rade**, i Mesa nije potrebna
ni za što.

```
Vulkan       NVIDIA GeForce RTX 4090   API 1.4.325   Discrete GPU
OpenGL       NVIDIA GeForce RTX 4090/PCIe/SSE2   4.6.0 NVIDIA 591.59
Direct3D 12  feature level 12_0,  24138 MiB
NVENC        h264_nvenc, hevc_nvenc, av1_nvenc     hardverski
```

Jedini uvjet je da **Hyper-V synthetic display bude prikačen na desktop** — bez njega
NVIDIA-in ICD nabroji nula uređaja, a OpenGL padne na `GDI Generic 1.1`.

Cijela priča, s objašnjenjem zašto je tako i što se sve pokazalo krivim, je u
**[GRAFIKA.md](GRAFIKA.md)**. Stara verzija ovog poglavlja je u `README.md.zastarjelo` (lokalna arhiva koja nije u repozitoriju).

## 4a. Uklanjanje

`UNINSTALL.ps1` je dio paketa i instalater ga ostavi na mjestu gdje ga možeš naći:

- **Start izbornik → Uninstall Luxstream**, ili
- `C:\Program Files\Luxstream\UNINSTALL.cmd`, ili
- `C:\Program Files\Luxstream\Luxstream-ODINSTALIRAJ.cmd` (isto)

Dvoklik je dovoljan — sam traži administratorske ovlasti.

**Prvo pogledaj što bi napravio** (ispiše sve, ne mijenja ništa):

```powershell
C:\Program Files\Luxstream\UNINSTALL.cmd -Samoprovjera
```

Uklanja svih **pet** zakazanih zadataka (`SunshineUser`, `StreamReady`,
`RestoreConsoleSession`, `VerifyAfterBoot`, `LuxstreamBridge`), Sunshine, VDD,
ViGEmBus i VB-Audio kabel, vraća registry izmjene (UAC, automatska prijava,
GameDVR/Game Bar, DPI), skida firewall pravilo i obriše paket. Na kraju je
**obavezan restart**.

Zadaci se odjavljuju **prije** drivera i datoteka — obrnut redoslijed ne radi jer
`StreamReady` i `SunshineUser` u međuvremenu ponovno podignu Sunshine.

Podaci mosta i `sunshine.conf` se **premjeste** u `C:\Luxstream-uklonjeno-<vrijeme>`,
a ne brišu; trajno brisanje je `-Obrisi`. Potpisnički certifikati se ne diraju bez
`-ObrisiCertifikate` (SignPath Foundation je javni CA).

Puni popis faza i prekidača je u **[INSTALACIJA.md](INSTALACIJA.md)**, poglavlje 12.

## 5. Postavke Moonlight klijenta

| Postavka | Vrijednost | Zašto |
|---|---|---|
| **Video decoder** | **Automatic** | najvažnija postavka, vidi niže |
| **Video codec** | **HEVC** | ne `Automatic` — ona izabere AV1, kojeg stariji klijenti nemaju |
| Rezolucija | ista kao desktop | inače Sunshine skalira i gubi se oštrina |
| FPS | 60 | ako klijent stiže |
| Bitrate | 36 Mbps | 72 Mbps je uzrokovalo štekanje |

### Video decoder mora biti Automatic

Ovo je bila najskuplja pouka cijelog projekta. Moonlight ima postavku `Video decoder` s
vrijednostima `Automatic`, `Force software decoding` i `Force hardware decoding`. Ako je
na **force software**, klijent svjesno zaobilazi svoj hardverski dekoder i sve radi
procesorom.

```
Force software decoding   25 ms u mirovanju, 170-350 ms pod opterecenjem
Automatic (hardverski)     1,5 ms
```

Sedamnaest puta razlike. Sat vremena je otišlo na mijenjanje rezolucija, osvježavanja,
bitratea i kodeka prije nego se to otkrilo.

**Znakovi da je klijent na softverskom dekodiranju:**

```
decode time preko 20 ms na bilo cemu
ventilator na klijentu se upali i ne gasi
CPU na klijentu visok, GPU nizak
decode skoci na 300+ ms cim se nesto pomakne na ekranu
IDR zahtjeva u sunshine.log vise od 0
```

Prije nego diraš išta na hostu, provjeri ovo.

### Rezolucija i širina

Ranija verzija ovog poglavlja tvrdila je da hardverski dekoderi staju na 4096 px širine i
da 5120x1440 traži softversko dekodiranje. **To je bilo krivo.** Uz ispravno postavljen
`Video decoder` klijent (Intel UHD 600 na LattePandi Delta) bez problema dekodira
5120x1440 pri 60 fps s 1,5 ms.

Ono što stvarno vrijedi: **desktop i Moonlight moraju biti na istoj rezoluciji.** Ako nisu,
Sunshine skalira — slika ostane preko cijelog ekrana ali izgubi oštrinu, a sva mjerenja
postanu besmislena. Što klijent stvarno traži vidi se u logu kao `Debug: mode -- 5120x1440x60`;
`Capture size` je veličina desktopa, ne streama.

## 5a. Kloniranje VM-a i više istovremenih sesija

Kad se ovaj VM kopira na hostu, klon **naslijedi Sunshineov identitet**. Moonlight hostove
razlikuje po `uniqueid`, pa dva klona vidi kao **jedan te isti host** i ne može držati dvije
istovremene sesije.

Sporni podaci:

| Datoteka / postavka | Što nosi |
|---|---|
| `config\sunshine_state.json` → `root.uniqueid` | jedinstveni ID hosta koji Moonlight koristi |
| `config\credentials\cacert.pem`, `cakey.pem` | TLS identitet za uparivanje |
| `hostname` | ime kojim se Sunshine objavljuje preko mDNS-a |

Na **svakom klonu** pokreni:

```powershell
.\scripts\04-prepare-clone.ps1 -NewComputerName GPU-2 -SunshineName "CAD-2" -Restart
```

Skripta obriše identitet (uz backup), po želji preimenuje računalo i postavi
`sunshine_name`. Sunshine pri sljedećem startu generira nov `uniqueid` i nove certifikate.
**Svaki klon se zatim mora ponovo upariti iz Moonlighta.**

### Što je stvarno usko grlo kod dvije sesije

**Ispravak:** ranija verzija je ovdje tvrdila da se NVENC ne koristi i da je usko grlo CPU.
Otkad hvatanje ide preko WGC-a na NVIDIA displayu, **NVENC radi** i enkodiranje je hardversko —
pri 5120x1440 i 60 fps Sunshine troši 5% CPU-a.

Time se usko grlo vraća onamo gdje se obično i očekuje: **consumer GeForce kartice ograničavaju
broj istovremenih NVENC sesija.** Koliko ih točno RTX 4090 podnosi kroz GPU-P particije nije
izmjereno — kad se bude klonirao drugi VM, to je prvo što treba provjeriti.

CPU hosta više nije glavna briga, ali svaki VM i dalje troši svoje vCPU jezgre na kompoziciju
desktopa i mrežni sloj.

Ono što se **ne** sudara: `output_name` GUID je isti na svim klonovima (VDD ima isti EDID),
ali je lokalan svakom VM-u pa ne stvara nikakav problem.

---

## 5b. Međuspremnik i datoteke između VM-a i klijenta

**Sunshine i Moonlight ne dijele ni međuspremnik ni datoteke.** To nije postavka koja
nedostaje — funkcije u protokolu nema. Provjereno: `sunshine.exe` nema nijednu referencu na
Windows clipboard API (`OpenClipboard`, `SetClipboardData`, `CF_UNICODETEXT` — sve nula).
RDP to ima jer je remote *desktop* protokol s virtualnim kanalima; Moonlight prenosi samo
sliku, zvuk i ulaz.

> **Ne rješavaj to usporednim RDP-om.** RDP preseli konzolnu sesiju sebi, VDD nestane i
> Sunshine ostane bez slike.

### Rješenje: `scripts\luxstream-bridge.ps1`

Dvosmjerni most preko običnog TCP-a, **izvan** protokola streama — pa radi s bilo kojom
verzijom Sunshinea i Moonlighta. Prenosi:

| Vrsta | Kako se koristi |
|---|---|
| tekst | kopiraj na jednoj strani, zalijepi na drugoj |
| slika (PNG) | isto, kroz međuspremnik |
| **datoteka iz međuspremnika** | Ctrl+C na datoteku u Exploreru → Ctrl+V na drugoj strani zalijepi samu datoteku |
| **datoteka preko mape** | baci datoteku u `%USERPROFILE%\Luxstream\Drop\` → nestane odatle i pojavi se u `Luxstream\Primljeno\` na drugoj strani |

Most zamjenjuje stari `clipboard-bridge.ps1`, koji je prenosio samo tekst.

### Koja strana sluša

**Host sluša, VM se spaja.** Host na *Default Switchu* ima fiksnu adresu `172.29.32.1`; adresa
VM-a se mijenja (DHCP i klonovi), pa bi se na hostu stalno morala prepisivati. Klijent bez
`-Peer` sam uzme zadani gateway — a to je na Default Switchu upravo host.

**Na HOSTU** (jednom, iz povišenog PowerShella):

```powershell
New-NetFirewallRule -DisplayName 'Luxstream bridge' -Direction Inbound `
  -Protocol TCP -LocalPort 51888 -Action Allow -RemoteAddress 172.29.32.0/24

.\scripts\luxstream-bridge.ps1 -Mode Server -Install
```

`-Install` zapiše konfiguraciju u `C:\ProgramData\Luxstream\bridge.json`, izgenerira
zajedničku tajnu, ispiše ju i registrira zadatak `LuxstreamBridge` koji se pokreće pri prijavi.
**Tajna mora biti ista na obje strane** — pokreni `-Install` na hostu, prepiši ispisanu tajnu, pa
je na VM-u predaj kao `-TajnaMosta`:

```powershell
.\INSTALL.ps1 -TajnaMosta 'tajna-s-hosta'
```

(Bez `-TajnaMosta` instalater izgenerira svoju i ispiše gotovu naredbu za host na kraju.)

Bez instalera, ručno:

```powershell
.\scripts\luxstream-bridge.ps1 -Mode Client -Secret '<tajna-s-hosta>' -Install
```

`-Install` na obje strane radi isto: registrira zadatak pri prijavi. Proces se pali kroz
`luxstream-bridge-hidden.vbs`, jer Task Scheduler pokretanjem `powershell.exe` nakratko
prikaže konzolni prozor — i to unatoč `-WindowStyle Hidden`.

**Ne postavljaj ga kao Windows servis** — servis radi u sesiji 0 i ondje nema pristup
međuspremniku korisnika.

### Provjera

```powershell
# radi li, koja je konfiguracija, zadnjih 15 redaka dnevnika
.\scripts\luxstream-bridge.ps1 -Status

# samotest bez ikakve vanjske veze - pravi TCP spoj na 127.0.0.1:
# tekst s dijakriticima u oba smjera, PNG, datoteka od 700 KB preko granice
# komada od 256 KB (MD5), i sanitizacija imena
.\scripts\luxstream-bridge.ps1 -SelfTest
```

Dnevnik je `%USERPROFILE%\Luxstream\luxstream-bridge.log`. Zapisuje se i **razlog zašto most
nije krenuo** (npr. nema tajne) — inače bi kvar iz zakazanog zadatka bio potpuno nevidljiv.

### Zašto je izvedeno preko STA runspacea

Windows clipboard API radi samo iz **STA** niti. Interaktivni `powershell.exe` jest STA, ali
zakazani zadaci i pozadinski procesi znaju biti **MTA**, gdje se međuspremnik **tiho** ne
pročita ni ne postavi — bez ijedne greške. Zato skripta drži jedan trajni STA runspace i sav
pristup ide kroz njega. Provjereno u oba smjera, uz hrvatske dijakritike.

Uz to su dvije zamke ugrađene u samotest kao trajne provjere:

- STA skripta ne smije kao završni izraz ispisati polje — PowerShell ga razvuče, pa se od
  `byte[]` (PNG) vrati samo prvi bajt. Tada i „duljina > 50" i „preneseno identično" ispadnu
  besmislene, ali ne i vidljivo pogrešne.
- `.BaseObject` na običnom hashtableu ili `byte[]` vraća `$null`. „Sigurnosno" raspetljavanje
  `if ($x -is [PSObject]) { $x = $x.BaseObject }` tiho obriše upravo ono što se prenosi.

### Redoslijed čitanja međuspremnika

Namjerno **datoteke → tekst → slika**. Kopiranje datoteke u Exploreru postavlja `CF_HDROP`,
ali često i `CF_UNICODETEXT` s putanjom; da tekst ide prvi, poslala bi se samo putanja, a
datoteka ne. PNG se pri ponovnom kodiranju ne dobije bajt-identičan, pa se nakon mrežnog
zapisa međuspremnik **ponovno pročita** i zapamti novi hash — uz prozor od 1,5 s. Bez toga bi
lokalna anketa vidjela vlastiti zapis kao „novo" i poslala ga natrag u petlji.

### Ograničenja

- Promet **nije kriptiran**. Zajednička tajna u `HELLO` samo sprječava slučajan spoj, ne
  prisluškivanje. Namijenjeno povjerljivom LAN-u.
- Mape se **ne prenose rekurzivno** — samo datoteke. Za mapu koristi arhivu ili kopiraj u
  `Drop\` u više prolaza.
- Granice: tekst 1 MB, slika 16 MB, ukupno pri copy/paste datoteka 64 MB, pojedinačna
  datoteka iz `Drop\` 4 GB, okvir 64 MB.
- Ime se sanira (odbacuje se svaka putanja, `<>:"|?*` i upravljački znakovi idu u `_`,
  skraćuje na 180 znakova), a kolizija dobiva sufiks `-1`, `-2`…
- Radi **samo u interaktivnoj sesiji**. Kao servis ne radi — tiho, bez greške.
- `-AllowedClients` ograničava po IP prefiksu (zadano `172.29.`, `192.168.`, `10.`, `127.`).

---

## 6. Dijagnostika

### `ddtest.ps1` — najvažniji alat

Testira `IDXGIOutput1::DuplicateOutput` nad **svakom** kombinacijom adaptera i outputa,
neovisno o Sunshineu. Bez njega se dijagnoza svodi na nagađanje jer Sunshine ne loguje
koji adapter proba.

```powershell
.\scripts\ddtest.ps1
```

Ispravan ishod:

```
ADAPTER 0: Microsoft Basic Render Driver
   OUTPUT 0: \\.\DISPLAY10  1920x1080 attached=True  -> *** DUPLICATE OK ***
ADAPTER 1: NVIDIA GeForce RTX 4090
   (nema outputa)
```

Ako uz VDD vidiš `FAIL 0x80070057`, VDD je vezan na GPU — vrati se na korak 1.

### Tablica simptoma

| Simptom | Uzrok | Rješenje |
|---|---|---|
| `DuplicateOutput() test failed [0x80070057]` | VDD vezan na GPU-P adapter | `<friendlyname>Microsoft Basic Render Driver</friendlyname>` |
| `Fatal: Unable to find display or encoder` | isto | isto |
| Slika 800×600 razvučena | 800×600 najniži mod + Sunshine ga pamti | ukloni ga iz VDD liste, obriši `display_device.state` |
| Rezolucija se ne mijenja pri spajanju | "Optimize game settings" isključen u klijentu | uključi u Moonlightu |
| Crni okvir, slika u sredini | `dd_resolution_option = manual`, omjer se ne poklapa s klijentom | postavi na `auto` |
| Sve sitno pri visokoj rezoluciji | Windows sam stavio 200% DPI | `set-dpi-100.ps1` |
| Slika štuca, decode time preko 100 ms | `Video decoder` na klijentu je `Force software decoding` | prebaci na `Automatic` |
| `sunshine.exe` se ruši u petlji (`0xc0000409`) | pokrenut kao servis, dakle SYSTEM; WGC aktivacija ne prolazi | pokreni ga kao korisnika, zadatak `SunshineUser` |
| Sunshine ignorira prvi redak `sunshine.conf` | UTF-8 BOM u datoteci | piši bez BOM-a (skripte to rade) |
| GPU prijavljen kao `CM_PROB_PHANTOM` | particija uklonjena na hostu | vidi poglavlje 3 |

---

## 7. Slijepe ulice — ne ponavljaj ih

**Ispravak:** ranija verzija je ovdje navodila `capture = wgc` kao slijepu ulicu. To je bilo
točno za **neizmijenjeni** Sunshine, koji svaki izlaz filtrira kroz Desktop Duplication probu
prije nego WGC dobije priliku. Sa zakrpom iz [FORK.md](FORK.md) `capture = wgc` je **rješenje**,
ne slijepa ulica.

Ovo je testirano i stvarno ne pomaže:

- **`adapter_name` uz `output_name` koji se ne poklapaju** — `adapter_name` bira adapter na
  kojem se traži i output; kad se ne poklapaju, pada i softverski enkoder.
- **Isključivanje ili deinstalacija Hyper-V Video adaptera** — ne mijenja ništa oko hvatanja
  slike, a oduzima ti izvorni Vulkan i OpenGL. Ostavi ga.
- **Ručna registracija NVIDIA Vulkan ICD-a** u `HKLM\SOFTWARE\Khronos\Vulkan\Drivers` — loader
  manifest stvarno prihvati, ali ICD i dalje prijavi 0 uređaja bez prikačenog NVIDIA displaya.
  Uz to uzrokuje dvostruko nabrajanje istog GPU-a. Vidi [GRAFIKA.md](GRAFIKA.md).
- **Vezanje VDD-a na NVIDIA nije dovoljno za ICD.** VDD je indirektni display i ne stvara
  WDDM display put koji NVIDIA-in ICD traži, ma na kojem GPU-u renderirao.
- **`libvirtualhid`** — MSI se ne instalira, driver uđe u trgovinu ali vezanje padne s
  `UpdateDriverForPlugAndPlayDevices failed with Win32 error 87`. Gamepad radi preko ViGEma.

## 8. Poznata ograničenja

Sve niže je izmjereno na trenutnoj postavi. Ranija verzija ovog poglavlja tvrdila je da
NVENC i HEVC nisu dostupni — **to više ne vrijedi**.

- **Sunshine ne može raditi kao servis.** Servis ga pokrene kao SYSTEM, a WinRT aktivacija
  `GraphicsCaptureItem` za SYSTEM ne prolazi i proces se ubije s `0xc0000409` u `ucrtbase.dll`.
  Radi kao korisnik preko zadatka `SunshineUser`. Posljedica: diže se tek nakon prijave i
  ne hvata zaslon za prijavu.
- **Rezolucija desktopa se postavlja ručno.** `dd_configuration_option` mora ostati
  `verify_only` da Sunshine ne izbaci Hyper-V display, pa `dd_resolution_option = auto`
  ne djeluje.
- **Hyper-V display mora ostati prikačen** — bez njega nema izvornog Vulkana ni OpenGL-a.
- **Desktop Duplication ne radi** i nikad neće. Nijedan alat koji se na nju oslanja neće
  raditi: Parsec, RustDesk, OBS *Display Capture*. OBS-ov *Window Capture (WGC)* bi trebao proći.

### Ako trebaš više

Postava mora ostati na **GPU-P** — host ne smije ostati bez GPU-a. Unutar tog okvira:

- **Usko grlo više nije host.** Pri 5120x1440 i 60 fps Sunshine troši 5% CPU-a i ima 10 ms
  latencije obrade kadra. Ako slika štuca, uzrok je gotovo sigurno na klijentu — prvo
  provjeri koristi li hardverski dekoder.
- **AV1** je dostupan hardverski (`av1_nvenc`) i daje istu sliku uz manji bitrate, ali samo
  ako ga klijentov dekoder podržava. Starije Intelove grafike ga nemaju.

## 9. Sadržaj paketa

```
INSTALL.cmd                      pokretač instalacije (dvoklik, sam traži ovlasti)
INSTALL.ps1                      glavni instalater
UNINSTALL.ps1                    glavni deinstalater (vidi poglavlje 12 u INSTALACIJA.md)
UNINSTALL.cmd                    pokretač uklanjanja (dvoklik, sam traži ovlasti)
Luxstream-ODINSTALIRAJ.cmd       isto, hrvatsko ime - par uz INSTALL.cmd
Luxstream-INSTALIRAJ.cmd         instalacija s mrežnog mjesta - kopira paket lokalno
README.md                        ovaj dokument
config/
  vdd_settings.xml               provjerena VDD konfiguracija
  sunshine.conf.template         Sunshine konfiguracija (output_name se popunjava skriptom)
scripts/
  00-preflight.ps1               provjera preduvjeta
  01-vdd-configure.ps1           konfiguracija i restart VDD-a
  02-sunshine-configure.ps1      konfiguracija Sunshinea, otkriva output_name
  04-prepare-clone.ps1           resetira Sunshine identitet na kloniranom VM-u
  03-verify.ps1                  završna provjera
  ddtest.ps1                     test Desktop Duplicationa (ključni alat)
  whichgpu.ps1                   koji adapter dobivaju aplikacije
  set-dpi-100.ps1                DPI na 100%
  disable-gamebar-prompt.ps1     mice Store dijalog za ms-gamingoverlay
  vulkantest.ps1                 nabraja Vulkan uredaje
  enable-vulkan.ps1              registrira NVIDIA Vulkan ICD (ne pomaze na GPU-P)
  d3d12test.ps1                  moze li se stvoriti D3D12 uredaj po adapteru
  d3d12features.ps1              Shader Model i Resource Binding Tier
  gltest.ps1                     GL_VENDOR / GL_RENDERER / GL_VERSION
  glext.ps1                      popis GL ekstenzija i kljucne provjere
  d3d12test.ps1 / d3d12features.ps1  D3D12 po adapteru
  gfx-status.ps1                 CIJELA graficka slika u jednoj naredbi
  setup-mesa-graphics.ps1        postavlja Mesu: OpenGL d3d12/llvmpipe + Vulkan Dozen
  luxstream-bridge.ps1           most za meduspremnik (tekst, slika, datoteke) i
                                 prijenos datoteka, VM <-> klijent; -Install/-Status/-SelfTest
  luxstream-bridge-hidden.vbs    pali most bez bljeska konzolnog prozora
  set-primary.ps1                programska promjena primarnog monitora
host/
  gpu-p-setup.ps1                naredbe za Hyper-V host
```

---

