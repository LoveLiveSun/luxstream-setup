# Što još treba riješiti

Stanje **21.8.2026.**, nakon što je zakrpani Sunshine proradio i postava dovedena do kraja.

Riješene stavke su izbačene iz ovog popisa; ono što je iz njih naučeno je u
[RADNA-POSTAVA.md](RADNA-POSTAVA.md) i [GRAFIKA.md](GRAFIKA.md).

---

## Gdje smo

```
5120x1440 @ 60 fps, HEVC, hardverski dekoder na klijentu   decode 1,5 ms
Vulkan 1.4.325 + OpenGL 4.6 + Direct3D 12 izvorni
NVENC hardverski, 5% CPU-a na hostu, 10 ms latencije
Postava prezivljava ponovno pokretanje VM-a
Novi VM se postavlja jednim pokretacem: INSTALL.cmd
```

---

## 1. Kritično

### 1.1. Sunshine ne može raditi kao servis — ZATVORENO 21.8.2026., to je zid

Uzrok je utvrđen zakrpom 3 (commit `8f3c1676`, build `2026.821.103043`), koja zapisuje
svaki korak u `wgc_capture_t::init`. Kad Sunshine radi kao SYSTEM:

```
wgc: init start
wgc: apartment initialised
wgc: step 1 GraphicsCaptureSession::IsSupported()
Error: wgc: std::exception while acquiring device: std::bad_alloc
```

Pada na **prvom pozivu**, `GraphicsCaptureSession::IsSupported()`, i baca **`std::bad_alloc`**.
C++/WinRT tako preslikava `E_OUTOFMEMORY` koji `RoGetActivationFactory` vrati kad aktivacija
runtime klase u tom kontekstu nije moguća.

**SYSTEM ne može aktivirati Windows.Graphics.Capture.** To je ograničenje Windowsa, ne bug
u Sunshineu, i ne da se zaobići konfiguracijom.

Provjereno i odbačeno usput:

- **Inicijalizacija WinRT apartmana ne pomaže.** Sunshine je nigdje ne radi; zakrpa 3 je
  dodala `winrt::init_apartment()` i on uspije (`apartment initialised`), ali pad ostaje.
- **Zakrpa 2 je hvatala krivi tip.** `catch (winrt::hresult_error&)` ne hvata `std::bad_alloc`,
  pa je iznimka izlijetala do `std::terminate()` i ubijala proces s `0xc0000409`.

**Zaključak: zadatak `SunshineUser` nije zaobilazno rješenje nego jedino moguće.**
Trajna cijena: Sunshine se diže tek nakon prijave i ne hvata zaslon za prijavu.

#### Što je zakrpa 3 ipak donijela

Proces se **više ne ruši u petlji**. Umjesto `0xc0000409` bez ijedne poruke u logu, sada
uredno zapiše grešku, vrati `-1` i nastavi:

```
Encoder [nvenc] failed
Encoder [software] failed
Fatal: Unable to find display or encoder during startup.
```

To je samo po sebi vrijedno za upstream — vidi poglavlje 4.

### 1.2. Gamepad — neprovjeren

Nema kontrolera za testiranje. Kod kaže da bi trebao raditi:

```cpp
// src/platform/windows/virtualhid_input.cpp
const auto fallback_supported = fallback_vigem_available && (profile.name == "x360" || profile.name == "ds4");
```

Onemogućeni su samo `generic`, `xone`, `xseries`, `ds5`, `switch`. Omogućeni su `auto`,
`x360` i `ds4`, preko ViGEma 1.21.442 koji je instaliran i zdrav.

`libvirtualhid` (nova LizardByteova komponenta) **se ne da instalirati** — driver uđe u
trgovinu (`oem7.inf`), ali vezanje padne s `UpdateDriverForPlugAndPlayDevices failed with
Win32 error 87`. MSI se zatim povuče i ostavi prazan uređaj `ROOT\LIBVIRTUALHID\0000`.
Očišćeno. Bez njega nedostaju samo egzotičniji profili: DualSense, Switch Pro, Xbox One/Series.

Potvrdeno 22.8.2026.: ViGEmBus uredaj **postoji i zdrav je** - `ROOT\SYSTEM\0001`,
hardverski ID `Nefarius\ViGEmBus\Gen1`, status OK.

Zamka pri provjeri: prijateljsko ime je *Nefarius Virtual Gamepad Emulation Bus*, u kojem
NEMA niza "ViGEm". Provjera po imenu lazno javlja da uredaja nema - trazi po hardverskom ID-u.

**Ostaje:** spojiti kontroler i potvrditi da se javi kao Xbox 360.

---

## 2. Ograničenja — što je palo, a što ostaje

### 2.1. Rezolucija prati klijenta - RIJESENO 22.8.2026.

`dd_configuration_option` je ostao `verify_only`, a `dd_resolution_option = auto` uz njega
**radi**. Ranija tvrdnja da uz `verify_only` automatika ne djeluje bila je pogresna i
nastala je iz jednog krivo procitanog mjerenja.

Ono sto i dalje vrijedi: `ensure_active` se NE SMIJE ukljuciti. On na pocetku streama
ponovno aktivira Hyper-V display i ponisti postavu s jednim zaslonom. To se dogodilo
uzivo - Cemu je pao usred pokretanja Zelde jer mu je Vulkan nestao petnaest sekundi ranije.

Rezolucija se mora birati iz **VDD liste modova** (11 ih je); trazenje moda kojeg nema u
listi se tiho nece primijeniti.

### 2.2. Hyper-V display OSTAJE aktivan - odluceno 23.8.2026.

**Ovo poglavlje je 22.8. tvrdilo suprotno. Tvrdnja je bila pogresna.**

Izmjereno 23.8.2026. na svjezem stogu, odmah nakon podizanja sustava:

```
17:03:53  displayi=2  vulkan=1
17:04:05  displayi=1  vulkan=0   <- pao odmah po deaktivaciji
17:05:08  displayi=2  vulkan=1
17:05:20  displayi=1  vulkan=1
17:05:52  displayi=1  vulkan=0   <- pao unutar 32 s
```

**Izvorni Vulkan i OpenGL trebaju AKTIVAN Hyper-V display.** S jednim displayem ne
prezive - ni odmah, ni nakon primingа. DirectX 12 radi u oba slucaja, jer ide preko
DXGI-ja i ne ovisi o ICD-u.

Zasto je 22.8. izgledalo drukcije: mjerilo se **odmah** nakon deaktivacije, a pad je
odgodjen 13-32 s. Mjerenje je bilo prerano i lazno pozitivno. Jednom je 23.8. u
15:46-15:52 doista drzalo sest minuta s jednim displayem - tu iznimku nisam objasnio.

**Odluka: dva displaya.** Hyper-V ostaje kao 640x480 na poziciji -640,720, dijagonalno
pomaknut, pa mis na njega prakticno ne prelazi. Stream ga ne dira jer je `output_name`
zakovan na VDD.

Watchdog vise NE deaktivira. Za staro ponasanje postoji prekidac `-JedanDisplay`.

Prozore koji ipak zavrse ondje vraca `scripts\vrati-prozore.ps1`.
### 2.3. Kloniranje VM-a - dva odvojena pitanja

Kad je kopirani VM odbio raditi, u igri su bile DVIJE hipoteze. Vrijedi ih drzati
odvojeno, jer se ne iskljucuju i jedna je rijesena, a druga nije.

#### (a) Sudar identiteta - MEHANIZAM POTVRDEN, RIJESENO 22.8.2026.

Klon nosi **isti** `credentials\cacert.pem` i **isti** `root.uniqueid` kao izvornik, pa
Moonlight vidi dva hosta koji tvrde da su isti stroj. Mehanizam je izmjeren i rjesenje
je ugradeno u instalater i u zadatak `StreamReady` - vidi [INSTALACIJA.md](INSTALACIJA.md),
poglavlje 5.

**Ali:** nije dokazano da je bas to srusilo onaj konkretni pokusaj. Potvrdeno je samo da
sudar postoji i da bi sam po sebi bio dovoljan da veza ne prode.

#### (b) Broj istovremenih NVENC sesija - NEIZMJERENO

Consumer GeForce kartice ogranicavaju broj istovremenih NVENC sesija. Koliko ih RTX 4090
podnosi kroz vise GPU-P particija - ne znamo.

Do 22.8.2026. se ovo smatralo neizmjerivim iz gosta. **Nije.** `nvidia-smi` u gostu radi
djelomicno: baci gresku za "device handle" fizickog GPU-a, ali `--query-gpu` prode:

```
nvidia-smi --query-gpu=name,encoder.stats.sessionCount --format=csv,noheader
NVIDIA GeForce RTX 4090, 0
```

Alat: `scripts\nvenc-sesije.ps1` (`-Prati` za neprekidno ocitavanje).

**Mjerenje koje treba napraviti kad postoji drugi VM:**

1. oba VM-a mirna -> ocekuj `0` i `0`
2. streamaj samo s VM-a A i ocitaj oba:
   - A pokazuje `1`, B pokazuje `0` -> brojac je **po particiji**, ne vidi tudje sesije
   - oba pokazuju `1` -> brojac je za **cijeli GPU**, i granica se moze pratiti
3. dodavaj streamove dok jedan ne odbije enkodirati; taj broj je granica

Tek to razdvaja hipotezu (b) od (a).

## 3. Čišćenje

### 3.1. Ostaci Vibepolla — UKLONJENO 21.8.2026.

```
Vibepollo 1.18.4-stable.3 (NSIS)      deinstalirano
Vibepollo 1.18.499.0 (MSI)            deinstalirano
SudoMaker Virtual Display Adapter     uredaj ROOT\DISPLAY\0001 + oem5.inf  uklonjeno
Sunshine Virtual Display Driver       uredaj ROOT\DISPLAY\0002 + oem6.inf  uklonjeno
```

Ostao je samo prazan `C:\Program Files\Apollo\config`, bezopasan.

**Dvije zamke uočene pri deinstalaciji:**

1. Vibepollov MSI deinstalater **ubije i nas Sunshine**, jer Apollo koristi isto ime izvršne
   datoteke (`sunshine.exe`). Nakon deinstalacije treba pokrenuti zadatak `SunshineUser`.
2. Prije brisanja driver paketa **provjeri koji INF pripada nasem VDD-u**. Kod nas je bio
   `oem3.inf`, a viškovi `oem5.inf` i `oem6.inf`:

```powershell
Get-PnpDeviceProperty -InstanceId 'ROOT\DISPLAY\0000' -KeyName 'DEVPKEY_Device_DriverInfPath'
```

Nakon uklanjanja je enkoder bio triput uzastopno restartan pa je `frame queue delay` na
klijentu narastao s 0,5 na 7 ms. Ponovnim spajanjem se vratilo na staro — nije bilo vezano
uz uklonjene drivere, koji su ionako bili mrtvi uređaji bez aktivnog displaya.

### 3.2. `launch-with-native-gpu.ps1` — ima grešku i više nije potreban

Provjerava je li Hyper-V monitor prikačen gledajući `WmiMonitorID`, a taj popis ga izlista
i kad nije u topologiji desktopa. Provjera daje lažno pozitivno i skripta preskoči
prikačivanje. Uz to, s novom postavom aplikacije se pokreću normalno.

Ili je popraviti, ili označiti kao povijesnu.

### 3.3. `04-prepare-clone.ps1` — zastarjelo

Pisano za staru arhitekturu (VDD na WARP-u, softverski enkoder). Treba prepisati za novu.

---

## 4. Prema upstreamu

Fork: `VjekoslavDugec/Sunshine-wgc`, grana `master`.

**Zakrpa 1 — gotova, dokazana, spremna za PR.** `test_capture_supported()` preskače Desktop
Duplication probu uz eksplicitni `capture = wgc`. Kompajlirala se iz prve uz `-DBUILD_WERROR=ON`.
Rješava cijelu kategoriju hostova — GPU-P/GPU-PV gostovi, Hyper-V, vjerojatno i neki hibridni
prijenosnici gdje DDA pada iz istog razloga.

Argument za PR je mjerenje na istom izlazu u istom trenutku:

```
IDXGIOutput1::DuplicateOutput()          -> 0x80070057
GraphicsCaptureItem CreateForMonitor()   -> S_OK, kadrovi teku
```

**Zakrpa 2 — commitana, ne rješava ništa ali je korisna sama po sebi.** Neuhvaćena iznimka
u `wgc_capture_t::init` ubija proces bez ijedne poruke u logu. I ako se pravi uzrok nikad ne
nađe, uredna poruka o grešci je bolja od tihog pada.

**Zakrpa 3 — gotova, dala odgovor i vrijedna sama po sebi.** Zapisuje svaki korak u
`wgc_capture_t::init` i hvata `std::exception` i `(...)` uz postojeći `hresult_error`.

Time je utvrđeno da `GraphicsCaptureSession::IsSupported()` baca **`std::bad_alloc`** kad
Sunshine radi kao SYSTEM — tip koji dosadašnji `catch` nije hvatao, pa je iznimka izlijetala
do `std::terminate()`.

Argument za PR: bez ove zakrpe korisnik dobije proces koji se ruši u petlji s `0xc0000409`
i **prazan log**. S njom dobije jasnu poruku i uredan nastavak. Vrijedi neovisno o tome što
je uzrok na kraju bilo ograničenje Windowsa, a ne bug u Sunshineu.

Uz to popravlja stvarnu grešku u istoj funkciji: `monitor_factory == nullptr` je dijelio
poruku koja ispisuje `status`, a on u toj grani nikad nije postavljen.

---

## 5. Deaktivacija Hyper-V displaya obara ICD — ZATVORENO 23.8.2026.

**Odgovor: kriv je bio izmrcvaren display stog, ne rezolucija i ne deaktivacija.**

Nakon čistog restarta, mjereno instrumentiranim watchdogom:

```
poslije-priminga       displayi=2  vulkan=1
poslije-deaktivacije   displayi=1  vulkan=1   <- preživio
na-pocetku             displayi=1  vulkan=1  |  DISPLAY2=5120x1440@60*
```

Dakle **5120×1440 na jednom displayu s izvornim Vulkanom** — točno ono što je korisnik
tvrdio, a što sam ja dvaput izmjerio krivo. Poglavlje 2.2 stoji.

Prije restarta je stog imao petnaestak promjena moda i topologije u pola sata, i u tom
stanju je deaktivacija rušila ICD. Pravilo o primingu vrijedi „od zadnjeg reseta display
stoga" — a stog se očito može dovesti u stanje iz kojeg se ne oporavlja bez podizanja
sustava.

**Praktična pouka:** ako Vulkan padne a priming ne pomaže, restartaj VM prije nego kreneš
loviti uzrok. Mjerenja iz izmrcvaranog stoga ne vrijede ništa.

**Pouka o postupku:** dva puta sam donio zaključak iz premalo mjerenja — prvo „kriva je
rezolucija", pa „deaktivacija uvijek obara ICD". Nedostajalo je jedno mjerenje: Vulkan
između trenutka kad je Sunshine postavio 5120×1440 i trenutka kad sam pokrenuo watchdog.
Zato watchdog sada to mjeri sam, u `C:\Users\Public\priming-dijagnostika.log`.

---

## 6. UAC potvrda preko Moonlighta — RIJEŠENO 23.8.2026.

Dok je Sunshine išao kao servis (SYSTEM) potvrda se mogla kliknuti. Otkad mora ići kao
korisnik zbog WGC-a, prestala je raditi.

**Uzrok su dvije odvojene prepreke:**

1. **Prebacivanje desktopa.** Uz `PromptOnSecureDesktop = 1` Windows prebaci ulazni desktop
   s `Default` na `Winlogon`. Sunshine hvata `Default`, pa se slika zamrzne i unos ode u
   prazno — potpuni gubitak kontrole.
2. **UIPI.** `consent.exe` radi na razini integriteta *System*, Sunshine kao korisnik na
   *High* i unos ubacuje preko `SendInput`. Niža razina ne smije slati unos višoj.

**Rješenje su također dvije stvari, obje potrebne:**

| Što | Zašto |
|---|---|
| `PromptOnSecureDesktop = 0` | dijalog ostaje na `Default` desktopu, WGC ga vidi |
| UIAccess na Sunshineu | unos zaobilazi UIPI |

UIAccess je Windowsov namjenski mehanizam za softver koji mora upravljati sučeljem iznad
vlastite razine — isti koji koristi `osk.exe`. Hipoteza je **prvo dokazana besplatno**:
zaslonska tipkovnica ima `<requestedExecutionLevel level="asInvoker" uiAccess="true"/>`,
potpisana je, i preko Moonlighta može potvrditi dijalog.

Tri uvjeta: sigurna lokacija (`C:\Program Files\Sunshine`), `uiAccess="true"` u manifestu,
Authenticode potpis. Odrađuje `scripts\uiaccess-sunshine.ps1`, koji instalater zove u fazi 6.

Potvrda da je stvarno uspjelo — nije dovoljno gledati manifest na disku:

```
proces PID 17988:  UIAccess = 1  (DODIJELJEN)
```

**Zamke koje su usput pojedene:**

- manifest u `Sunshine.exe` stoji pod **jezičnim identifikatorom 0**; upis pod 1033 vrati
  `OK` a promjena tiho nestane, jer `FindResource` i dalje nalazi izvorni
- čitanje manifesta u **istom procesu** koji ga je mijenjao vraća keširanu staru vrijednost
- `StreamReady` svake minute diže Sunshine — usred izmjene resursa zaključa datoteku, pa ga
  skripta privremeno gasi

**Zašto ovo nije u forku:** potpis se mora raditi na stroju jer se privatni ključ ne
isporučuje u paketu. Da manifest ide u build, i dalje bi trebao lokalni potpis — dvije
točke kvara umjesto jedne. Fork usto ostaje čist za PR prema upstreamu.

**Cijena:** certifikat `CN=Luxstream Code Signing` stoji u strojnim pouzdanim korijenima,
pa Windows vjeruje svemu potpisanom tim ključem. Ključ ne napušta VM.

Povratak: `.\uiaccess-sunshine.ps1 -Vrati` vraća izvornu binarnu datoteku iz
`Sunshine.exe.bez-uiaccess`.
