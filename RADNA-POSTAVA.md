# Radna postava — provjereno 21.8.2026.

Sve navedeno je izmjereno, ne pretpostavljeno.

---

## Host: VM `GPU-test` (192.168.6.220)

```
capture                 = wgc
dd_configuration_option = verify_only
output_name             = {d54a4360-26df-5f1a-b161-298c03c03b66}
min_log_level           = info
```

`encoder` se **ne upisuje** — Sunshine sam probe i nađe hardverske enkodere:

```
Found H.264 encoder: h264_nvenc [nvenc]
Found HEVC encoder: hevc_nvenc [nvenc]
Found AV1 encoder:  av1_nvenc  [nvenc]
```

Pri 5120x1440: **5% CPU-a**, latencija obrade kadra ~10 ms, mrežna latencija 0,1 ms.

**Displayi — oba su nužna:**

```
VDD (ROOT\DISPLAY\0000)   5120x1440 @ 60 Hz   primary   <- ovo se streama
Hyper-V synthetic          640x480  @ 64 Hz             <- bez njega nema NVIDIA ICD-a
```

VDD je u `vdd_settings.xml` vezan na `NVIDIA GeForce RTX 4090`.
Hyper-V display mora ostati prikačen, inače Vulkan javi 0 uređaja a OpenGL padne
na `GDI Generic 1.1`. Položaj `-640,1080` dodiruje glavni display u jednoj točki,
pa miš ne može odlutati.

**Sunshine se pokreće zadatkom `SunshineUser` kao `luxnet`**, ne servisom.
`SunshineService` je `Disabled`. Zadatak `StreamReady` svake minute provjerava
konzolnu sesiju, oba displaya i radi li Sunshine.

---

## Klijent: LattePanda Delta (192.168.6.147)

Intel Celeron N4100, Intel UHD Graphics 600, ~6 W.

(vidi poglavlje o dekoderu nize za tocne postavke)

**Ne stavljati Automatic.** Sunshine sada nudi i AV1, automatika ga izabere kao
najnoviji, a UHD 600 nema AV1 dekoder — dobije se prazan bijeli okvir.

**Ne dizati bitrate na 72 Mbps.** Pri 72 je slika štekala, pri 36 radi.

---

## Dva profila spajanja

Rezolucija i osvježavanje desktopa se postavljaju **ručno** (zbog `verify_only`), pa se
mijenjaju ovisno o tome odakle se spajaš.

### Lokalna mreža, ultrawide klijent

```
desktop      5120x1440 @ 60 Hz
Moonlight    5120x1440, 60 fps, HEVC, decoder Automatic
bitrate      36 Mbps
```

Mrežna latencija 0,1 ms, decode 1,5 ms. Sve radi glatko.

### PPTP, klijent 1920x1080

```
desktop      1920x1080 @ 30 Hz
Moonlight    1920x1080, 30 fps, HEVC, decoder Automatic
bitrate      10-15 Mbps
```

Preko PPTP-a je mrežna latencija oko **150 ms** i nju nikakva postavka ne mijenja — to je
granica same veze. Smanjenjem fps-a i bitratea dobiva se **stabilnost, ne odziv**: manje
podataka znači manje zagušenja, manje izgubljenih paketa i manje zahtjeva za ključnim
kadrom. Miš svejedno osjetno kasni.

Upotrebljivo za tekst i pregled crteža. Nije za bilo što gdje pratiš pokret.

**Desktop na 30 Hz je dovoljan sam po sebi** — Sunshine ne može poslati više kadrova nego
što ih desktop proizvede, pa i ako Moonlight traži 60, dobit će 30. Postavka u Moonlightu
je tu samo da enkoder ne cilja uzalud na 60.

---
## Dekodiranje na klijentu — pravi uzrok svih problema

**U Moonlightu je `Video decoder` bio na `Force software decoding`.**

Sve ostalo je bila posljedica. Intelov hardverski dekoder je bio zaobiđen, a Celeron
N4100 je HEVC dekodirao procesorom.

```
Force software decoding   25 ms u mirovanju, 170-350 ms pod opterecenjem, ventilator stalno
Automatic (hardverski)     1,5 ms                                          ventilator tih
```

Sedamnaest puta brže. Nakon prebacivanja `5120x1440 @ 60` radi bez problema, CPU
na klijentu ispod 10%.

**Ispravna postavka klijenta:**

```
Resolution     5120x1440
FPS            60
Video codec    HEVC        <- NE "Automatic": ona izabere AV1, kojeg UHD 600 nema, i dobije se bijeli okvir
Video decoder  Automatic   <- NE "Force software decoding"
Bitrate        36 Mbps
```

Dvije su postavke slično imenovane i lako ih je pomiješati. **Codec** ostaje ručno na
HEVC, **decoder** mora biti na Automatic.

### Kako prepoznati da je klijent na softverskom dekodiranju

```
decode time preko 20 ms na bilo cemu
ventilator na klijentu se upali i ne gasi
CPU na klijentu visok, GPU nizak
decode skoci na 300+ ms cim se nesto pomakne na ekranu
```

Ako se to dogodi, prvo provjeri `Video decoder`, prije nego diraš rezoluciju,
osvježavanje, bitrate ili kodek. Sve to smo mijenjali cijelo jutro bez ikakve koristi.

### Oborene hipoteze

Sedam objašnjenja koja su se činila dobrima i pala su na mjerenjima:

1. **Granica širine 4096 px u dekoderu.** Log je pokazivao `mode -- 5120x1440x30`
   sa 23 ms i nula IDR zahtjeva.
2. **Ukupna propusnost u megapikselima.** `2560x1440 @ 60` i `5120x1440 @ 30` imaju
   isti broj megapiksela u sekundi, a ponašali su se posve različito.
3. **Osvježavanje desktopa.** Desktop je već bio na 30 Hz kad je štekalo.
4. **Toplinsko posustajanje klijenta.** Hlađenje nije pomoglo.
5. **Dubina boje ili colorspace.** U svim sesijama 8 bita, isti P709.
6. **30 fps je strop ovog klijenta.** Sa hardverskim dekoderom 60 fps radi glatko.
7. **NVENC nedostupan na GPU-P.** Rade sva tri enkodera (vidi TODO 2.1).

### Pouka

Prije mjerenja bilo čega na hostu, **provjeri da klijent uopće koristi hardverski
dekoder**. Sat vremena je otišlo na mijenjanje rezolucija, osvježavanja i kodeka,
a uzrok je bio jedna postavka u klijentu. Znak koji je cijelo vrijeme bio pred nama:
ventilator na klijentu koji zuji čak i kad se ništa ne događa.

### Varljiva mjerenja

Ako se desktop i Moonlight ne poklapaju, Sunshine skalira: slika ostane preko cijelog
ekrana ali izgubi oštrinu, a mjerenja postanu besmislena. Ono što klijent stvarno traži
vidi se u logu kao `Debug: mode -- 5120x1440x60`; `Capture size` je veličina desktopa,
ne streama.
## Što je uz to riješeno

- Uparivanje s klijenta preko PPTP-a — vatrozid je bio na strani klijenta
- UAC više ne zamrzava unos (`ConsentPromptBehaviorAdmin = 0`)
- Postava preživljava ponovno pokretanje VM-a
- Miš ne bježi na Hyper-V display

Otvorene stavke su u `TODO.md`.
